import Foundation

/// FedExCup (or tour-equivalent points race) standing for one player. Kept
/// strictly separate from tournament leaderboard position — a player can be
/// leading the tournament while sitting outside the top FedExCup spots, or
/// vice versa (STEP 58).
nonisolated struct GolfCupStanding: Identifiable, Codable, Sendable, Hashable {
    var id: String { playerID }
    let playerID: String
    let displayName: String
    let country: String?
    let officialRankDisplay: String?
    let projectedRankDisplay: String?
    let officialPointsDisplay: String?
    let projectedPointsDisplay: String?
    let movementRaw: String?
    let movementAmountDisplay: String?

    /// Only meaningful mid-tournament; the provider omits this once there is
    /// no live projection to show — never synthesize one (STEP 57).
    var hasProjection: Bool { projectedRankDisplay != nil }
}
