import Foundation
import OSLog

nonisolated protocol EPLPulseLiveClientProtocol: Sendable {
    func matches(season: String, matchweek: Int?, team: String?, period: String?, limit: Int, next: String?, sort: String?, kickoffAfter: Date?, kickoffBefore: Date?) async throws -> EPLValue
    func match(_ id: String) async throws -> EPLValue
    func events(_ matchID: String) async throws -> EPLValue
    func lineups(_ matchID: String) async throws -> EPLValue
    func stats(_ matchID: String) async throws -> EPLValue
    func officials(_ matchID: String) async throws -> EPLValue
    func commentary(_ matchID: String, limit: Int, next: String?) async throws -> EPLValue
    func standings(season: String, live: Bool) async throws -> EPLValue
    func teams(season: String) async throws -> EPLValue
    func squad(season: String, teamID: String) async throws -> EPLValue
    func playerBasic(_ id: String) async throws -> EPLValue
    func playerSeasonStats(season: String, playerID: String) async throws -> EPLValue
    func playersByID(_ ids: [String]) async throws -> EPLValue
}

/// PulseLive/SDP is undocumented private web infrastructure (see EPL-INTEGRATION.md
/// for the licensing note) — no API key, no auth, but a real gateway rate limit.
/// This client owns retry/backoff, 429 cooldown, and RFC 7807 problem+json parsing so
/// none of that leaks into mapping or UI code.
actor EPLPulseLiveClient {
    static let shared = EPLPulseLiveClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?

    init(session: URLSession = .shared, baseURL: String = "https://sdp-prem-prod.premier-league-prod.pulselive.com") {
        self.session = session
        self.baseURL = baseURL
    }

    func matches(season: String, matchweek: Int? = nil, team: String? = nil, period: String? = nil, limit: Int = 100, next: String? = nil, sort: String? = nil,
                 kickoffAfter: Date? = nil, kickoffBefore: Date? = nil) async throws -> EPLValue {
        try await get(.matches(season: season, matchweek: matchweek, team: team, period: period, limit: limit, next: next, sort: sort, kickoffAfter: kickoffAfter, kickoffBefore: kickoffBefore))
    }
    func match(_ id: String) async throws -> EPLValue { try await get(.match(id)) }
    func events(_ matchID: String) async throws -> EPLValue { try await get(.events(matchID)) }
    func lineups(_ matchID: String) async throws -> EPLValue { try await get(.lineups(matchID)) }
    func stats(_ matchID: String) async throws -> EPLValue { try await get(.stats(matchID)) }
    func officials(_ matchID: String) async throws -> EPLValue { try await get(.officials(matchID)) }
    func commentary(_ matchID: String, limit: Int = 20, next: String? = nil) async throws -> EPLValue { try await get(.commentary(matchID, limit: limit, next: next)) }
    func standings(season: String, live: Bool) async throws -> EPLValue { try await get(.standings(season: season, live: live)) }
    func teams(season: String) async throws -> EPLValue { try await get(.teams(season: season)) }
    func squad(season: String, teamID: String) async throws -> EPLValue { try await get(.squad(season: season, teamID: teamID)) }
    func playerBasic(_ id: String) async throws -> EPLValue { try await get(.playerBasic(id)) }
    func playerSeasonStats(season: String, playerID: String) async throws -> EPLValue { try await get(.playerSeasonStats(season: season, playerID: playerID)) }
    func playersByID(_ ids: [String]) async throws -> EPLValue { try await get(.playersByID(ids)) }

    private func get(_ endpoint: EPLEndpoint) async throws -> EPLValue {
        let url = try endpoint.url(base: baseURL)
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw EPLAPIError.rateLimited(deadline) }
            // Deliberately not `.reloadIgnoringLocalCacheData` — PulseLive is
            // CloudFront-fronted with real Cache-Control headers; honoring the
            // protocol cache policy means URLSession/URLCache can serve short-TTL
            // responses locally instead of re-fetching every poll tick.
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BannerTV/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw EPLAPIError.invalidResponse }
                await EPLRateLimitState.shared.update(from: http)
                if http.statusCode == 429 {
                    let deadline = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw EPLAPIError.rateLimited(deadline)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                if http.statusCode == 400 { throw EPLAPIError.notEnabled(Self.problemDetail(data) ?? "not enabled") }
                if http.statusCode == 404 { throw EPLAPIError.notFound(Self.problemDetail(data) ?? "not found") }
                guard (200...299).contains(http.statusCode) else { throw EPLAPIError.http(http.statusCode, Self.problemDetail(data)) }
                do { return try JSONDecoder().decode(EPLValue.self, from: data) }
                catch {
                    Logger(subsystem: "BannerTV", category: "EPL").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw EPLAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw EPLAPIError.invalidResponse
    }

    /// RFC 7807 `application/problem+json` body: `{"detail":"..."}`. Best-effort — a
    /// malformed error body must not itself throw.
    private static func problemDetail(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
    }

    private static func retryDate(_ value: String?) -> Date {
        if let value, let seconds = Double(value) { return Date().addingTimeInterval(max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return value.flatMap(formatter.date) ?? Date().addingTimeInterval(60)
    }
}
extension EPLPulseLiveClient: EPLPulseLiveClientProtocol {}
