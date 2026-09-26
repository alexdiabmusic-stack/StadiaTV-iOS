import Foundation

/// One team's Opta-derived match statistics, normalized from ~180 raw provider keys
/// into a stable canonical shape. Every field is optional — a missing metric must
/// hide its row in the UI, never render as a fake `0`. `raw` preserves every
/// supplied metric (mapped or not) for DEBUG diagnostics and future expansion
/// (Steps 30–34, 76).
nonisolated struct SoccerTeamMatchStats: Codable, Sendable, Equatable {
    let teamID: String
    var possession: Double?
    var expectedGoals: Double?
    var expectedGoalsOnTarget: Double?
    var shots: Double?
    var shotsOnTarget: Double?
    var shotsOffTarget: Double?
    var blockedShots: Double?
    var bigChancesCreated: Double?
    var bigChancesMissed: Double?
    var corners: Double?
    var passes: Double?
    var passesCompleted: Double?
    var crosses: Double?
    var tackles: Double?
    var tacklesWon: Double?
    var interceptions: Double?
    var clearances: Double?
    var duelsWon: Double?
    var aerialDuelsWon: Double?
    var touchesInOppositionBox: Double?
    var finalThirdEntries: Double?
    var fouls: Double?
    var offsides: Double?
    var saves: Double?
    var yellowCards: Double?
    var redCards: Double?
    /// Pitch-zone entry distribution (e.g. MLS's 4 attacking zones), when the
    /// provider supplies positional aggregates instead of/alongside a possession
    /// time-series. Empty, not synthesized, when unsupported.
    var attackingZones: [SoccerAttackingZone] = []
    var distanceCovered: Double? = nil
    var ballRecoveryTime: Double? = nil
    var raw: [String: Double] = [:]
}

/// One pitch-zone slice of `SoccerTeamMatchStats.attackingZones`. `zoneID` is the
/// provider's own zone identifier, preserved verbatim rather than remapped to a
/// guessed pitch-third label.
nonisolated struct SoccerAttackingZone: Codable, Sendable, Equatable, Identifiable {
    var id: String { zoneID }
    let zoneID: String
    let entries: Int
    let ratio: Double
}
