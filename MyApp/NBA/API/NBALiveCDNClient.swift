import Foundation
import OSLog

/// Primary live-data source. `cdn.nba.com` is reliable and cache-friendly, so this
/// client leans on standard HTTP caching (ETag/Last-Modified via `URLCache`) instead
/// of defeating it with cache-busting query params. A 304 is a normal, cheap success.
nonisolated protocol NBALiveCDNClientProtocol: Sendable {
    func todaysScoreboard() async throws -> NBAScoreboardResponse
    func boxScore(gameID: String) async throws -> NBABoxScoreResponse
    func playByPlay(gameID: String) async throws -> NBAPlayByPlayResponse
    func scheduleLeagueV2() async throws -> NBAScheduleResponse
}

actor NBALiveCDNClient {
    static let shared = NBALiveCDNClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?

    init(session: URLSession? = nil, baseURL: String = "https://cdn.nba.com") {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .useProtocolCachePolicy
            configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 32 * 1024 * 1024, diskPath: "BannerTV/NBA/http-cache")
            self.session = URLSession(configuration: configuration)
        }
        self.baseURL = baseURL
    }

    func todaysScoreboard() async throws -> NBAScoreboardResponse { try await get(.todaysScoreboard) }
    func boxScore(gameID: String) async throws -> NBABoxScoreResponse { try await get(.liveBoxScore(gameID: gameID)) }
    func playByPlay(gameID: String) async throws -> NBAPlayByPlayResponse { try await get(.livePlayByPlay(gameID: gameID)) }
    func scheduleLeagueV2() async throws -> NBAScheduleResponse { try await get(.staticSchedule) }

    private func get<T: Decodable & Sendable>(_ endpoint: NBAEndpoint) async throws -> T {
        let url = try endpoint.url(base: baseURL)
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw NBAAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BannerTV/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw NBAAPIError.invalidResponse }
                if http.statusCode == 429 {
                    let deadline = NBARetry.date(from: http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw NBAAPIError.rateLimited(deadline)
                }
                if http.statusCode == 403 {
                    // An Akamai edge block on `/static/` is per-IP and persistent, not
                    // transient — back off hard rather than hammering it every poll tick.
                    retryNotBefore = Date().addingTimeInterval(300)
                    throw NBAAPIError.blocked(host: "cdn.nba.com", status: 403)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                // 304 arrives with the cached body already substituted by URLLoadingSystem.
                guard (200...299).contains(http.statusCode) else { throw NBAAPIError.http(http.statusCode) }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch {
                    Logger(subsystem: "BannerTV", category: "NBA").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw NBAAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw NBAAPIError.invalidResponse
    }
}
extension NBALiveCDNClient: NBALiveCDNClientProtocol {}

nonisolated enum NBARetry {
    static func date(from headerValue: String?) -> Date {
        if let headerValue, let seconds = Double(headerValue) { return Date().addingTimeInterval(max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return headerValue.flatMap(formatter.date) ?? Date().addingTimeInterval(60)
    }
}
