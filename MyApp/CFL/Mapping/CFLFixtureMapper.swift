import Foundation

/// `game_type_id` → CFL terminology. Values 0/1/6 are unambiguous from the id alone
/// (verified live: 0 pairs with a negative `week` for preseason, 1 is regular season,
/// 6 is the single Grey Cup fixture). 2/3 (conference semi-finals) and 4/5 (conference
/// finals) are NOT distinguishable from the id alone — `label` resolves East/West from
/// the actual participating teams' `team_zone` once qualifiers are known, rather than
/// guessing which numeric id maps to which conference.
nonisolated enum CFLGameTypeMapper {
    static func type(gameTypeID: Int) -> CFLGameType {
        switch gameTypeID {
        case 0: .preseason
        case 1: .regularSeason
        case 2, 3: .divisionSemiFinal
        case 4, 5: .divisionFinal
        case 6: .greyCup
        default: .unknown(gameTypeID)
        }
    }
    static func label(_ type: CFLGameType, homeZone: String?, awayZone: String?) -> String {
        func conference(_ zone: String?) -> String? {
            switch zone?.lowercased() {
            case "eastern": return "EAST"
            case "western": return "WEST"
            default: return nil
            }
        }
        let side = conference(homeZone) ?? conference(awayZone)
        switch type {
        case .preseason: return "PRESEASON"
        case .regularSeason: return "REGULAR SEASON"
        case .divisionSemiFinal: return side.map { "\($0) SEMI-FINAL" } ?? "DIVISION SEMI-FINAL"
        case .divisionFinal: return side.map { "\($0) FINAL" } ?? "DIVISION FINAL"
        case .greyCup: return "GREY CUP"
        case .unknown: return "CFL"
        }
    }
}
/// `echo.pims.cfl.ca` fixtures never carry down/distance/field-position/play data
/// (verified live against both scheduled and finished fixtures) — `drives`/`plays`
/// stay empty here by design; only a wired-in `CFLLivePlayProvider` populates them.
nonisolated enum CFLFixtureMapper {
    static func team(_ raw: CFLValue) -> FootballTeamState? {
        guard let id = raw["ID"].string else { return nil }
        let abbreviation = raw["abbreviation"].string ?? "CFL"
        // `logo_svg` is an inline SVG data URI (verified live) — the app's existing team-logo
        // pipeline only rasterizes PNG/JPG from a CDN URL, so this deliberately resolves to no
        // logo rather than passing an unrenderable data URI through (disclosed gap).
        return FootballTeamState(id: id, name: raw["clubname"].string ?? raw["name"].string ?? abbreviation,
            abbreviation: abbreviation, logo: nil, score: nil, quarters: [:], possession: false)
    }
    static func status(_ raw: String?, start: Date, now: Date) -> FootballGameStatus {
        guard let raw else { return start > now ? .scheduled : .live }
        switch raw.uppercased() {
        case "FINISHED", "FINAL": return .final
        case "IN PROGRESS", "INPROGRESS", "LIVE": return .live
        case "HALFTIME": return .halftime
        case "POSTPONED": return .postponed
        case "CANCELLED", "CANCELED": return .cancelled
        case "SCHEDULED", "PREGAME": return .pregame
        default: return .unknown
        }
    }
    static func game(_ fixture: CFLValue, teams: [String: CFLValue], venues: [String: CFLValue], seasonID: Int, year: Int, now: Date = Date()) -> CFLGameState? {
        guard let id = fixture["ID"].string, let startAt = fixture["start_at"].string, let start = date(startAt),
              let homeID = fixture["home_team_id"].string, let awayID = fixture["away_team_id"].string,
              var home = team(teams[homeID] ?? .null), var away = team(teams[awayID] ?? .null) else { return nil }
        home.score = fixture["home_team_score"].int
        away.score = fixture["away_team_score"].int
        let week = fixture["week"].int ?? 0
        let gameType = CFLGameTypeMapper.type(gameTypeID: fixture["game_type_id"].int ?? -1)
        let rawStatus = fixture["game_status"].string
        let status = status(rawStatus, start: start, now: now)
        let venueName = fixture["venue_id"].string.flatMap { venues[$0] }?["name"].string
        let label = CFLGameTypeMapper.label(gameType, homeZone: teams[homeID]?["team_zone"].string, awayZone: teams[awayID]?["team_zone"].string)
        return CFLGameState(id: id, seasonID: seasonID, year: year, week: week, gameType: gameType, start: start,
            home: home, away: away, status: status, statusText: rawStatus ?? label,
            totalPeriods: fixture["total_periods"].int, clock: fixture["game_clock"].string,
            venue: venueName, broadcasts: fixture["broadcasting_options"].array.compactMap(\.string),
            drives: [], plays: [], summaryUpdated: now, detailsUpdated: now)
    }
    static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: value) { return date }
        f.formatOptions.insert(.withFractionalSeconds); return f.date(from: value)
    }
}
