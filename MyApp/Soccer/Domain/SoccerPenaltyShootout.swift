import Foundation

/// One kick in a penalty shootout, in the order taken.
nonisolated struct SoccerPenaltyKick: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let teamID: String
    let playerReference: SoccerPlayerReference
    let scored: Bool
    /// Kick order within the shootout (1-based), independent of alternating-side display.
    let sequence: Int
}

/// A penalty shootout, present on `SoccerGameCentreSnapshot` only when the provider
/// actually reports one in progress or completed — the Game Centre must never
/// render this panel from an inferred/guessed extra-time state.
nonisolated struct SoccerPenaltyShootout: Codable, Sendable, Equatable {
    let homeTeamID: String
    let awayTeamID: String
    var kicks: [SoccerPenaltyKick]
    var homeScore: Int
    var awayScore: Int
    /// True once the shootout has a winner (sudden-death kicks included).
    var isComplete: Bool
}
