import Foundation

// MARK: - FOX Bifrost News Provider
// Trending articles and league player news via the FOX Sports Bifrost JSON API.
// Public API key sourced from SportsDataverse (sportsdataverse-js / fox.ts).
// Circuit-broken: one failed build will flip isEnabled false for the session.

struct FOXBifrostNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    var supportsPagination: Bool { false }

    // Public default from SportsDataverse fox.ts — not a private credential.
    private static let apiKey = "jE7yBJVRNAwdDesMgTzTXUUSx1It41Fq"
    private static let apiVersion = "1.1"
    private static let bifrostBase = "https://api.foxsports.com/bifrost/v1"

    init() {
        self.metadata = SportsDataProviderMetadata(
            id: .foxBifrostNews,
            name: "FOX Sports Bifrost",
            supportLevel: .firstPartyWeb,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: ["*"],
            capabilities: [.newsMetadata],
            authenticationType: .none,
            isEnabled: AppConfiguration.isFOXBifrostNewsProviderEnabled,
            requestTimeout: 15
        )
    }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.foxBifrostNews) }

        let http = BannerNewsHTTPClient.shared
        let now = Date()
        var collected: [BannerNewsArticle] = []

        // 1. Trending articles (general — filter post-fetch)
        let trendingURL = Self.trendingURL()
        if let url = trendingURL {
            if let data = try? await http.dataWithRetry(from: url, accept: "application/json"),
               let articles = parseBifrostResponse(data, league: league, type: "trending", now: now) {
                collected.append(contentsOf: articles)
            }
        }

        // 2. League-specific player news (if FOX sport slug is known)
        if let slug = foxSportSlug(for: league) {
            let playerNewsURL = Self.playerNewsURL(sport: slug)
            if let url = playerNewsURL,
               let data = try? await http.dataWithRetry(from: url, accept: "application/json"),
               let articles = parseBifrostResponse(data, league: league, type: "playernews", now: now) {
                collected.append(contentsOf: articles)
            }
        }

        guard !collected.isEmpty else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        return BannerNewsDeduplicator.deduplicate(collected).prefix(limit).map { $0 }
    }

    // MARK: - URL builders

    private static func trendingURL() -> URL? {
        var comps = URLComponents(string: "\(bifrostBase)/general/trending/articles")
        comps?.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "api-version", value: apiVersion),
            URLQueryItem(name: "duration", value: "4"),
        ]
        return comps?.url
    }

    private static func playerNewsURL(sport: String) -> URL? {
        var comps = URLComponents(string: "\(bifrostBase)/\(sport)/league/playernews")
        comps?.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "api-version", value: apiVersion),
        ]
        return comps?.url
    }

    // MARK: - Parsing

    private func parseBifrostResponse(_ data: Data, league: League, type articleType: String, now: Date) -> [BannerNewsArticle]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Response envelope: {"articles": [...]} or {"page": {"content": [...]}} or bare array
        let rawItems: [[String: Any]]
        if let arr = json["articles"] as? [[String: Any]] {
            rawItems = arr
        } else if let page = json["page"] as? [String: Any],
                  let content = page["content"] as? [[String: Any]] {
            rawItems = content
        } else if let arr = json["content"] as? [[String: Any]] {
            rawItems = arr
        } else {
            return nil
        }

        let targetLeagueID = SportsIdentityResolver.canonicalLeagueID(for: league)

        return rawItems.compactMap { item -> BannerNewsArticle? in
            guard let headline = (item["export_headline"] as? String)
                    ?? (item["title"] as? String),
                  !headline.isEmpty else { return nil }

            // canonical_url may be relative like "/nfl/…" — prepend www.foxsports.com
            let rawURL = (item["canonical_url"] as? String) ?? (item["url"] as? String) ?? ""
            let fullURL: String
            if rawURL.hasPrefix("http") {
                fullURL = rawURL
            } else if rawURL.hasPrefix("/") {
                fullURL = "https://www.foxsports.com\(rawURL)"
            } else {
                fullURL = rawURL
            }

            // Image: prefer thumbnail, fall back to fn__image
            let imageURL = ((item["thumbnail"] as? [String: Any])?["url"] as? String)
                ?? ((item["fn__image"] as? [String: Any])?["url"] as? String)

            // Date
            let dateStr = (item["last_published_date"] as? String)
                ?? (item["published_date"] as? String)
            let publishedDate = dateStr.flatMap { BannerRSSParser.parseDate($0) }

            // League classification from tags
            let tags = (item["tags"] as? [[String: Any]]) ?? []
            let tagStrings = tags.compactMap { tag -> String? in
                if let type_ = tag["tag_type"] as? String,
                   (type_ == "league" || type_ == "sport"),
                   let name = tag["tag_name"] as? String ?? tag["name"] as? String {
                    return name
                }
                return nil
            }
            let (_, classifiedLeagueID) = BannerNewsDeduplicator.classify(
                headline: headline,
                description: item["dek"] as? String,
                tags: tagStrings
            )
            // If we have a confident league classification AND it doesn't match the requested league, skip
            if let cid = classifiedLeagueID, cid != targetLeagueID { return nil }

            let seed = fullURL.isEmpty ? headline : fullURL
            let idHash = BannerNewsDeduplicator.articleHash(seed)

            return BannerNewsArticle(
                id: BannerEntityID(rawValue: "news:foxBifrost:\(idHash)"),
                headline: headline,
                description: item["dek"] as? String ?? "",
                published: publishedDate,
                url: URL(string: fullURL),
                imageURL: imageURL.flatMap(URL.init(string:)),
                leagueID: targetLeagueID,
                teamIDs: [],
                playerIDs: [],
                sourceName: nil,
                provenance: DataProvenance(
                    provider: .foxBifrostNews,
                    fetchedAt: now,
                    providerEntityID: seed,
                    confidence: 0.8
                ),
                publisher: "FOX Sports",
                articleType: articleType,
                authorByline: item["author"] as? String
            )
        }
    }

    // MARK: - Helpers

    private func foxSportSlug(for league: League) -> String? {
        switch league.group {
        case .football:
            return league.path.contains("nfl") ? "nfl"
                 : league.path.contains("college") ? "cfb"
                 : nil
        case .basketball:
            return league.path.contains("nba") ? "nba"
                 : league.path.contains("college") ? "cbb"
                 : nil
        case .baseball:  return "mlb"
        case .hockey:    return "nhl"
        case .soccer:    return "soccer"
        case .golf:      return "golf"
        default:         return nil
        }
    }

}
