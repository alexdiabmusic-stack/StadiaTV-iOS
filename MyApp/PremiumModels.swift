import Foundation

// MARK: - Premium ESPN data models
//
// App-level value types decoded from ESPN's Core / Site / Web APIs to power the
// premium experience: standings, rosters, player stats & bios, statistical
// leaders, and league-wide injury reports.

// MARK: Standings

/// A single team's row within a standings table.
struct StandingRow: Identifiable, Hashable {
    let teamID: String
    let displayName: String
    let abbreviation: String
    let logoURL: URL?
    /// Ordered display stats (e.g. W, L, PCT, GB, streak) already formatted for display.
    let record: String          // e.g. "48-20"
    let winPercent: String?     // e.g. ".706"
    let gamesBack: String?      // e.g. "3.5"
    let streak: String?         // e.g. "W4"
    let pointsFor: String?
    let pointsAgainst: String?

    var id: String { teamID }
}

/// A named group of standings rows — a conference, division, or the full table.
struct StandingsGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let rows: [StandingRow]
}

// MARK: Roster & athletes

/// A player as it appears on a team roster.
struct RosterAthlete: Identifiable, Hashable {
    let id: String
    let displayName: String
    let jersey: String?
    let position: String?
    let positionName: String?
    let headshotURL: URL?
    let age: Int?
    let displayHeight: String?
    let displayWeight: String?
    let college: String?
    let experienceYears: Int?
    let birthPlace: String?
    let isInjured: Bool
}

/// A positional grouping of roster athletes (e.g. "Offense", "Guards").
struct RosterGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let athletes: [RosterAthlete]
}

/// A named statistic value for a player (aligned label + value).
struct StatValue: Identifiable, Hashable {
    let label: String        // short label, e.g. "PPG"
    let displayName: String  // full name, e.g. "Points Per Game"
    let value: String        // formatted value, e.g. "26.8"
    var id: String { label + displayName }
}

/// The stats + related news for a single athlete, from the Web overview endpoint.
/// Bio (name, headshot, position) is supplied by the roster the user navigated from.
struct AthleteOverview: Hashable {
    /// The split the stats represent, e.g. "2024-25 Regular Season" or "Career".
    let statlineLabel: String
    /// Full stat line (all available averages / totals).
    let stats: [StatValue]
    /// The most important 3-4 stats for a compact header.
    let headlineStats: [StatValue]
    /// Recent news mentioning this athlete.
    let news: [ESPNArticle]
}

// MARK: Statistical leaders

/// A single athlete's placement on a leaders board for one stat.
struct LeaderRow: Identifiable, Hashable {
    let rank: Int
    let athleteID: String
    let displayName: String
    let teamAbbreviation: String?
    let headshotURL: URL?
    let value: String
    var id: String { athleteID }
}

/// A leaders board for one statistic (e.g. Points Per Game).
struct LeaderBoard: Identifiable, Hashable {
    let id: String
    let statName: String       // machine key, e.g. "avgPoints"
    let displayName: String    // "Points Per Game"
    let rows: [LeaderRow]
}

// MARK: Injuries

/// A single entry in a league-wide injury report.
struct LeagueInjury: Identifiable, Hashable {
    let id: String
    let athleteName: String
    let teamAbbreviation: String?
    let position: String?
    let status: String          // e.g. "Out", "Day-To-Day"
    let detail: String?         // description / expected return
    let headshotURL: URL?

    /// A tint suggestion driven by severity of the status.
    var isOut: Bool {
        let s = status.lowercased()
        return s.contains("out") || s.contains("injured reserve") || s.contains("ir")
    }
}

// MARK: Game summary (in-game stats)

/// Live/in-game statistics for one event, from the game summary endpoint.
struct GameSummary: Hashable {

    /// One team's stat column in the boxscore.
    struct TeamBox: Identifiable, Hashable {
        let id: String              // ESPN team id
        let name: String
        let abbreviation: String
        let stats: [GameStat]
    }

    /// One formatted stat (e.g. label "Rebounds", value "41").
    struct GameStat: Hashable {
        let label: String
        let displayValue: String
    }

    /// A top performer for one stat category.
    struct GameLeader: Identifiable, Hashable {
        let id: String
        let category: String        // e.g. "Points"
        let athleteName: String
        let teamAbbreviation: String?
        let displayValue: String
    }

    let teams: [TeamBox]
    let leaders: [GameLeader]

    var isEmpty: Bool {
        teams.allSatisfy { $0.stats.isEmpty } && leaders.isEmpty
    }
}
