import Foundation

/// A confirmed (or partially confirmed) cross-provider identity for one match.
/// Exists because La Liga is the first two-source soccer provider in this codebase:
/// the official LaLiga match ID and the FotMob match ID are never the same value and
/// must never be compared/guessed from — see `LaLigaFotMobMatchResolver`. Either
/// field may be nil (a source that hasn't resolved yet), but never a guessed value.
nonisolated struct SoccerProviderMatchIDs: Codable, Sendable, Equatable {
    var laligaOfficial: String?
    var fotmob: String?
}
