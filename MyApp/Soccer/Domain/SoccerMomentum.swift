import Foundation

/// One sample of a provider's restrained "match momentum" graph (Step 25) — never
/// labelled or treated as a win-probability model, just the provider's own relative
/// attacking-pressure value at a point in the match.
nonisolated struct SoccerMomentumSample: Codable, Sendable, Equatable, Identifiable {
    var id: Int { minute }
    let minute: Int
    /// Positive favors home, negative favors away. Provider-defined scale, not a probability.
    let value: Double
}
