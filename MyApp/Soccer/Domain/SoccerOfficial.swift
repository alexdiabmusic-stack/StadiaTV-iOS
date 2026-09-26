import Foundation

/// A match official. `role` preserves the provider's raw label (e.g. "Referee",
/// "Assistant Referee#1", "Fourth official", "VAR") rather than forcing it into a
/// fixed enum, since the exact set of roles supplied varies by match.
nonisolated struct SoccerOfficial: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(role)-\(name)" }
    let name: String
    let role: String
}
