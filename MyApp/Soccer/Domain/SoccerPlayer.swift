import Foundation

/// A lightweight player identity — enough to label a goal, card, or substitution
/// without a full profile fetch. Lineup slots and roster rows layer their own
/// position/shirt-number fields on top of this since those vary by context.
nonisolated struct SoccerPlayerReference: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let firstName: String?
    let lastName: String?

    var fullName: String {
        let joined = [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespaces).isEmpty ? "Unknown player" : joined
    }
}

/// A player on a club's squad list.
nonisolated struct SoccerRosterPlayer: Codable, Sendable, Equatable, Identifiable {
    var id: String { reference.id }
    let reference: SoccerPlayerReference
    var position: String?
    var shirtNumber: String?
    var nationality: String?
    var dateOfBirth: Date?
}
