import Foundation

// MARK: - Catalog root

struct SportsCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let catalogId: String
    let sports: [CatalogSport]
}

// MARK: - Sport

struct CatalogSport: Decodable, Identifiable, Sendable {
    let id: String          // e.g. "football"
    let name: String        // e.g. "Football"
    let uiSortOrder: Int
    let leagues: [CatalogLeague]
}

// MARK: - League

struct CatalogLeague: Decodable, Identifiable, Sendable {
    let id: String          // e.g. "football:national-football-league"
    let name: String
    let abbreviation: String?
    let country: String?
    let region: String?
    let selectionEntityType: CatalogSelectionEntityType
    let membershipType: CatalogMembershipType
    let season: String?
    let enabled: Bool
    let aliases: [String]
    let teams: [CatalogTeam]
    let notes: String?
    let sortOrder: Int

    /// True when bundled teams are available and entity selection is meaningful.
    var supportsTeamSelection: Bool {
        switch selectionEntityType {
        case .team, .club, .nationalTeam, .constructor:
            return membershipType == .fixed && !teams.isEmpty
        default:
            return false
        }
    }
}

// MARK: - Team

struct CatalogTeam: Decodable, Identifiable, Sendable {
    let id: String          // e.g. "football:national-football-league:arizona-cardinals"
    let name: String
    let abbreviation: String?
    let country: String?
    let aliases: [String]
    let sortOrder: Int
}

// MARK: - Enumerations

enum CatalogSelectionEntityType: String, Decodable, Sendable {
    case team
    case club
    case nationalTeam
    case driver
    case constructor
    case player
    case none
}

enum CatalogMembershipType: String, Decodable, Sendable {
    case fixed
    case dynamic
    case qualification
    case individual

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CatalogMembershipType(rawValue: raw) ?? .dynamic
    }
}
