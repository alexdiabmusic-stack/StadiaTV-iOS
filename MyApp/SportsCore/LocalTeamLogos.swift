import Foundation

nonisolated enum TeamLogoAssetResolver {
    static func assetURL(leaguePath: String, abbreviation: String?, displayName: String? = nil, providerTeamID: String? = nil) -> URL? {
        guard let abbreviation, !abbreviation.isEmpty else { return nil }
        let prefixes = ["hockey/nhl":"NHLLogo_", "basketball/nba":"NBALogo_", "football/nfl":"NFLLogo_"]
        guard let prefix = prefixes[leaguePath] else { return nil }
        let name = prefix + abbreviation.uppercased()
        return URL.bannerImageAsset(named: name)
    }
}
