import Foundation

/// Centralized FotMob web JSON route construction (Steps 11–14). Every route below
/// was verified against `www.fotmob.com` live 2026-09-24 (see LALIGA-INTEGRATION.md).
/// Kept league-agnostic (not La Liga-specific) since FotMob covers every league —
/// La Liga's league id (87) is supplied by the caller, not hardcoded here.
nonisolated struct FotMobEndpoint: Sendable {
    let path: String
    var query: [String: String] = [:]

    func url(base: String = "https://www.fotmob.com") throws -> URL {
        guard var components = URLComponents(string: base) else { throw FotMobAPIError.invalidURL }
        components.path = path
        let items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw FotMobAPIError.invalidURL }
        return url
    }

    static func leagues(id: Int, season: String? = nil) -> Self {
        var query = ["id": String(id)]
        query["season"] = season
        return Self(path: "/api/data/leagues", query: query)
    }

    static func matches(date: String, timezone: String? = nil) -> Self {
        var query = ["date": date]
        query["timezone"] = timezone
        return Self(path: "/api/data/matches", query: query)
    }

    static func matchDetails(matchId: String) -> Self { Self(path: "/api/data/matchDetails", query: ["matchId": matchId]) }

    /// Never guess this URL when `matchDetails` already provided one (Step 14) —
    /// this factory exists only for the fallback derivation in
    /// `FotMobCommentaryMapper` when the payload's own `liveticker` block omits it.
    static func liveTicker(ltcUrl: String) -> Self {
        Self(path: "/api/data/ltc", query: ["ltcUrl": ltcUrl])
    }
}
