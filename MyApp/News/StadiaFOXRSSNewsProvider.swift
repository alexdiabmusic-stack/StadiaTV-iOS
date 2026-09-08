import Foundation

// MARK: - FOX Sports RSS provider
// Official sport-tagged feeds from the FOX Sports RSS directory (foxsports.com/rss-feeds).
// partnerKey sourced from the public FOX RSS directory page — not a private credential.

struct FOXRSSNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    var supportsPagination: Bool { false }

    // Obtained from https://www.foxsports.com/rss-feeds — public RSS directory page
    private static let partnerKey = "MB0Wehpmuj2lUhuRhQaafhBjAJqaPU244mlTDK1i"
    private static let foxRSSBase = "https://api.foxsports.com/v1/rss"

    init() {
        self.metadata = SportsDataProviderMetadata(
            id: .foxRSS,
            name: "FOX Sports RSS",
            supportLevel: .firstPartyWeb,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: ["*"],
            capabilities: [.newsMetadata],
            authenticationType: .none,
            isEnabled: AppConfiguration.isFOXRSSNewsProviderEnabled,
            requestTimeout: 15
        )
    }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [StadiaNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.foxRSS) }

        let feedURLs = foxFeeds(for: league)
        guard !feedURLs.isEmpty else { throw SportsDataError.unsupportedCapability(.newsMetadata) }

        let http = StadiaNewsHTTPClient.shared
        let now = Date()
        let targetLeagueID = SportsIdentityResolver.canonicalLeagueID(for: league)
        var collected: [StadiaNewsArticle] = []

        await withTaskGroup(of: [StadiaNewsArticle].self) { group in
            for feedURL in feedURLs {
                group.addTask {
                    guard let url = URL(string: feedURL) else { return [] }
                    do {
                        let data = try await http.dataWithRetry(
                            from: url,
                            accept: "application/rss+xml, application/xml, text/xml"
                        )
                        return StadiaRSSParser.parse(data).compactMap { item -> StadiaNewsArticle? in
                            guard let title = item.title, !title.isEmpty else { return nil }
                            let urlStr = item.link ?? item.guid ?? ""
                            let seed = item.guid ?? urlStr
                            return StadiaNewsArticle(
                                id: StadiaEntityID(rawValue: "news:foxRSS:\(StadiaNewsDeduplicator.articleHash(seed))"),
                                headline: title,
                                description: item.description ?? item.content ?? "",
                                published: StadiaRSSParser.parseDate(item.publishedRaw),
                                url: URL(string: urlStr),
                                imageURL: item.imageURL.flatMap(URL.init(string:)),
                                leagueID: targetLeagueID,
                                teamIDs: [],
                                playerIDs: [],
                                sourceName: nil,
                                provenance: DataProvenance(
                                    provider: .foxRSS,
                                    fetchedAt: now,
                                    providerEntityID: seed,
                                    confidence: 0.7
                                ),
                                publisher: "FOX Sports",
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
        return StadiaNewsDeduplicator.deduplicate(
            collected.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        ).prefix(limit).map { $0 }
    }

    // MARK: - Feed URL builder

    private func foxFeeds(for league: League) -> [String] {
        let pk = Self.partnerKey
        let base = Self.foxRSSBase

        // FOX RSS feeds use ?tag=nfl&partnerKey=... or ?tag=nba&partnerKey=...
        guard let tag = foxTag(for: league) else {
            // Fall back to general FOX Sports feed
            return ["\(base)?partnerKey=\(pk)"]
        }
        return ["\(base)?tag=\(tag)&partnerKey=\(pk)"]
    }

    private func foxTag(for league: League) -> String? {
        switch league.group {
        case .football:
            return league.path.contains("nfl") ? "nfl"
                 : league.path.contains("college") ? "college-football"
                 : nil
        case .basketball:
            return league.path.contains("nba") ? "nba"
                 : league.path.contains("college") ? "college-basketball"
                 : nil
        case .baseball:  return "mlb"
        case .hockey:    return "nhl"
        case .soccer:    return "soccer"
        case .golf:      return "golf"
        case .tennis:    return "tennis"
        case .racing:    return "nascar"  // FOX has NASCAR, not F1
        default:         return nil
        }
    }

}
