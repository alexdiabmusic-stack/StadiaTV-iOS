import Foundation
import OSLog

nonisolated protocol MLBAPIClientProtocol: Sendable {
    func schedule(date: Date) async throws -> MLBScheduleResponse
    func schedule(startDate: Date, endDate: Date) async throws -> MLBScheduleResponse
    func liveFeed(gamePk: Int) async throws -> MLBGameFeedResponse
    func status(gamePk: Int) async throws -> MLBGameFeedResponse
    func playByPlay(gamePk: Int) async throws -> MLBPlayByPlayResponse
    func linescore(gamePk: Int) async throws -> MLBLineScoreResponse
    func boxscore(gamePk: Int) async throws -> MLBBoxscoreResponse
    func winProbability(gamePk: Int) async throws -> MLBWinProbabilityResponse
    func contextMetrics(gamePk: Int) async throws -> MLBContextMetricsResponse
    func content(gamePk: Int) async throws -> MLBContentResponse
    func teams() async throws -> MLBTeamResponse
    func team(teamID: Int) async throws -> MLBTeamResponse
    func roster(teamID: Int) async throws -> MLBRosterResponse
    func player(playerID: Int) async throws -> MLBPersonResponse
    func standings(season: Int) async throws -> MLBStandingsResponse
}
actor MLBAPIClient {
    static let shared = MLBAPIClient()
    private let session: URLSession
    private let baseURL: String
    private var retryNotBefore: Date?
    init(session: URLSession = .shared, baseURL: String = "https://statsapi.mlb.com") {
        self.session = session; self.baseURL = baseURL
    }
    func schedule(date: Date) async throws -> MLBScheduleResponse { try await get(.schedule(start: date)) }
    func schedule(startDate: Date, endDate: Date) async throws -> MLBScheduleResponse { try await get(.schedule(start: startDate, end: endDate)) }
    func liveFeed(gamePk: Int) async throws -> MLBGameFeedResponse { try await get(.feed(gamePk)) }
    func status(gamePk: Int) async throws -> MLBGameFeedResponse { try await get(.feed(gamePk, statusOnly: true)) }
    func playByPlay(gamePk: Int) async throws -> MLBPlayByPlayResponse { try await get(.game(gamePk, resource: "playByPlay")) }
    func linescore(gamePk: Int) async throws -> MLBLineScoreResponse { try await get(.game(gamePk, resource: "linescore")) }
    func boxscore(gamePk: Int) async throws -> MLBBoxscoreResponse { try await get(.game(gamePk, resource: "boxscore")) }
    func winProbability(gamePk: Int) async throws -> MLBWinProbabilityResponse { try await get(MLBEndpoint(path: "/api/v1/game/\(gamePk)/winProbability", query: ["fields": "about,atBatIndex,homeTeamWinProbability"])) }
    func contextMetrics(gamePk: Int) async throws -> MLBContextMetricsResponse { try await get(.game(gamePk, resource: "contextMetrics")) }
    func content(gamePk: Int) async throws -> MLBContentResponse { try await get(.game(gamePk, resource: "content")) }
    func teams() async throws -> MLBTeamResponse { try await get(MLBEndpoint(path: "/api/v1/teams", query: ["sportId": "1"])) }
    func team(teamID: Int) async throws -> MLBTeamResponse { try await get(MLBEndpoint(path: "/api/v1/teams/\(teamID)")) }
    func roster(teamID: Int) async throws -> MLBRosterResponse { try await get(MLBEndpoint(path: "/api/v1/teams/\(teamID)/roster", query: ["hydrate": "person"])) }
    func player(playerID: Int) async throws -> MLBPersonResponse { try await get(MLBEndpoint(path: "/api/v1/people/\(playerID)", query: ["hydrate": "stats(group=[hitting,pitching],type=[season])"])) }
    func standings(season: Int) async throws -> MLBStandingsResponse {
        let leagues: MLBValue = try await get(MLBEndpoint(path: "/api/v1/leagues", query: ["sportId": "1"]))
        let ids = leagues["leagues"].array.filter { $0["active"].bool == true && $0["sport"]["id"].int == 1 }.compactMap { $0["id"].string }
        guard !ids.isEmpty else { throw MLBAPIError.invalidResponse }
        return try await get(MLBEndpoint(path: "/api/v1/standings", query: ["leagueId": ids.joined(separator: ","), "season": String(season), "standingsTypes": "regularSeason", "hydrate": "team,division"]))
    }
    private func get<T: Decodable & Sendable>(_ endpoint: MLBEndpoint) async throws -> T {
        let url = try endpoint.url(base: baseURL)
        for attempt in 0...2 {
            try Task.checkCancellation()
            if let deadline = retryNotBefore, deadline > Date() { throw MLBAPIError.rateLimited(deadline) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("BannerTV/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw MLBAPIError.invalidResponse }
                if http.statusCode == 429 {
                    let deadline = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"))
                    retryNotBefore = deadline
                    throw MLBAPIError.rateLimited(deadline)
                }
                if (500...599).contains(http.statusCode), attempt < 2 {
                    try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    continue
                }
                guard (200...299).contains(http.statusCode) else { throw MLBAPIError.http(http.statusCode) }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch {
                    Logger(subsystem: "BannerTV", category: "MLB").error("Decode \(endpoint.path, privacy: .public): \(String(describing: error), privacy: .public)")
                    throw MLBAPIError.decoding(String(describing: error))
                }
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                guard attempt < 2 else { throw error }
                try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
            }
        }
        throw MLBAPIError.invalidResponse
    }
    private static func retryDate(_ value: String?) -> Date {
        if let value, let seconds = Double(value) { return Date().addingTimeInterval(max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return value.flatMap(formatter.date) ?? Date().addingTimeInterval(60)
    }
}
extension MLBAPIClient: MLBAPIClientProtocol {}
