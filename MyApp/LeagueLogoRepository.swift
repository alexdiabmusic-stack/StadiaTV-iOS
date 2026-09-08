import Foundation

/// Loads banner_league_logos.json once, indexes by catalogLeagueId, and resolves
/// logo URLs on demand using a priority chain: directURL → ESPN → Wikipedia → nil.
/// Resolved URLs are cached per session; AsyncImage handles image caching.
@MainActor
final class LeagueLogoRepository {
    static let shared = LeagueLogoRepository()

    private var index: [String: LeagueLogoConfig] = [:]
    private let resolvedURLs = NSCache<NSString, NSURL>()
    private var inFlight: [String: Task<URL?, Never>] = [:]

    private init() { load() }

    private func load() {
        guard let fileURL = Bundle.main.url(forResource: "banner_league_logos", withExtension: "json"),
              let data = try? Data(contentsOf: fileURL),
              let manifest = try? JSONDecoder().decode(LeagueLogoManifest.self, from: data) else { return }
        index = Dictionary(uniqueKeysWithValues: manifest.leagues.map { ($0.catalogLeagueId, $0) })
    }

    func config(for catalogLeagueId: String) -> LeagueLogoConfig? {
        index[catalogLeagueId]
    }

    /// Returns the display-friendly pill label, overriding opaque sport codes with real names.
    func displayLabel(for catalogLeagueId: String) -> String? {
        guard let config = index[catalogLeagueId] else { return nil }
        let raw = config.pillLabel
        return Self.pillLabelOverrides[raw] ?? raw
    }

    /// Resolves and caches the best logo URL for a league. Returns nil when no logo is available;
    /// callers should fall back to the sport SF Symbol in that case.
    func logoURL(for catalogLeagueId: String) async -> URL? {
        let key = catalogLeagueId as NSString
        if let cached = resolvedURLs.object(forKey: key) { return cached as URL }

        // Deduplicate concurrent requests for the same league
        if let existing = inFlight[catalogLeagueId] {
            return await existing.value
        }

        let task = Task<URL?, Never> { [weak self] in
            guard let self, let config = self.index[catalogLeagueId] else { return nil }
            return await self.resolveSpec(config.logo)
        }
        inFlight[catalogLeagueId] = task
        let result = await task.value
        inFlight.removeValue(forKey: catalogLeagueId)
        if let result { resolvedURLs.setObject(result as NSURL, forKey: key) }
        return result
    }

    // MARK: - Resolution chain

    private func resolveSpec(_ spec: LogoSpec) async -> URL? {
        if let s = spec.directURL, let u = URL(string: s) { return u }
        if let primary = spec.primaryResolver, let u = await resolveOne(primary) { return u }
        if let fallback = spec.fallbackResolver, let u = await resolveOne(fallback) { return u }
        return nil
    }

    private func resolveOne(_ r: LogoResolver) async -> URL? {
        switch r.type {
        case "directImage":
            return r.url.flatMap { URL(string: $0) }
        case "espnLeagueMetadata":
            return await resolveESPN(r)
        case "wikipediaPageImage":
            return await resolveWikipedia(r)
        default:
            return nil
        }
    }

    private func resolveESPN(_ r: LogoResolver) async -> URL? {
        guard let urlString = r.requestURL, let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let leagues = json["leagues"] as? [[String: Any]],
              let firstLeague = leagues.first,
              let logos = firstLeague["logos"] as? [[String: Any]] else { return nil }

        let prefs = r.preference ?? ["dark-background-compatible", "default", "first-valid"]
        for pref in prefs {
            if pref == "first-valid" {
                if let href = logos.first?["href"] as? String { return URL(string: href) }
            } else {
                for logo in logos {
                    guard let rels = logo["rel"] as? [String], rels.contains(pref),
                          let href = logo["href"] as? String else { continue }
                    return URL(string: href)
                }
            }
        }
        return logos.compactMap { $0["href"] as? String }.first.flatMap { URL(string: $0) }
    }

    private func resolveWikipedia(_ r: LogoResolver) async -> URL? {
        guard let urlString = r.requestURL, let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: [String: Any]] else { return nil }
        for (_, page) in pages {
            if let thumb = page["thumbnail"] as? [String: Any],
               let src = thumb["source"] as? String { return URL(string: src) }
        }
        return nil
    }

    // MARK: - Display label overrides for opaque sport codes

    nonisolated static let pillLabelOverrides: [String: String] = [
        "ACLE":   "AFC Champions League",
        "LPF":    "Argentine Primera",
        "JPL":    "Belgian Pro League",
        "BRA1":   "Brasileirão",
        "BUN":    "Bundesliga",
        "ERE":    "Eredivisie",
        "DPWT":   "DP World Tour",
        "L1":     "Ligue 1",
        "LIGAMX": "Liga MX",
        "LALIGA": "La Liga",
        "WC":     "FIFA World Cup",
        "CWC":    "Club World Cup",
        "LIB":    "Copa Libertadores",
        "KFT":    "Korn Ferry Tour",
        "PGATC":  "PGA Tour Champions",
        "OLY-M":  "Olympics (Men's)",
        "OLY-W":  "Olympics (Women's)",
        "OLY":    "Olympics",
    ]
}
