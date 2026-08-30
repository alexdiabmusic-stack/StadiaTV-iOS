import Foundation

enum TeamLogoAssetResolver {
    nonisolated static func assetURL(leaguePath: String, abbreviation: String?, displayName: String? = nil, providerTeamID: String? = nil) -> URL? {
        switch leaguePath {
        case "basketball/nba":
            return nbaAssetURL(abbreviation: abbreviation)
        case "football/nfl":
            return nflAssetURL(abbreviation: abbreviation)
        case "baseball/mlb":
            return mlbAssetURL(abbreviation: abbreviation, displayName: displayName, providerTeamID: providerTeamID)
        default:
            return soccerAssetURL(leaguePath: leaguePath, displayName: displayName)
        }
    }

    nonisolated static func nbaAssetURL(abbreviation: String?) -> URL? {
        normalizedAbbreviation(abbreviation).flatMap { URL.stadiaImageAsset(named: "NBALogo_\($0)") }
    }

    nonisolated static func nflAssetURL(abbreviation: String?) -> URL? {
        guard let abbreviation = normalizedAbbreviation(abbreviation) else { return nil }
        let normalized = nflAbbreviationAliases[abbreviation] ?? abbreviation
        return URL.stadiaImageAsset(named: "NFLLogo_\(normalized)")
    }

    nonisolated static func mlbAssetURL(abbreviation: String?, displayName: String?, providerTeamID: String?) -> URL? {
        if let providerTeamID, let asset = mlbProviderIDAssets[providerTeamID] {
            return URL.stadiaImageAsset(named: asset)
        }
        if let abbreviation = normalizedAbbreviation(abbreviation), let asset = mlbAbbreviationAssets[abbreviation] {
            return URL.stadiaImageAsset(named: asset)
        }
        if let displayName {
            let asset = "MLBLogo_\(assetSuffix(displayName))"
            return URL.stadiaImageAsset(named: asset)
        }
        return nil
    }

    nonisolated static func soccerAssetURL(leaguePath: String, displayName: String?) -> URL? {
        guard let displayName, let leagueName = msiLeagueName(for: leaguePath) else { return nil }
        let asset = "MSILogo_\(assetSuffix("\(leagueName)_\(displayName)").lowercased())"
        return URL.stadiaImageAsset(named: asset)
    }

    nonisolated static func normalizedAbbreviation(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }

    nonisolated static func assetSuffix(_ value: String) -> String {
        value
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .map { character in
                character.isLetter || character.isNumber ? String(character) : "_"
            }
            .joined()
            .split(separator: "_")
            .joined(separator: "_")
    }

    private nonisolated static func msiLeagueName(for leaguePath: String) -> String? {
        switch leaguePath {
        case "soccer/fra.1": return "Ligue 1"
        case "soccer/eng.1": return "Premier League"
        case "soccer/esp.1": return "La Liga"
        case "soccer/ita.1": return "Serie A"
        case "soccer/ger.1": return "Bundesliga"
        case "soccer/usa.1": return "MLS"
        default: return nil
        }
    }

    private nonisolated static let nflAbbreviationAliases: [String: String] = [
        "WSH": "WAS",
        "JAC": "JAX",
        "ARZ": "ARI",
        "LA": "LAR"
    ]

    private nonisolated static let mlbAbbreviationAssets: [String: String] = [
        "ARI": "MLBLogo_Arizona_Diamondbacks",
        "ATH": "MLBLogo_Athletics",
        "OAK": "MLBLogo_Athletics",
        "ATL": "MLBLogo_Atlanta_Braves",
        "BAL": "MLBLogo_Baltimore_Orioles",
        "BOS": "MLBLogo_Boston_Red_Sox",
        "CHC": "MLBLogo_Chicago_Cubs",
        "CWS": "MLBLogo_Chicago_White_Sox",
        "CHW": "MLBLogo_Chicago_White_Sox",
        "CIN": "MLBLogo_Cincinnati_Reds",
        "CLE": "MLBLogo_Cleveland_Guardians",
        "COL": "MLBLogo_Colorado_Rockies",
        "DET": "MLBLogo_Detroit_Tigers",
        "HOU": "MLBLogo_Houston_Astros",
        "KC": "MLBLogo_Kansas_City_Royals",
        "KCR": "MLBLogo_Kansas_City_Royals",
        "LAA": "MLBLogo_Los_Angeles_Angels",
        "LAD": "MLBLogo_Los_Angeles_Dodgers",
        "MIA": "MLBLogo_Miami_Marlins",
        "MIL": "MLBLogo_Milwaukee_Brewers",
        "MIN": "MLBLogo_Minnesota_Twins",
        "NYM": "MLBLogo_New_York_Mets",
        "NYY": "MLBLogo_New_York_Yankees",
        "PHI": "MLBLogo_Philadelphia_Phillies",
        "PIT": "MLBLogo_Pittsburgh_Pirates",
        "SD": "MLBLogo_San_Diego_Padres",
        "SDP": "MLBLogo_San_Diego_Padres",
        "SF": "MLBLogo_San_Francisco_Giants",
        "SFG": "MLBLogo_San_Francisco_Giants",
        "SEA": "MLBLogo_Seattle_Mariners",
        "STL": "MLBLogo_St_Louis_Cardinals",
        "TB": "MLBLogo_Tampa_Bay_Rays",
        "TBR": "MLBLogo_Tampa_Bay_Rays",
        "TEX": "MLBLogo_Texas_Rangers",
        "TOR": "MLBLogo_Toronto_Blue_Jays",
        "WSH": "MLBLogo_Washington_Nationals",
        "WSN": "MLBLogo_Washington_Nationals"
    ]

    private nonisolated static let mlbProviderIDAssets: [String: String] = [
        "109": "MLBLogo_Arizona_Diamondbacks",
        "133": "MLBLogo_Athletics",
        "144": "MLBLogo_Atlanta_Braves",
        "110": "MLBLogo_Baltimore_Orioles",
        "111": "MLBLogo_Boston_Red_Sox",
        "112": "MLBLogo_Chicago_Cubs",
        "145": "MLBLogo_Chicago_White_Sox",
        "113": "MLBLogo_Cincinnati_Reds",
        "114": "MLBLogo_Cleveland_Guardians",
        "115": "MLBLogo_Colorado_Rockies",
        "116": "MLBLogo_Detroit_Tigers",
        "117": "MLBLogo_Houston_Astros",
        "118": "MLBLogo_Kansas_City_Royals",
        "108": "MLBLogo_Los_Angeles_Angels",
        "119": "MLBLogo_Los_Angeles_Dodgers",
        "146": "MLBLogo_Miami_Marlins",
        "158": "MLBLogo_Milwaukee_Brewers",
        "142": "MLBLogo_Minnesota_Twins",
        "121": "MLBLogo_New_York_Mets",
        "147": "MLBLogo_New_York_Yankees",
        "143": "MLBLogo_Philadelphia_Phillies",
        "134": "MLBLogo_Pittsburgh_Pirates",
        "135": "MLBLogo_San_Diego_Padres",
        "137": "MLBLogo_San_Francisco_Giants",
        "136": "MLBLogo_Seattle_Mariners",
        "138": "MLBLogo_St_Louis_Cardinals",
        "139": "MLBLogo_Tampa_Bay_Rays",
        "140": "MLBLogo_Texas_Rangers",
        "141": "MLBLogo_Toronto_Blue_Jays",
        "120": "MLBLogo_Washington_Nationals"
    ]
}
