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
            if seenTitles.contains(titleKey) { continue }

            if !urlKey.isEmpty { seenURLs.insert(urlKey) }
            seenTitles.insert(titleKey)
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

    // MARK: - League classification

    /// Attempts to identify the most relevant league for a headline + description.
    nonisolated static func classify(headline: String, description: String?, tags: [String] = []) -> (sport: SportGroup?, leagueID: BannerEntityID?) {
        let text = ([headline, description ?? ""] + tags).joined(separator: " ").lowercased()

        // Sorted from most-specific to least-specific so short tokens don't collide.
        let orderedLeagues: [League] = League.all.sorted { lhs, rhs in
            let lMax = lhs.keywords.map(\.count).max() ?? 0
            let rMax = rhs.keywords.map(\.count).max() ?? 0
            return lMax > rMax
        }

        for league in orderedLeagues {
            for keyword in league.keywords {
                let k = keyword.lowercased()
                // Require word-boundary match for short tokens (≤ 4 chars) to reduce false positives
                if k.count <= 4 {
                    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: k))\\b"
                    if let _ = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                        .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                        return (league.group, SportsIdentityResolver.canonicalLeagueID(for: league))
                    }
                } else if text.contains(k) {
                    return (league.group, SportsIdentityResolver.canonicalLeagueID(for: league))
                }
            }
        }
        return (nil, nil)
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
        return (comps.url?.absoluteString ?? "").lowercased()
    }

    private nonisolated static func normalizeTitle(_ title: String) -> String {
        var t = title.lowercased()
        // Strip publisher suffixes like " - ESPN", " | FOX Sports"
        for sep in [" - ", " | ", " – "] {
            if let range = t.range(of: sep, options: .backwards) {
                t = String(t[..<range.lowerBound])
            }
        }
        t = t.replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
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
