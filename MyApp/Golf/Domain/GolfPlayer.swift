import Foundation

nonisolated struct GolfPlayerReference: Identifiable, Codable, Sendable, Hashable {
    var id: String
    let firstName: String?
    let lastName: String?
    let displayName: String
    let shortName: String?
    let country: String?
    let countryFlag: String?
    let amateur: Bool

    init(
        id: String,
        firstName: String? = nil,
        lastName: String? = nil,
        displayName: String? = nil,
        shortName: String? = nil,
        country: String? = nil,
        countryFlag: String? = nil,
        amateur: Bool = false
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.displayName = displayName ?? [firstName, lastName].compactMap { $0 }.joined(separator: " ").ifEmpty("Player \(id)")
        self.shortName = shortName
        self.country = country
        self.countryFlag = countryFlag
        self.amateur = amateur
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// Full PGA TOUR player-directory entry (`player/list/{tour}`), distinct from
/// the lighter `GolfPlayerReference` embedded in leaderboard/scorecard rows.
nonisolated struct GolfPlayerDirectoryEntry: Identifiable, Codable, Sendable, Hashable {
    var id: String
    let tourCode: String?
    let isPrimary: Bool?
    let isActive: Bool?
    let firstName: String?
    let lastName: String?
    let displayName: String?
    let shortName: String?
    let country: String?
    let countryFlag: String?
    let age: Int?
    let primaryTour: String?
}
