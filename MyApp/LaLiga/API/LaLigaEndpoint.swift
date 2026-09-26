import Foundation

/// Centralized official-API route construction (Steps 1–9) — every network call is
/// built here so allow-listed paths/query shapes never get hand-rolled at call sites.
/// Every route below was verified against the live `apim.laliga.com` gateway
/// 2026-09-24 (see LALIGA-INTEGRATION.md), not assumed from documentation alone.
nonisolated struct LaLigaEndpoint: Sendable {
    let path: String
    var query: [String: String] = [:]

    func url(base: String = LaLigaProviderConfiguration.baseURL) throws -> URL {
        guard var components = URLComponents(string: base) else { throw LaLigaAPIError.invalidURL }
        components.path = path
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw LaLigaAPIError.invalidURL }
        return url
    }

    static func competitions() -> Self { Self(path: LaLigaProviderConfiguration.basePath + "/api/v1/competitions") }

    static func subscriptions(offset: Int, limit: Int) -> Self {
        Self(path: LaLigaProviderConfiguration.basePath + "/api/v1/subscriptions", query: ["offset": String(offset), "limit": String(limit)])
    }

    static func rounds(subscriptionSlug: String) -> Self {
        Self(path: LaLigaProviderConfiguration.basePath + "/api/v1/subscriptions/\(subscriptionSlug)/rounds")
    }

    static func standing(subscriptionSlug: String) -> Self {
        Self(path: LaLigaProviderConfiguration.basePath + "/api/v1/subscriptions/\(subscriptionSlug)/standing")
    }

    /// `limit` above 100 returns HTTP 500 (verified live 2026-09-24) — clamped here
    /// so no call site can accidentally trip that, per Step 4.
    static func matches(subscriptionSlug: String, competition: String, limit: Int, offset: Int) -> Self {
        Self(path: LaLigaProviderConfiguration.basePath + "/api/v1/matches",
             query: ["subscription": subscriptionSlug, "competition": competition, "limit": String(min(limit, 100)), "offset": String(offset)])
    }

    static func squad(teamSlug: String, subscriptionSlug: String) -> Self {
        Self(path: LaLigaProviderConfiguration.basePath + "/api/v1/teams/\(teamSlug)/squad", query: ["subscription": subscriptionSlug])
    }

    static func playerStats(subscriptionSlug: String, limit: Int, offset: Int) -> Self {
        Self(path: LaLigaProviderConfiguration.basePath + "/api/v1/subscriptions/\(subscriptionSlug)/players/stats",
             query: ["limit": String(min(limit, 100)), "offset": String(offset)])
    }
}

nonisolated enum LaLigaDate {
    /// Parses the official API's `"yyyy-MM-ddTHH:mm:ss+00:00"` timestamps (kickoff,
    /// date of birth, gameweek date) — always UTC-offset ISO 8601 in every response
    /// sampled live 2026-09-24, never a bare date-only string.
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return formatter.date(from: value) ?? fallbackFormatter.date(from: value)
    }

    // `ISO8601DateFormatter` predates Sendable but is never mutated after creation
    // here — read-only use is safe across concurrent callers.
    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    /// Not observed live so far, kept only as a fallback in case a future response
    /// includes fractional seconds.
    private nonisolated(unsafe) static let fallbackFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
