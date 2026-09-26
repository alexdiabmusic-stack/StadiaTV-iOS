import Foundation

/// Isolates the LaLiga website's public Azure APIM subscription key (Steps 1, 34) so
/// it never gets scattered through call sites. This is NOT a user credential — it's
/// lifted from laliga.com's own frontend runtime config (`runtimeConfig.
/// backendSubscription`) and can rotate. If it starts 401ing, `LaLigaClient` marks
/// the official provider temporarily unavailable rather than retrying forever or
/// asking the user for anything.
nonisolated enum LaLigaProviderConfiguration {
    static let host = "apim.laliga.com"
    static let baseURL = "https://\(host)"
    static let basePath = "/public-service"
    /// LaLiga's own primary-division slug/id (Step 1) — distinct from Segunda
    /// División (2) and the women's competition (15), which this provider never fetches.
    static let competitionSlug = "primera-division"
    static let competitionID = 1

    /// Overridable via Info.plist (`LaLigaAPIMSubscriptionKey`) if the site rotates
    /// this key before an app update ships — one value to change, mirroring
    /// `AppConfiguration.foxSportsAPIKey`'s public-default-with-override pattern.
    private static let infoPlistKeyName = "LaLigaAPIMSubscriptionKey"
    /// Public website key, verified live against `apim.laliga.com` 2026-09-24 — see
    /// LALIGA-INTEGRATION.md. Rotates independently of any app release.
    private static let fallbackSubscriptionKey = "c13c3a8e2f6b46da9c5c425cf61fab3e"

    static var subscriptionKey: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistKeyName) as? String else { return fallbackSubscriptionKey }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed.hasPrefix("__")) ? fallbackSubscriptionKey : trimmed
    }
}
