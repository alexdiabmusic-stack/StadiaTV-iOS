import Foundation

/// How a shot ended. `.unknown` preserves the raw provider label rather than
/// dropping a shot whose outcome doesn't map cleanly onto the four common buckets.
nonisolated enum SoccerShotOutcome: Codable, Sendable, Equatable {
    case goal, saved, missed, blocked
    case unknown(String)
}

/// A single shot, for the optional Shots tab/section (Step 24). Only providers with a
/// real shot-by-shot feed (e.g. FotMob) populate this — EPL/MLS leave it empty rather
/// than synthesizing shots from goal events. `expectedGoals` is only ever set when the
/// provider actually supplies xG for that shot — never estimated locally.
nonisolated struct SoccerShot: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let matchID: String
    let teamID: String
    let playerReference: SoccerPlayerReference
    let minute: Int?
    /// Provider's own normalized pitch coordinates (0–100 on each axis), preserved as-supplied.
    let x: Double?
    let y: Double?
    var expectedGoals: Double? = nil
    let outcome: SoccerShotOutcome
    let bodyPart: String?
    let situation: String?
}
