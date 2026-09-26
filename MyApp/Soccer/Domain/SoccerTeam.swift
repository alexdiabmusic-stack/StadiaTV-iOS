import Foundation

/// A club as known to a soccer provider. Provider-independent — EPL, MLS, Liga MX,
/// or any future league's provider maps its own team payload into this shape.
nonisolated struct SoccerTeam: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let shortName: String
    let abbreviation: String
}
