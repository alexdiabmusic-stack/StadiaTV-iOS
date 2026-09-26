import Foundation
import OSLog

nonisolated protocol MLSStatsClientProtocol: Sendable {
    func competitions() async throws -> MLSValue
    func seasons(competitionID: String) async throws -> MLSValue
    func clubs(competitionID: String, seasonID: String) async throws -> MLSValue
    func schedule(seasonID: String, from: String?, to: String?, competitionID: String?, teamID: String?, pageToken: String?) async throws -> MLSValue
    func match(_ matchID: String) async throws -> MLSValue
    func keyEvents(_ matchID: String, event: String?, perPage: Int?) async throws -> MLSValue
    func commentary(_ matchID: String, pageToken: String?) async throws -> MLSValue
    func standings(competitionID: String, seasonID: String, category: String?, isLive: Bool?) async throws -> MLSValue
    func teamMatchStats(_ matchID: String) async throws -> MLSValue
    func playerMatchStats(_ matchID: String) async throws -> MLSValue
    func clubSeasonStats(competitionID: String, seasonID: String) async throws -> MLSValue
    func playerSeasonStats(competitionID: String, seasonID: String) async throws -> MLSValue
    func playerMatchLog(personID: String, competitionID: String?, pageToken: String?) async throws -> MLSValue
}

/// `stats-api.mlssoccer.com` is undocumented private web infrastructure (see
/// MLS-INTEGRATION.md for the licensing note and the live-endpoint discovery that
/// superseded the dead `/v1` + Opta-ID route family) — no API key, no auth observed.
/// This client owns retry/backoff and 429 cooldown so none of that leaks into
/// mapping or UI code, mirroring `EPLPulseLiveClient`'s shape.
actor MLSStatsClient {
    static let shared = MLSStatsClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?

    init(session: URLSession = .shared, baseURL: String = "https://stats-api.mlssoccer.com") {
        self.session = session
        self.baseURL = baseURL
    }

    func competitions() async throws -> MLSValue { try await get(.competitions()) }
    func seasons(competitionID: String) async throws -> MLSValue { try await get(.seasons(competitionID: competitionID)) }
    func clubs(competitionID: String, seasonID: String) async throws -> MLSValue { try await get(.clubs(competitionID: competitionID, seasonID: seasonID)) }
    func schedule(seasonID: String, from: String? = nil, to: String? = nil, competitionID: String? = nil, teamID: String? = nil, pageToken: String? = nil) async throws -> MLSValue {
        try await get(.schedule(seasonID: seasonID, from: from, to: to, competitionID: competitionID, teamID: teamID, pageToken: pageToken))
    }
    func match(_ matchID: String) async throws -> MLSValue { try await get(.match(matchID)) }
    func keyEvents(_ matchID: String, event: String? = nil, perPage: Int? = nil) async throws -> MLSValue { try await get(.keyEvents(matchID, event: event, perPage: perPage)) }
    func commentary(_ matchID: String, pageToken: String? = nil) async throws -> MLSValue { try await get(.commentary(matchID, pageToken: pageToken)) }
    func standings(competitionID: String, seasonID: String, category: String? = nil, isLive: Bool? = nil) async throws -> MLSValue {
        try await get(.standings(competitionID: competitionID, seasonID: seasonID, category: category, isLive: isLive))
    }
    func teamMatchStats(_ matchID: String) async throws -> MLSValue { try await get(.teamMatchStats(matchID)) }
    func playerMatchStats(_ matchID: String) async throws -> MLSValue { try await get(.playerMatchStats(matchID)) }
    func clubSeasonStats(competitionID: String, seasonID: String) async throws -> MLSValue { try await get(.clubSeasonStats(competitionID: competitionID, seasonID: seasonID)) }
    func playerSeasonStats(competitionID: String, seasonID: String) async throws -> MLSValue { try await get(.playerSeasonStats(competitionID: competitionID, seasonID: seasonID)) }
    func playerMatchLog(personID: String, competitionID: String? = nil, pageToken: String? = nil) async throws -> MLSValue {
        try await get(.playerMatchLog(personID: personID, competitionID: competitionID, pageToken: pageToken))
    }

    private func get(_ endpoint: MLSEndpoint) async throws -> MLSValue {
        let url = try endpoint.url(base: baseURL)
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw MLSAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BannerTV/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw MLSAPIError.invalidResponse }
                if http.statusCode == 429 {
                    let deadline = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw MLSAPIError.rateLimited(deadline)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                if http.statusCode == 400 { throw MLSAPIError.badRequest(Self.errorDetail(data) ?? "bad request") }
                if http.statusCode == 404 { throw MLSAPIError.notFound(Self.errorDetail(data) ?? "not found") }
                guard (200...299).contains(http.statusCode) else { throw MLSAPIError.http(http.statusCode, Self.errorDetail(data)) }
                do { return try JSONDecoder().decode(MLSValue.self, from: data) }
                catch {
                    Logger(subsystem: "BannerTV", category: "MLS").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw MLSAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw MLSAPIError.invalidResponse
    }

    /// MLS's error body shape: `{"error_code":"MLS-00N-ERR","message":"...","error":"..."}`.
    /// Best-effort — a malformed error body must not itself throw.
    private static func errorDetail(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
    }

    private static func retryDate(_ value: String?) -> Date {
        if let value, let seconds = Double(value) { return Date().addingTimeInterval(max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return value.flatMap(formatter.date) ?? Date().addingTimeInterval(60)
    }
}
extension MLSStatsClient: MLSStatsClientProtocol {}
