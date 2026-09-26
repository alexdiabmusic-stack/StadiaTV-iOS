import Foundation

/// One competition split (overall / home / away) of a standings row.
nonisolated struct SoccerStandingsSplit: Codable, Sendable, Equatable {
    var position: Int?
    var played: Int?
    var won: Int?
    var drawn: Int?
    var lost: Int?
    var goalsFor: Int?
    var goalsAgainst: Int?
    var points: Int?
    /// Only meaningful on the `overall` split — position before the matchweek in progress.
    var startingPosition: Int?

    var goalDifference: Int? {
        guard let goalsFor, let goalsAgainst else { return nil }
        return goalsFor - goalsAgainst
    }
}

/// A single club's row in a standings table.
nonisolated struct SoccerStandingsEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String { team.id }
    var team: SoccerTeam
    var overall: SoccerStandingsSplit
    var home: SoccerStandingsSplit?
    var away: SoccerStandingsSplit?
}

/// A full table. `isLive` distinguishes a projection that folds in in-progress matches
/// from the official table — these must never be conflated or persisted as each other.
nonisolated struct SoccerStandingsTable: Codable, Sendable, Equatable {
    var matchWeek: Int?
    var entries: [SoccerStandingsEntry]
    var isLive: Bool
    /// Points deductions applied by the league (club id -> points), when supplied.
    var deductions: [String: Int] = [:]
    /// Display label for a conference/group split (e.g. "EASTERN CONFERENCE"). Nil
    /// for single-table leagues like EPL, which show a plain "TABLE"/"LIVE TABLE".
    var groupLabel: String? = nil
}
