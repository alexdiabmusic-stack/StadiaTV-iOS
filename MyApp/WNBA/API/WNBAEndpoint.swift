import Foundation

/// League ID "10" (Step 2) — centralized here, never scattered through call sites.
/// `cdn.wnba.com`/`stats.wnba.com` are represented by the same endpoint shape;
/// `WNBALiveCDNClient`/`WNBAStatsClient` decide which base URL and headers apply.
nonisolated struct WNBAEndpoint: Sendable {
    static let leagueID = "10"
    let path: String
    var query: [String: String] = [:]
    func url(base: String) throws -> URL {
        guard var components = URLComponents(string: base) else { throw WNBAAPIError.invalidURL }
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw WNBAAPIError.invalidURL }
        return url
    }
    // MARK: - cdn.wnba.com (live)
    static let todaysScoreboard = Self(path: "/static/json/liveData/scoreboard/todaysScoreboard_\(leagueID).json")
    static func liveBoxScore(gameID: String) -> Self { Self(path: "/static/json/liveData/boxscore/boxscore_\(gameID).json") }
    static func livePlayByPlay(gameID: String) -> Self { Self(path: "/static/json/liveData/playbyplay/playbyplay_\(gameID).json") }
    /// Step 8: current-season-only, per the WNBA integration brief — the old
    /// `stats.wnba.com/stats/scheduleleaguev2` route was retired in 2026; this CDN
    /// file is the only current source and never serves a historical season.
    static let staticSchedule = Self(path: "/static/json/staticData/scheduleLeagueV2.json")
    // MARK: - stats.wnba.com (secondary — standings/leaders/rosters only, Step 20/21)
    static func leagueStandingsV3(season: String, seasonType: String) -> Self {
        Self(path: "/stats/leaguestandingsv3", query: ["LeagueID": leagueID, "Season": season, "SeasonType": seasonType, "SeasonYear": ""])
    }
    static func commonPlayerInfo(playerID: String) -> Self { Self(path: "/stats/commonplayerinfo", query: ["PlayerID": playerID, "LeagueID": leagueID]) }
    static func playerCareerStats(playerID: String) -> Self { Self(path: "/stats/playercareerstats", query: ["PlayerID": playerID, "LeagueID": leagueID, "PerMode": "PerGame"]) }
    static func commonTeamRoster(teamID: String, season: String) -> Self {
        Self(path: "/stats/commonteamroster", query: ["LeagueID": leagueID, "TeamID": teamID, "Season": season])
    }
}

nonisolated enum WNBASeason {
    /// WNBA plays a single-calendar-year season (May–Oct), unlike NBA's Oct–Jun
    /// split season — the label is just the year itself, not a hyphenated range.
    /// Not verified against a real schedule response this session (Step: WNBA CDN
    /// unreachable from this sandbox) — if the live payload's own season label
    /// differs, `WNBAProvider` should prefer whatever it reports over this guess.
    static func current(on date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return String(calendar.component(.year, from: date))
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
