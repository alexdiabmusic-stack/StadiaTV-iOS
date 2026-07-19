import Foundation

enum AppConfiguration {
    private static let oddsAPIKeyName = "OddsAPIKey"
    private static let oddsAPIBaseURLName = "OddsAPIBaseURL"
    private static let backendBaseURLName = "BackendBaseURL"

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

    static var isOddsEnabled: Bool {
        oddsAPIKey != nil
    }

    private static func sanitizedString(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("__") else { return nil }
        return trimmed
    }
}
