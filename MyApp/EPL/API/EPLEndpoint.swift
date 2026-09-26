import Foundation

/// Centralized SDP route construction — every EPL network call is built here so the
/// allow-listed path/query shapes never get hand-rolled at call sites. All routes are
/// verified against the live gateway (see EPL-INTEGRATION.md), not assumed from docs.
nonisolated struct EPLEndpoint: Sendable {
    let path: String
    var query: [String: String] = [:]

    func url(base: String = "https://sdp-prem-prod.premier-league-prod.pulselive.com") throws -> URL {
        guard var components = URLComponents(string: base) else { throw EPLAPIError.invalidURL }
        components.path = path
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw EPLAPIError.invalidURL }
        return url
    }

    // MARK: Matches

    static func matches(season: String, matchweek: Int? = nil, team: String? = nil, period: String? = nil, limit: Int = 100, next: String? = nil, sort: String? = nil,
                        kickoffAfter: Date? = nil, kickoffBefore: Date? = nil) -> Self {
        var query = ["competition": EPLSeasonResolver.competitionID, "season": season, "_limit": String(limit)]
        query["matchweek"] = matchweek.map(String.init)
        query["team"] = team
        query["period"] = period
        query["_sort"] = sort
        query["_next"] = next
        // URLComponents percent-encodes the literal `>`/`<` in these query key names.
        query["kickoff>"] = kickoffAfter.map(EPLDate.day)
        query["kickoff<"] = kickoffBefore.map(EPLDate.day)
        return Self(path: "/api/v2/matches", query: query)
    }

    static func match(_ id: String) -> Self { Self(path: "/api/v2/matches/\(id)") }
    static func events(_ matchID: String) -> Self { Self(path: "/api/v1/matches/\(matchID)/events") }
    static func lineups(_ matchID: String) -> Self { Self(path: "/api/v3/matches/\(matchID)/lineups") }
    static func stats(_ matchID: String) -> Self { Self(path: "/api/v3/matches/\(matchID)/stats") }
    static func officials(_ matchID: String) -> Self { Self(path: "/api/v1/matches/\(matchID)/officials") }
    static func commentary(_ matchID: String, limit: Int = 20, next: String? = nil) -> Self {
        var query = ["_limit": String(limit), "_sort": "timestamp:desc"]
        query["_next"] = next
        return Self(path: "/api/v1/matches/\(matchID)/commentary", query: query)
    }

    // MARK: Standings

    static func standings(season: String, live: Bool) -> Self {
        Self(path: "/api/v5/competitions/\(EPLSeasonResolver.competitionID)/seasons/\(season)/standings", query: ["live": live ? "true" : "false"])
    }

    // MARK: Teams & squads

    static func teams(season: String, limit: Int = 20) -> Self {
        Self(path: "/api/v1/competitions/\(EPLSeasonResolver.competitionID)/seasons/\(season)/teams", query: ["_limit": String(limit)])
    }
    static func allTeams(limit: Int = 60) -> Self {
        Self(path: "/api/v1/competitions/\(EPLSeasonResolver.competitionID)/teams", query: ["_limit": String(limit)])
    }
    static func squad(season: String, teamID: String) -> Self {
        Self(path: "/api/v2/competitions/\(EPLSeasonResolver.competitionID)/seasons/\(season)/teams/\(teamID)/squad")
    }
    static func teamsByID(_ ids: [String]) -> Self { Self(path: "/api/v2/teams-by-id", query: ["id": ids.joined(separator: ",")]) }

    // MARK: Players

    static func playerBasic(_ id: String) -> Self { Self(path: "/api/v1/players/\(id)/basic") }
    static func player(_ id: String) -> Self { Self(path: "/api/v1/players/\(id)") }
    static func playersByID(_ ids: [String]) -> Self { Self(path: "/api/v2/players-by-id", query: ["id": ids.joined(separator: ",")]) }
    static func playerSeasonStats(season: String, playerID: String) -> Self {
        Self(path: "/api/v1/competitions/\(EPLSeasonResolver.competitionID)/seasons/\(season)/players/\(playerID)/stats")
    }
}

nonisolated enum EPLDate {
    /// Formats a date as the plain `yyyy-MM-dd` day PulseLive expects for `kickoff>`/`kickoff<` range filters.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    /// Parses PulseLive's `"yyyy-MM-dd HH:mm:ss"` kickoff strings (observed, not ISO8601).
    static func parseKickoff(_ value: String?) -> Date? {
        guard let value else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: value)
    }
    /// Parses match-event timestamps, e.g. `"20260920T140902+0100"`.
    static func parseEventTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmssZ"
        return f.date(from: value)
    }
    /// Parses commentary timestamps, e.g. `"2026-09-20 15:58:19"` (no timezone offset —
    /// observed alongside UK kickoff times, so treated as Europe/London wall-clock time).
    static func parseCommentaryTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: value)
    }
}
