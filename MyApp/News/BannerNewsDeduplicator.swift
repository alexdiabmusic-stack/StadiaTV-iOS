import Foundation
import CryptoKit

// MARK: - Multi-source news deduplication, classification, and ranking

enum BannerNewsDeduplicator {

    // MARK: - Merge and rank from multiple providers

    nonisolated static func mergeAndRank(
        _ collected: [(SportsDataProviderID, [BannerNewsArticle])],
        league: League,
        limit: Int
    ) -> [BannerNewsArticle] {
        var all: [BannerNewsArticle] = []
        for (_, articles) in collected { all.append(contentsOf: articles) }
        let deduped = deduplicate(all)
        return rank(deduped, league: league, collected: collected, limit: limit)
    }

    // MARK: - Deduplication

    nonisolated static func deduplicate(_ articles: [BannerNewsArticle]) -> [BannerNewsArticle] {
        var seenURLs: Set<String> = []
        var seenTitles: Set<String> = []
        var result: [BannerNewsArticle] = []

        for article in articles {
            let urlKey = canonicalURLKey(article.url)
            let titleKey = normalizeTitle(article.headline)

            if !urlKey.isEmpty && seenURLs.contains(urlKey) { continue }
            if !titleKey.isEmpty && seenTitles.contains(titleKey) { continue }

            if !urlKey.isEmpty { seenURLs.insert(urlKey) }
            if !titleKey.isEmpty { seenTitles.insert(titleKey) }
            result.append(article)
        }
        return result
    }

    // MARK: - Ranking with source diversity

    nonisolated static func rank(
        _ articles: [BannerNewsArticle],
        league: League,
        collected: [(SportsDataProviderID, [BannerNewsArticle])],
        limit: Int
    ) -> [BannerNewsArticle] {
        let now = Date()

        // Score each article
        let scored: [(BannerNewsArticle, Double)] = articles.map { article in
            var score = 0.0

            // Freshness: decay over 24h window
            if let published = article.published {
                let ageHours = max(0, now.timeIntervalSince(published)) / 3600
                score += max(0, 1.0 - (ageHours / 24.0)) * 50
            }

            // Source priority bonus
            let provider = article.provenance?.provider ?? .espn
            score += sourcePriority(provider) * 20

            // Confidence bonus
            score += (article.provenance?.confidence ?? 0.5) * 10

            // Breaking/trending premium
            if article.articleType == "breaking" || article.articleType == "trending" { score += 15 }

            return (article, score)
        }

        // Sort by score descending
        var sorted = scored.sorted { $0.1 > $1.1 }.map(\.0)

        // Apply source diversity cap: limit per source to avoid flooding
        var countByProvider: [SportsDataProviderID: Int] = [:]
        let maxPerProvider = max(3, limit / max(1, collected.count))
        sorted = sorted.filter { article in
            let provider = article.provenance?.provider ?? .espn
            let current = countByProvider[provider, default: 0]
            guard current < maxPerProvider else { return false }
            countByProvider[provider] = current + 1
            return true
        }

        return Array(sorted.prefix(limit))
    }

    nonisolated static func hasAmbiguousLeagueEvidence(headline: String, description: String?) -> Bool {
        if isMultiEventRoundup(headline) { return true }
        let headlineLeagues = identifiedLeagues(in: headline)
        return (headlineLeagues.isEmpty ? identifiedLeagues(in: description ?? "") : headlineLeagues).count > 1
    }

    nonisolated private static func isMultiEventRoundup(_ headline: String) -> Bool {
        let normalized = headline.lowercased().replacingOccurrences(of: "’", with: "'")
        return normalized.contains("today's top games") || normalized.contains("games to watch, best bets")
    }

    // MARK: - League classification

    /// Attempts to identify the most relevant league for a headline + description.
    nonisolated static func classify(headline: String, description: String?, tags: [String] = []) -> (sport: SportGroup?, leagueID: BannerEntityID?) {
        if isMultiEventRoundup(headline) { return (nil, nil) }
        // Broadcast keywords such as "football", "Sunday" or "basketball" are
        // not league evidence. Headline evidence takes priority over feed tags.
        let headlineLeagues = identifiedLeagues(in: headline)
        let candidates = headlineLeagues.isEmpty
            ? identifiedLeagues(in: ([description ?? ""] + tags).joined(separator: " "))
            : headlineLeagues
        if candidates.count == 1, let league = candidates.first {
            return (league.group, SportsIdentityResolver.canonicalLeagueID(for: league))
        }
        let groups = Set(candidates.map(\.group))
        if !candidates.isEmpty { return (groups.count == 1 ? groups.first : nil, nil) }
        let text = ([headline, description ?? ""] + tags).joined(separator: " ")
        let sports: [(SportGroup, [String])] = [
            (.basketball, ["basketball"]), (.hockey, ["hockey"]),
            (.baseball, ["baseball"]), (.soccer, ["soccer"]),
            (.golf, ["golf"]), (.tennis, ["tennis"]), (.racing, ["motorsport", "racing"])
        ]
        let matched = sports.filter { _, words in words.contains { containsPhrase($0, in: text) } }
        return (matched.count == 1 ? matched.first?.0 : nil, nil)
    }

    private nonisolated static func identifiedLeagues(in text: String) -> [League] {
        League.all.filter { league in
            var names = [league.name, league.shortName]
            switch league.path {
            case "racing/f1": names += ["Formula 1", "Formula One"]
            case "soccer/eng.1": names += ["Premier League"]
            case "soccer/esp.1": names += ["La Liga", "LaLiga"]
            case "baseball/mlb": names += ["World Series"]
            case "football/nfl": names += ["Monday Night Football", "MNF", "Super Bowl"]
            case "hockey/nhl": names += ["National Hockey League"]
            case "basketball/nba": names += ["National Basketball Association"]
            case "basketball/wnba": names += ["Women's National Basketball Association"]
            default: break
            }
            return names.contains { containsPhrase($0, in: text) }
        }
    }

    private nonisolated static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Helpers

    private nonisolated static func canonicalURLKey(_ url: URL?) -> String {
        guard var comps = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return "" }
        // Strip tracking parameters
        let trackingParams = ["utm_source", "utm_medium", "utm_campaign", "utm_content", "utm_term",
                              "cmpid", "campaign", "source", "ref", "referrer", "fbclid", "gclid"]
        comps.queryItems = comps.queryItems?.filter { item in
            !trackingParams.contains(item.name.lowercased())
        }
        if comps.queryItems?.isEmpty == true { comps.queryItems = nil }
        comps.fragment = nil
        // URL paths and query values may be case-sensitive.
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        comps.queryItems = comps.queryItems?.sorted {
            $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name
        }
        return comps.url?.absoluteString ?? ""
    }

    private nonisolated static func normalizeTitle(_ title: String) -> String {
        var t = title.lowercased()
        // Strip publisher suffixes like " - ESPN", " | FOX Sports"
        for sep in [" - ", " | ", " – "] {
            if let range = t.range(of: sep, options: .backwards) {
                let suffix = t[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if ["espn", "fox sports", "bbc sport", "cbs sports", "nbc sports", "sky sports"].contains(suffix) {
                    t = String(t[..<range.lowerBound])
                }
            }
        }
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// djb2-style hash for stable article IDs — nonisolated so it can be called from any concurrency context.
    nonisolated static func articleHash(_ seed: String) -> String {
        var h = UInt64(5381)
        for b in seed.utf8 { h = h &* 31 &+ UInt64(b) }
        return String(h, radix: 16)
    }

    private nonisolated static func sourcePriority(_ provider: SportsDataProviderID) -> Double {
        switch provider {
        case .espn: return 1.0
        case .yahooSports: return 0.85
        case .foxBifrostNews: return 0.85
        case .cbsSports, .cbsRSS: return 0.8
        case .nbcSports: return 0.75
        case .foxRSS: return 0.75
        case .bbcSport: return 0.7
        case .skySports: return 0.65
        default: return 0.5
        }
    }
}
