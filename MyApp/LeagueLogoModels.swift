import Foundation

struct LeagueLogoManifest: Decodable {
    let schemaVersion: Int
    let catalogId: String
    let globalPillStyle: GlobalPillStyle
    let leagues: [LeagueLogoConfig]
}

struct GlobalPillStyle: Decodable {
    let height: Double
    let cornerRadius: Double
    let logoFrameWidth: Double
    let logoFrameHeight: Double
    let logoMaxWidth: Double
    let logoMaxHeight: Double
    let minimumTouchHeight: Double
}

struct LeagueLogoConfig: Decodable {
    let catalogLeagueId: String
    let sport: String
    let name: String
    let pillLabel: String
    let logo: LogoSpec
}

struct LogoSpec: Decodable {
    let directURL: String?
    let primaryResolver: LogoResolver?
    let fallbackResolver: LogoResolver?
    let fallbackSFSymbol: String?
}

struct LogoResolver: Decodable {
    let type: String
    // directImage
    let url: String?
    // espnLeagueMetadata
    let requestURL: String?
    let logoArrayJSONPath: String?
    let hrefJSONKey: String?
    let preference: [String]?
    // wikipediaPageImage
    let jsonPath: String?
    let pageTitle: String?
}
