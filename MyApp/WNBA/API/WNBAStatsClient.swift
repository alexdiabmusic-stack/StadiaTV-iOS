import Foundation
import OSLog

/// Secondary source for standings/rosters/player profiles ONLY (Step 20/21) — never
/// consulted by the live Game Center poll path. `stats.wnba.com`'s exact response
/// shape is UNVERIFIED this session (unreachable from this sandbox, same as
/// `stats.nba.com` and `cdn.nba.com`); this mirrors `NBAStatsClient`'s header set
/// and defensive backoff on the assumption the two sites share infrastructure, but
/// that assumption itself is disclosed as unconfirmed — see WNBA-INTEGRATION.md.
nonisolated protocol WNBAStatsClientProtocol: Sendable {
    func leagueStandingsV3(season: String, seasonType: String) async throws -> WNBAStandingsResponse
    func commonPlayerInfo(playerID: String) async throws -> WNBAPlayerInfoResponse
    func playerCareerStats(playerID: String) async throws -> WNBAPlayerCareerStatsResponse
    func commonTeamRoster(teamID: String, season: String) async throws -> WNBARosterResponse
}

actor WNBAStatsClient {
    static let shared = WNBAStatsClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?

    init(session: URLSession? = nil, baseURL: String = "https://stats.wnba.com") {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            self.session = URLSession(configuration: configuration)
        }
        self.baseURL = baseURL
    }

    func leagueStandingsV3(season: String, seasonType: String) async throws -> WNBAStandingsResponse { try await get(.leagueStandingsV3(season: season, seasonType: seasonType)) }
    func commonPlayerInfo(playerID: String) async throws -> WNBAPlayerInfoResponse { try await get(.commonPlayerInfo(playerID: playerID)) }
    func playerCareerStats(playerID: String) async throws -> WNBAPlayerCareerStatsResponse { try await get(.playerCareerStats(playerID: playerID)) }
    func commonTeamRoster(teamID: String, season: String) async throws -> WNBARosterResponse { try await get(.commonTeamRoster(teamID: teamID, season: season)) }

    private func get<T: Decodable & Sendable>(_ endpoint: WNBAEndpoint) async throws -> T {
        let url = try endpoint.url(base: baseURL)
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw WNBAAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("https://www.wnba.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://www.wnba.com", forHTTPHeaderField: "Origin")
            request.setValue("stats", forHTTPHeaderField: "x-nba-stats-origin")
            request.setValue("true", forHTTPHeaderField: "x-nba-stats-token")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 BannerTV/1.0", forHTTPHeaderField: "User-Agent")
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
                    retryNotBefore = Date().addingTimeInterval(120)
                    throw WNBAAPIError.blocked(host: "stats.wnba.com", status: 403)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                guard (200...299).contains(http.statusCode) else { throw WNBAAPIError.http(http.statusCode) }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch {
                    Logger(subsystem: "BannerTV", category: "WNBAStats").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw WNBAAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                if [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code) {
                    retryNotBefore = Date().addingTimeInterval(120)
                    throw WNBAAPIError.blocked(host: "stats.wnba.com", status: nil)
                }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw WNBAAPIError.invalidResponse
    }
}
extension WNBAStatsClient: WNBAStatsClientProtocol {}
