import Foundation

/// A La Liga club's identity across the official API's endpoints. `numericID` is only
/// meaningful within the endpoint that produced it — verified live 2026-09-24 that a
/// squad row's nested `team.id` and a player-stats row's `team.id` are drawn from the
/// same numbering, but never assume that holds for an endpoint not yet checked.
/// `optaID` (`t###`) is the one join key confirmed stable across matches, standings,
/// and player-stats responses — team reconciliation always keys off it, never off
/// `numericID` alone (Step 6).
nonisolated struct LaLigaTeamIdentity: Codable, Sendable, Equatable {
    let numericID: String
    let optaID: String?
    let slug: String?
    /// The canonical app team ID this resolves to, once known.
    var canonicalTeamID: String?
}

/// A La Liga player's identity — same numeric/opta split as `LaLigaTeamIdentity`.
/// Verified live 2026-09-24 that a squad row's own `opta_id` (`p60772`) and a
/// player-stats row's `opta_id` for the same person agree, while their respective
/// row-level `id` fields (squad-row id vs. player-stats-row id) do not.
nonisolated struct LaLigaPlayerIdentity: Codable, Sendable, Equatable {
    let numericID: String
    let optaID: String?
    var canonicalPlayerID: String?
}
