import Foundation

/// Maps `/competitions/{c}/seasons/{s}/standings` into `[SoccerStandingsTable]`.
/// `category=conference` returns two tables whose own `group` field is already the
/// display label (`"EASTERN CONFERENCE"`/`"WESTERN CONFERENCE"`, confirmed live);
/// the default (no `category`) returns one combined/Supporters'-Shield-order table
/// with an empty `group`. Both shapes are handled by the same mapper — the caller
/// decides which query to send.
nonisolated enum MLSStandingsMapper {
    static func tables(_ raw: MLSValue, isLive: Bool) -> [SoccerStandingsTable] {
        raw["tables"].array.map { table(from: $0, isLive: isLive) }
    }

    private static func table(from raw: MLSValue, isLive: Bool) -> SoccerStandingsTable {
        let entries = raw["entries"].array.compactMap(entry)
        let group = raw["group"].string.flatMap { $0.isEmpty ? nil : $0 }
        return SoccerStandingsTable(matchWeek: raw["match_day"].int, entries: entries, isLive: isLive, deductions: [:], groupLabel: group)
    }

    private static func entry(_ raw: MLSValue) -> SoccerStandingsEntry? {
        guard let teamID = raw["team_id"].string else { return nil }
        let team = SoccerTeam(id: teamID, name: raw["team"].string ?? teamID, shortName: raw["team_short_name"].string ?? teamID,
            abbreviation: raw["team_three_letter_code"].string ?? teamID)
        let split = SoccerStandingsSplit(position: raw["position"].int, played: raw["games_played"].int, won: raw["wins"].int,
            drawn: raw["draws"].int, lost: raw["losses"].int, goalsFor: raw["goals_scored"].int, goalsAgainst: raw["goals_against"].int,
            points: raw["points"].int, startingPosition: nil)
        return SoccerStandingsEntry(team: team, overall: split, home: nil, away: nil)
    }
}
