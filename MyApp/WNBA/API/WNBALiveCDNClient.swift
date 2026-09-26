import Foundation
import OSLog

/// Primary live-data source (Step: "Primary WNBA source"). Deliberately has no
/// stats.wnba.com fallback for any of these four routes — the WNBA integration
/// brief is explicit that live score/PBP must never depend on Stats availability
/// (Step 21/26), unlike `NBAAPIClient`'s CDN→stats fallback for NBA. A CDN failure
/// here surfaces as an error the Game Center degrades around, not a silent switch
/// to a more fragile secondary host.
nonisolated protocol WNBALiveCDNClientProtocol: Sendable {
    func todaysScoreboard() async throws -> WNBAScoreboardResponse
    func boxScore(gameID: String) async throws -> WNBABoxScoreResponse
    func playByPlay(gameID: String) async throws -> WNBAPlayByPlayResponse
    func scheduleLeagueV2() async throws -> WNBAScheduleResponse
}

actor WNBALiveCDNClient {
    static let shared = WNBALiveCDNClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?

    init(session: URLSession? = nil, baseURL: String = "https://cdn.wnba.com") {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024, diskPath: "BannerTV/WNBA/http-cache")
            self.session = URLSession(configuration: configuration)
        }
        self.baseURL = baseURL
    }

    func todaysScoreboard() async throws -> WNBAScoreboardResponse { try await get(.todaysScoreboard) }
    func boxScore(gameID: String) async throws -> WNBABoxScoreResponse { try await get(.liveBoxScore(gameID: gameID)) }
    func playByPlay(gameID: String) async throws -> WNBAPlayByPlayResponse { try await get(.livePlayByPlay(gameID: gameID)) }
    func scheduleLeagueV2() async throws -> WNBAScheduleResponse { try await get(.staticSchedule) }

    private func get<T: Decodable & Sendable>(_ endpoint: WNBAEndpoint) async throws -> T {
        let url = try endpoint.url(base: baseURL)
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw WNBAAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BannerTV/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw WNBAAPIError.invalidResponse }
                if http.statusCode == 429 {
                    let deadline = WNBARetry.date(from: http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw WNBAAPIError.rateLimited(deadline)
                }
                if http.statusCode == 403 {
                    // Same edge-block pattern the NBA CDN exhibits — per-IP and
                    // persistent, not transient; back off hard rather than retrying every poll.
                    retryNotBefore = Date().addingTimeInterval(300)
                    throw WNBAAPIError.blocked(host: "cdn.wnba.com", status: 403)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                guard (200...299).contains(http.statusCode) else { throw WNBAAPIError.http(http.statusCode) }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch {
                    Logger(subsystem: "BannerTV", category: "WNBA").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw WNBAAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw WNBAAPIError.invalidResponse
    }
}
extension WNBALiveCDNClient: WNBALiveCDNClientProtocol {}

nonisolated enum WNBARetry {
    static func date(from headerValue: String?) -> Date {
        if let headerValue, let seconds = Double(headerValue) { return Date().addingTimeInterval(max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return headerValue.flatMap(formatter.date) ?? Date().addingTimeInterval(60)
    }
}
