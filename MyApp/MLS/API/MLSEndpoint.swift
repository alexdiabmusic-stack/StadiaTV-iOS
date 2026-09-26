import Foundation

/// Centralized route construction for the MLS Sportec stats API — every network
/// call is built here so the verified path/query shapes never get hand-rolled at
/// call sites. All routes are verified against the live gateway on 2026-09-23 (see
/// MLS-INTEGRATION.md), not assumed from any documentation — MLS publishes none.
/// Base host has **no `/v1` prefix**; the entire documented `/v1/*` + Opta-ID route
/// family 404s live and is not used anywhere in this file.
nonisolated struct MLSEndpoint: Sendable {
    let path: String
    var query: [String: String] = [:]

    func url(base: String = "https://stats-api.mlssoccer.com") throws -> URL {
        guard var components = URLComponents(string: base) else { throw MLSAPIError.invalidURL }
        components.path = path
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw MLSAPIError.invalidURL }
        return url
    }

    // MARK: Discovery

    static func competitions() -> Self { Self(path: "/competitions") }
    static func seasons(competitionID: String) -> Self { Self(path: "/competitions/\(competitionID)/seasons") }
    static func clubs(competitionID: String, seasonID: String, perPage: Int = 100) -> Self {
        Self(path: "/clubs/competitions/\(competitionID)/seasons/\(seasonID)", query: ["per_page": String(perPage)])
    }

    // MARK: Schedule / match

    /// `match_date[gte]`/`match_date[lte]` are literal MLS query key names (square
    /// brackets and all) — `URLComponents` percent-encodes them correctly when
    /// building the final URL, same trick as EPLEndpoint's `kickoff>`/`kickoff<`.
    static func schedule(seasonID: String, from: String? = nil, to: String? = nil, competitionID: String? = nil,
                          teamID: String? = nil, perPage: Int = 100, sort: String? = nil, pageToken: String? = nil) -> Self {
        var query: [String: String] = ["per_page": String(perPage)]
        query["match_date[gte]"] = from
        query["match_date[lte]"] = to
        query["competition_id"] = competitionID
        query["team_id"] = teamID
        query["sort"] = sort
        query["page_token"] = pageToken
        return Self(path: "/matches/seasons/\(seasonID)", query: query)
    }

    static func match(_ matchID: String) -> Self { Self(path: "/matches/\(matchID)") }

    /// `event` filters the response to one structured bucket (`goals`, `penalties`,
    /// `cards`, `substitutions`); omitted, it returns every bucket together — that
    /// unfiltered form is what the Game Centre timeline actually polls.
    static func keyEvents(_ matchID: String, event: String? = nil, perPage: Int? = nil) -> Self {
        var query: [String: String] = [:]
        query["event"] = event
        query["per_page"] = perPage.map(String.init)
        return Self(path: "/matches/\(matchID)/key_events", query: query)
    }

    static func commentary(_ matchID: String, language: String = "en", pageToken: String? = nil) -> Self {
        var query = ["language": language]
        query["page_token"] = pageToken
        return Self(path: "/matches/\(matchID)/commentary", query: query)
    }

    // MARK: Standings

    /// `category=conference` returns the Eastern/Western split; omitted, it returns
    /// the single combined/Supporters'-Shield-order table. `type` accepts `table`
    /// (default), `home`, `away`, `shape` — confirmed via the live validation error.
    static func standings(competitionID: String, seasonID: String, category: String? = nil, type: String? = nil, isLive: Bool? = nil) -> Self {
        var query: [String: String] = [:]
        query["category"] = category
        query["type"] = type
        query["is_live"] = isLive.map { $0 ? "true" : "false" }
        return Self(path: "/competitions/\(competitionID)/seasons/\(seasonID)/standings", query: query)
    }

    // MARK: Statistics

    /// `scope` accepts `match` (default), `firstHalf`, `secondHalf`, `firstHalfExtra`,
    /// `secondHalfExtra`, `penalty`, `all` — confirmed via the live validation error.
    static func teamMatchStats(_ matchID: String, scope: String? = nil) -> Self {
        var query: [String: String] = [:]
        query["scope"] = scope
        return Self(path: "/statistics/clubs/matches/\(matchID)", query: query)
    }

    static func playerMatchStats(_ matchID: String, perPage: Int = 100) -> Self {
        Self(path: "/statistics/players/matches/\(matchID)", query: ["per_page": String(perPage)])
    }

    static func clubSeasonStats(competitionID: String, seasonID: String, perPage: Int = 100) -> Self {
        Self(path: "/statistics/clubs/competitions/\(competitionID)/seasons/\(seasonID)", query: ["per_page": String(perPage)])
    }

    static func playerSeasonStats(competitionID: String, seasonID: String, perPage: Int = 100) -> Self {
        Self(path: "/statistics/players/competitions/\(competitionID)/seasons/\(seasonID)", query: ["per_page": String(perPage)])
    }

    static func playerMatchLog(personID: String, competitionID: String? = nil, pageToken: String? = nil) -> Self {
        var query: [String: String] = [:]
        query["competition_id"] = competitionID
        query["page_token"] = pageToken
        return Self(path: "/statistics/players/\(personID)/matches", query: query)
    }
}

nonisolated enum MLSDate {
    /// MLS timestamps appear both with fractional seconds (`key_events.event_time`,
    /// `kickoff_time`: `"2026-09-21T01:14:51.314Z"`) and without (`commentary.event_time`,
    /// `planned_kickoff_time`: `"2026-09-20T23:00:00Z"`) — try fractional first, fall back.
    static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    /// Formats a date as the plain `yyyy-MM-dd` day the schedule endpoint's
    /// `match_date[gte]`/`match_date[lte]` filters expect.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Extracts the base minute from MLS's own stoppage-formatted `minute_of_play`
    /// (`"90+7"`, `"45+2"`, `"12"`) — the provider's clock is authoritative, this
    /// never recomputes it from wall-clock time.
    static func baseMinute(_ minuteOfPlay: String?) -> Int? {
        guard let minuteOfPlay else { return nil }
        guard let base = minuteOfPlay.split(separator: "+", maxSplits: 1).first else { return nil }
        return Int(base)
    }
}
