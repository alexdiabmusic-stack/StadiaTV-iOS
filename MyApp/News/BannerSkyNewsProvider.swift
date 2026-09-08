import Foundation

// MARK: - Sky Sports RSS provider
// Live-verified 2026-09-07: feeds return HTTP 200 with valid RSS content.
// Feed ID 12040 is Sky Sports' main sports news RSS.

struct SkySportsNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    var supportsPagination: Bool { false }

    // Sky Sports RSS base — all sport feeds use this pattern
    private nonisolated static let rssBase = "https://www.skysports.com/rss"

    // Sky feed IDs mapped by sport (from Sky's public RSS directory)
    private nonisolated static let feedByLeagueGroup: [SportGroup: [Int]] = [
        .soccer:      [12040, 12801, 12803, 12604],  // main, premier league, football news, transfers
        .racing:      [12040, 12614],                // main + F1/motorsport
        .tennis:      [12040, 12615],
        .golf:        [12040, 12616],
        .cycling:     [12040],
        .basketball:  [12040],
        .baseball:    [12040],
        .hockey:      [12040],
        .football:    [12040],
        .wrestling:   [12040],
        .esports:     [12040],
    ]

    init() {
        self.metadata = SportsDataProviderMetadata(
            id: .skySports,
            name: "Sky Sports RSS",
            supportLevel: .firstPartyWeb,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: ["*"],
            capabilities: [.newsMetadata],
            authenticationType: .none,
            isEnabled: AppConfiguration.isSkySportsNewsProviderEnabled,
            requestTimeout: 15
        )
    }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.skySports) }

        let feedIDs = Self.feedByLeagueGroup[league.group] ?? [12040]
        let http = BannerNewsHTTPClient.shared
        let now = Date()
        let targetLeagueID = SportsIdentityResolver.canonicalLeagueID(for: league)
        var collected: [BannerNewsArticle] = []

        await withTaskGroup(of: [BannerNewsArticle].self) { group in
            for feedID in feedIDs {
                group.addTask {
                    guard let url = URL(string: "\(Self.rssBase)/\(feedID)") else { return [] }
                    do {
                        let data = try await http.dataWithRetry(
                            from: url,
                            accept: "application/rss+xml, application/xml, text/xml"
                        )
                        return BannerRSSParser.parse(data).compactMap { item -> BannerNewsArticle? in
                            guard let title = item.title, !title.isEmpty else { return nil }
                            let urlStr = item.link ?? item.guid ?? ""
                            let seed = item.guid ?? urlStr
                            return BannerNewsArticle(
                                id: BannerEntityID(rawValue: "news:skySports:\(BannerNewsDeduplicator.articleHash(seed))"),
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
                                    provider: .skySports,
                                    fetchedAt: now,
                                    providerEntityID: seed,
                                    confidence: 0.6
                                ),
                                publisher: "Sky Sports",
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

        // For mixed feeds (feedID 12040), classify and filter to requested league
        let filtered: [BannerNewsArticle]
        if feedIDs.contains(12040) && feedIDs.count == 1 {
            filtered = collected.filter { article in
                let (_, cid) = BannerNewsDeduplicator.classify(
                    headline: article.headline,
                    description: article.description,
                    tags: []
                )
                return cid == nil || cid == targetLeagueID
            }
        } else {
            filtered = collected
        }

        return BannerNewsDeduplicator.deduplicate(
            filtered.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        ).prefix(limit).map { $0 }
    }

}
