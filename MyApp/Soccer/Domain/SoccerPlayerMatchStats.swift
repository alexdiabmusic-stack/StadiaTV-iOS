import Foundation

/// One player's match statistics — the individual-performance counterpart to
/// `SoccerTeamMatchStats`. Every field optional; a missing metric hides its row
/// rather than rendering a fake `0`, same rule as the team stats. `raw` preserves
/// every supplied metric (mapped or not) for future expansion.
nonisolated struct SoccerPlayerMatchStats: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(matchID)|\(playerID)" }
    let matchID: String
    let playerID: String
    let teamID: String
    var minutesPlayed: Double?
    var goals: Double?
    var assists: Double?
    var shots: Double?
    var shotsOnTarget: Double?
    var passesCompleted: Double?
    var passAccuracy: Double?
    var tackles: Double?
    var interceptions: Double?
    var duelsWon: Double?
    var foulsCommitted: Double?
    var yellowCards: Double?
    var redCards: Double?
    var saves: Double?
    var raw: [String: Double] = [:]
}
