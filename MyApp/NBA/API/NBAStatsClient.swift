import Foundation
import OSLog

/// Secondary source for schedule, standings, non-today scoreboards, and play-by-play
/// fallback. `stats.nba.com` is more fragile than the CDN and can reject requests
/// that don't look like they came from a browser, so this client sets a realistic
/// header set. It does not rotate IPs or otherwise attempt to bypass access controls —
/// it just avoids looking like an obviously non-browser client, and backs off hard
/// on 403/429 rather than retrying aggressively.
nonisolated protocol NBAStatsClientProtocol: Sendable {
    func scheduleLeagueV2(season: String) async throws -> NBAScheduleResponse
    func leagueStandingsV3(season: String, seasonType: String) async throws -> NBAStandingsResponse
    func scoreboardV3(date: Date) async throws -> NBAScoreboardV3Response
    func playByPlayV3(gameID: String) async throws -> NBAPlayByPlayV3Response
    func commonPlayerInfo(playerID: String) async throws -> NBAPlayerInfoResponse
    func playerCareerStats(playerID: String) async throws -> NBAPlayerCareerStatsResponse
    func commonTeamRoster(teamID: String, season: String) async throws -> NBARosterResponse
}

actor NBAStatsClient {
    static let shared = NBAStatsClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?

    init(session: URLSession? = nil, baseURL: String = "https://stats.nba.com") {
        if let session {
            self.session = session
        } else {
            // A dedicated short timeout: this host is observed to silently drop
            // connections from some networks rather than returning an error, and the
            // default 60s system timeout would turn every such call into a long hang.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            self.session = URLSession(configuration: configuration)
        }
        self.baseURL = baseURL
    }

    func scheduleLeagueV2(season: String) async throws -> NBAScheduleResponse { try await get(.scheduleLeagueV2(season: season)) }
    func leagueStandingsV3(season: String, seasonType: String) async throws -> NBAStandingsResponse { try await get(.leagueStandingsV3(season: season, seasonType: seasonType)) }
    func scoreboardV3(date: Date) async throws -> NBAScoreboardV3Response { try await get(.scoreboardV3(date: NBASeason.day(date))) }
    func playByPlayV3(gameID: String) async throws -> NBAPlayByPlayV3Response { try await get(.playByPlayV3(gameID: gameID)) }
    func commonPlayerInfo(playerID: String) async throws -> NBAPlayerInfoResponse { try await get(.commonPlayerInfo(playerID: playerID)) }
    func playerCareerStats(playerID: String) async throws -> NBAPlayerCareerStatsResponse { try await get(.playerCareerStats(playerID: playerID)) }
    func commonTeamRoster(teamID: String, season: String) async throws -> NBARosterResponse { try await get(.commonTeamRoster(teamID: teamID, season: season)) }

    private func get<T: Decodable & Sendable>(_ endpoint: NBAEndpoint) async throws -> T {
        let url = try endpoint.url(base: baseURL)
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw NBAAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://www.nba.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://www.nba.com", forHTTPHeaderField: "Origin")
            request.setValue("stats", forHTTPHeaderField: "x-nba-stats-origin")
            request.setValue("true", forHTTPHeaderField: "x-nba-stats-token")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BannerTV/1.0", forHTTPHeaderField: "User-Agent")
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
                    // stats.nba.com throttling/blocking — back off without retrying immediately.
                    retryNotBefore = Date().addingTimeInterval(120)
                    throw NBAAPIError.blocked(host: "stats.nba.com", status: 403)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                guard (200...299).contains(http.statusCode) else { throw NBAAPIError.http(http.statusCode) }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch {
                    Logger(subsystem: "BannerTV", category: "NBAStats").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw NBAAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                // This host has been observed to accept a TCP/TLS connection and then
                // never respond at all — a connectivity-layer block, not a transient
                // blip. Retrying just repeats the same multi-second hang three times.
                if [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
                    retryNotBefore = Date().addingTimeInterval(120)
                    throw NBAAPIError.blocked(host: "stats.nba.com", status: nil)
                }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw NBAAPIError.invalidResponse
    }
}
extension NBAStatsClient: NBAStatsClientProtocol {}
