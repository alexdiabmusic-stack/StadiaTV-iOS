import Foundation

enum AppConfiguration {
    private static let oddsAPIKeyName = "OddsAPIKey"
    private static let oddsAPIBaseURLName = "OddsAPIBaseURL"
    private static let backendBaseURLName = "BackendBaseURL"
    private static let youtubeAPIKeyName = "YouTubeAPIKey"
    private nonisolated static let espnFantasyEnabledName = "ESPNFantasyProviderEnabled"
    private nonisolated static let sleeperFantasyEnabledName = "SleeperFantasyProviderEnabled"
    private nonisolated static let nhlProviderEnabledName = "NHLProviderEnabled"
    private nonisolated static let mlbProviderEnabledName = "MLBProviderEnabled"
    private nonisolated static let nbaProviderEnabledName = "NBAProviderEnabled"
    private nonisolated static let nflProviderEnabledName = "NFLProviderEnabled"
    private nonisolated static let appleSportsEnabledName = "AppleSportsProviderEnabled"
    private nonisolated static let cbsSportsEnabledName = "CBSSportsProviderEnabled"
    private nonisolated static let yahooSportsEnabledName = "YahooSportsProviderEnabled"
    private nonisolated static let foxSportsEnabledName = "FoxSportsProviderEnabled"
    private nonisolated static let foxBifrostNewsEnabledName = "FOXBifrostNewsProviderEnabled"
    private nonisolated static let cbsRSSEnabledName = "CBSRSSNewsProviderEnabled"
    private nonisolated static let bbcSportEnabledName = "BBCSportNewsProviderEnabled"
    private nonisolated static let skySportsNewsEnabledName = "SkySportsNewsProviderEnabled"
    private nonisolated static let nbcSportsNewsEnabledName = "NBCSportsNewsProviderEnabled"
    private nonisolated static let foxRSSEnabledName = "FOXRSSNewsProviderEnabled"
    private nonisolated static let bleacherReportEnabledName = "BleacherReportNewsProviderEnabled"

    static var oddsAPIKey: String? {
        sanitizedString(for: oddsAPIKeyName)
    }

    static var oddsAPIBaseURL: URL {
        sanitizedString(for: oddsAPIBaseURLName)
            .flatMap(URL.init(string:))
            ?? URL(string: "https://mlapi.bet/v1")!
    }

    static var backendBaseURL: URL? {
        sanitizedString(for: backendBaseURLName).flatMap(URL.init(string:))
    }

    static var youtubeAPIKey: String? {
        sanitizedString(for: youtubeAPIKeyName)
    }

    static var isOddsEnabled: Bool {
        oddsAPIKey != nil
    }

    static var isYouTubeEnabled: Bool {
        youtubeAPIKey != nil
    }

    nonisolated static var isESPNFantasyProviderEnabled: Bool {
        guard let value = sanitizedString(for: espnFantasyEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isSleeperFantasyProviderEnabled: Bool {
        guard let value = sanitizedString(for: sleeperFantasyEnabledName)?.lowercased() else { return false }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isNHLProviderEnabled: Bool {
        guard let value = sanitizedString(for: nhlProviderEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isMLBProviderEnabled: Bool {
        guard let value = sanitizedString(for: mlbProviderEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isNBAProviderEnabled: Bool {
        guard let value = sanitizedString(for: nbaProviderEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isNFLProviderEnabled: Bool {
        guard let value = sanitizedString(for: nflProviderEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isAppleSportsProviderEnabled: Bool {
        guard let value = sanitizedString(for: appleSportsEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isCBSSportsProviderEnabled: Bool {
        guard let value = sanitizedString(for: cbsSportsEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isYahooSportsProviderEnabled: Bool {
        guard let value = sanitizedString(for: yahooSportsEnabledName)?.lowercased() else { return false }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isFoxSportsProviderEnabled: Bool {
        guard let value = sanitizedString(for: foxSportsEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isFOXBifrostNewsProviderEnabled: Bool {
        guard let value = sanitizedString(for: foxBifrostNewsEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isCBSRSSNewsProviderEnabled: Bool {
        guard let value = sanitizedString(for: cbsRSSEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isBBCSportNewsProviderEnabled: Bool {
        guard let value = sanitizedString(for: bbcSportEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isSkySportsNewsProviderEnabled: Bool {
        guard let value = sanitizedString(for: skySportsNewsEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isNBCSportsNewsProviderEnabled: Bool {
        guard let value = sanitizedString(for: nbcSportsNewsEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    nonisolated static var isFOXRSSNewsProviderEnabled: Bool {
        guard let value = sanitizedString(for: foxRSSEnabledName)?.lowercased() else { return true }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    /// Bleacher Report legacy API — defaults disabled; endpoints are verified offline.
    nonisolated static var isBleacherReportNewsProviderEnabled: Bool {
        guard let value = sanitizedString(for: bleacherReportEnabledName)?.lowercased() else { return false }
        return ["1", "true", "yes", "enabled"].contains(value)
    }

    private nonisolated static func sanitizedString(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("__") else { return nil }
        return trimmed
    }
}
