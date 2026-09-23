import Foundation

/// Both NBA hosts (`cdn.nba.com`, `stats.nba.com`) are represented by the same
/// endpoint shape; `NBAAPIClient` decides which base URL and headers apply.
nonisolated struct NBAEndpoint: Sendable {
    let path: String
    var query: [String: String] = [:]
    func url(base: String) throws -> URL {
        guard var components = URLComponents(string: base) else { throw NBAAPIError.invalidURL }
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw NBAAPIError.invalidURL }
        return url
    }
    // MARK: - cdn.nba.com (live)
    static let todaysScoreboard = Self(path: "/static/json/liveData/scoreboard/todaysScoreboard_00.json")
    static func liveBoxScore(gameID: String) -> Self { Self(path: "/static/json/liveData/boxscore/boxscore_\(gameID).json") }
    static func livePlayByPlay(gameID: String) -> Self { Self(path: "/static/json/liveData/playbyplay/playbyplay_\(gameID).json") }
    /// Current-season-only static schedule. Shares `NBAScheduleResponse`'s
    /// `leagueSchedule.gameDates[].games` envelope with `scheduleLeagueV2(season:)`
    /// below, so no separate DTO or mapper is needed for this route.
    static let staticSchedule = Self(path: "/static/json/staticData/scheduleLeagueV2_1.json")
    // MARK: - stats.nba.com (secondary)
    static func scheduleLeagueV2(season: String) -> Self { Self(path: "/stats/scheduleleaguev2", query: ["LeagueID": "00", "Season": season]) }
    static func leagueStandingsV3(season: String, seasonType: String) -> Self {
        Self(path: "/stats/leaguestandingsv3", query: ["LeagueID": "00", "Season": season, "SeasonType": seasonType, "SeasonYear": ""])
    }
    static func scoreboardV3(date: String) -> Self { Self(path: "/stats/scoreboardv3", query: ["LeagueID": "00", "GameDate": date, "DayOffset": "0"]) }
    static func playByPlayV3(gameID: String) -> Self { Self(path: "/stats/playbyplayv3", query: ["GameID": gameID, "StartPeriod": "0", "EndPeriod": "14"]) }
    static func commonPlayerInfo(playerID: String) -> Self { Self(path: "/stats/commonplayerinfo", query: ["PlayerID": playerID, "LeagueID": "00"]) }
    static func playerCareerStats(playerID: String) -> Self { Self(path: "/stats/playercareerstats", query: ["PlayerID": playerID, "LeagueID": "00", "PerMode": "PerGame"]) }
    static func commonTeamRoster(teamID: String, season: String) -> Self {
        Self(path: "/stats/commonteamroster", query: ["LeagueID": "00", "TeamID": teamID, "Season": season])
    }
}

nonisolated enum NBASeason {
    /// NBA seasons run Oct–Jun; label format is "2025-26".
    static func current(on date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        let startYear = month >= 8 ? year : year - 1
        let shortEnd = String(format: "%02d", (startYear + 1) % 100)
        return "\(startYear)-\(shortEnd)"
    }
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let f = ISO8601DateFormatter()
        if let date = f.date(from: value) { return date }
        f.formatOptions.insert(.withFractionalSeconds); return f.date(from: value)
    }
}
