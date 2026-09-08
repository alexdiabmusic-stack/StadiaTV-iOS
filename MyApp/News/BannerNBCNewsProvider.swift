import Foundation

// MARK: - NBC Sports RSS/Atom provider
// Live-verified 2026-09-07: index.rss returns HTTP 200 with valid RSS content.
// sport-specific feeds follow https://www.nbcsports.com/{sport}/rss/index.rss pattern.

struct NBCSportsNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    var supportsPagination: Bool { false }

    private static let nbcBase = "https://www.nbcsports.com"

    init() {
        self.metadata = SportsDataProviderMetadata(
            id: .nbcSports,
            name: "NBC Sports RSS",
            supportLevel: .firstPartyWeb,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: ["*"],
            capabilities: [.newsMetadata],
            authenticationType: .none,
            isEnabled: AppConfiguration.isNBCSportsNewsProviderEnabled,
            requestTimeout: 15
        )
    }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.nbcSports) }

        let feedURLs = nbcFeeds(for: league)
        let http = BannerNewsHTTPClient.shared
        let now = Date()
        let targetLeagueID = SportsIdentityResolver.canonicalLeagueID(for: league)
        var collected: [BannerNewsArticle] = []

        await withTaskGroup(of: [BannerNewsArticle].self) { group in
            for feedURLString in feedURLs {
                group.addTask {
                    guard let url = URL(string: feedURLString) else { return [] }
                    do {
                        let data = try await http.dataWithRetry(
                            from: url,
                            accept: "application/rss+xml, application/atom+xml, application/xml, text/xml"
                        )
                        return BannerRSSParser.parse(data).compactMap { item -> BannerNewsArticle? in
                            guard let title = item.title, !title.isEmpty else { return nil }
                            let urlStr = item.link ?? item.guid ?? ""
                            let seed = item.guid ?? urlStr
                            return BannerNewsArticle(
                                id: BannerEntityID(rawValue: "news:nbcSports:\(BannerNewsDeduplicator.articleHash(seed))"),
                                headline: title,
                                description: item.description ?? item.content ?? "",
                                published: BannerRSSParser.parseDate(item.publishedRaw),
                                url: URL(string: urlStr),
                                imageURL: item.imageURL.flatMap(URL.init(string:)),
                                leagueID: targetLeagueID,
                                teamIDs: [],
                                playerIDs: [],
                                sourceName: nil,
                                provenance: DataProvenance(
                                    provider: .nbcSports,
                                    fetchedAt: now,
                                    providerEntityID: seed,
                                    confidence: 0.7
                                ),
                                publisher: "NBC Sports",
                                articleType: nil,
                                authorByline: item.author
                            )
                        }
                    } catch { return [] }
                }
            }
            for await batch in group { collected.append(contentsOf: batch) }
        }

        guard !collected.isEmpty else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        return BannerNewsDeduplicator.deduplicate(
            collected.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        ).prefix(limit).map { $0 }
    }

    // MARK: - Feed selection

    private func nbcFeeds(for league: League) -> [String] {
        let b = Self.nbcBase
        // Primary feed always included (classifies itself via headline matching)
        var feeds = ["\(b)/rss/index.rss"]

        // Sport-specific feeds (NBC uses slug-based paths)
        let slug = nbcSlug(for: league)
        if let slug {
            feeds.append("\(b)/\(slug)/rss/index.rss")
        }
        return feeds
    }

    private func nbcSlug(for league: League) -> String? {
        switch league.group {
        case .football:
            return league.path.contains("nfl") ? "nfl"
                 : league.path.contains("college") ? "college-football"
                 : nil
        case .basketball:
            return league.path.contains("nba") ? "nba" : nil
        case .baseball:  return "mlb"
        case .hockey:    return "nhl"
        case .soccer:    return "soccer"
        case .golf:      return "golf"
        case .tennis:    return "tennis"
        case .racing:    return "motorsports"
        default:         return nil
        }
    }

}
