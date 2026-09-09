import Foundation

// MARK: - BBC Sport RSS provider
// Live-verified 2026-09-07: all feeds return HTTP 200 with valid RSS content.
// All URLs are BBC's official public RSS endpoints.

struct BBCSportNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    var supportsPagination: Bool { false }

    // BBC RSS base
    private static let base = "https://feeds.bbci.co.uk/sport"

    init() {
        self.metadata = SportsDataProviderMetadata(
            id: .bbcSport,
            name: "BBC Sport RSS",
            supportLevel: .firstPartyWeb,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: ["*"],
            capabilities: [.newsMetadata],
            authenticationType: .none,
            isEnabled: AppConfiguration.isBBCSportNewsProviderEnabled,
            requestTimeout: 15
        )
    }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.bbcSport) }

        let feedURLs = bbcFeeds(for: league)
        guard !feedURLs.isEmpty else { throw SportsDataError.unsupportedCapability(.newsMetadata) }

        let http = BannerNewsHTTPClient.shared
        let now = Date()
        var collected: [BannerNewsArticle] = []
        let targetLeagueID = SportsIdentityResolver.canonicalLeagueID(for: league)

        await withTaskGroup(of: [BannerNewsArticle].self) { group in
            for feedURL in feedURLs {
                group.addTask {
                    guard let url = URL(string: feedURL) else { return [] }
                    do {
                        let data = try await http.dataWithRetry(
                            from: url,
                            accept: "application/rss+xml, application/xml, text/xml",
                            maxAttempts: 1
                        )
                        return BannerRSSParser.parse(data).compactMap { item -> BannerNewsArticle? in
                            guard let title = item.title, !title.isEmpty else { return nil }
                            let urlStr = item.link ?? item.guid ?? ""
                            let seed = item.guid ?? urlStr
                            return BannerNewsArticle(
                                id: BannerEntityID(rawValue: "news:bbcSport:\(BannerNewsDeduplicator.articleHash(seed))"),
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
                                    provider: .bbcSport,
                                    fetchedAt: now,
                                    providerEntityID: seed,
                                    confidence: 0.65
                                ),
                                publisher: "BBC Sport",
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

    private func bbcFeeds(for league: League) -> [String] {
        let b = Self.base
        // Only return sport-specific feeds. Returning the general /rss.xml for every
        // league causes cross-sport contamination (e.g. tennis articles tagged as NHL).
        // Sports without a BBC-specific feed return [] so the provider throws
        // .unsupportedCapability and the platform falls back to ESPN for those leagues.
        switch league.group {
        case .soccer:
            return ["\(b)/football/rss.xml", "\(b)/football/premier-league/rss.xml"]
        case .racing:
            return ["\(b)/formula1/rss.xml"]
        case .tennis:
            return ["\(b)/tennis/rss.xml"]
        case .golf:
            return ["\(b)/golf/rss.xml"]
        case .cycling:
            return ["\(b)/cycling/rss.xml"]
        default:
            return []
        }
    }

}
