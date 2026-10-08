import Foundation

// MARK: - CBS Sports RSS provider
// Live-verified 2026-09-07: all feeds return HTTP 200 with valid RSS content.

nonisolated private let cbsLeagueForPath: [(String, League?)] = {
    let all = League.all
    return [
        ("",               nil),   // general — all sports
        ("mlb",            all.first { $0.path == "baseball/mlb" }),
        ("nfl",            all.first { $0.path == "football/nfl" }),
        ("nhl",            all.first { $0.path == "hockey/nhl" }),
        ("nba",            all.first { $0.path == "basketball/nba" }),
        ("soccer",         nil),   // multi-league soccer
        ("golf",           all.first { $0.path == "golf/pga" }),
        ("tennis",         all.first { $0.path == "tennis/atp" }),
        ("college-football", all.first { $0.path == "football/college-football" }),
        ("college-basketball", all.first { $0.path == "basketball/mens-college-basketball" }),
        ("mma",            nil),
        ("boxing",         nil),
    ]
}()

nonisolated struct CBSRSSNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    var supportsPagination: Bool { false }

    init() {
        self.metadata = SportsDataProviderMetadata(
            id: .cbsRSS,
            name: "CBS Sports RSS",
            supportLevel: .firstPartyWeb,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: ["*"],
            capabilities: [.newsMetadata],
            authenticationType: .none,
            isEnabled: AppConfiguration.isCBSRSSNewsProviderEnabled,
            requestTimeout: 15
        )
    }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.cbsRSS) }

        let base = "https://www.cbssports.com/rss/headlines"
        let http = BannerNewsHTTPClient.shared
        let now = Date()

        // Determine which CBS feeds could contain this league's news
        let relevantSlugs = cbsSlugs(for: league)

        var collected: [BannerNewsArticle] = []

        await withTaskGroup(of: [BannerNewsArticle].self) { group in
            for (slug, fixedLeague) in relevantSlugs {
                group.addTask {
                    let urlString = slug.isEmpty ? base + "/" : "\(base)/\(slug)"
                    guard let url = URL(string: urlString) else { return [] }
                    do {
                        let data = try await http.dataWithRetry(from: url)
                        return BannerRSSParser.parse(data).compactMap { item -> BannerNewsArticle? in
                            guard let title = item.title, !title.isEmpty else { return nil }
                            let urlStr = item.link ?? item.guid ?? ""
                            let seed = item.guid ?? urlStr
                            let idHash = BannerNewsDeduplicator.articleHash(seed)
                            let articleLeague: League
                            if let fixed = fixedLeague {
                                articleLeague = fixed
                            } else {
                                let (_, lid) = BannerNewsDeduplicator.classify(
                                    headline: title,
                                    description: item.description,
                                    tags: item.categories
                                )
                                guard let lid,
                                      lid == SportsIdentityResolver.canonicalLeagueID(for: league) else { return nil }
                                articleLeague = league
                            }
                            // Only keep articles for the requested league
                            guard SportsIdentityResolver.canonicalLeagueID(for: articleLeague) ==
                                    SportsIdentityResolver.canonicalLeagueID(for: league) else { return nil }
                            return BannerNewsArticle(
                                id: BannerEntityID(rawValue: "news:cbsRSS:\(idHash)"),
                                headline: title,
                                description: item.description ?? item.content ?? "",
                                published: BannerRSSParser.parseDate(item.publishedRaw),
                                url: URL(string: urlStr),
                                imageURL: item.imageURL.flatMap(URL.init(string:)),
                                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                                teamIDs: [],
                                playerIDs: [],
                                sourceName: nil,
                                provenance: DataProvenance(provider: .cbsRSS, fetchedAt: now, providerEntityID: seed, confidence: 0.65),
                                publisher: "CBS Sports",
                                articleType: nil,
                                authorByline: item.author
                            )
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await batch in group { collected.append(contentsOf: batch) }
        }

        guard !collected.isEmpty else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        return BannerNewsDeduplicator.deduplicate(collected.sorted {
            ($0.published ?? .distantPast) > ($1.published ?? .distantPast)
        }).prefix(limit).map { $0 }
    }

    /// Returns CBS feed slugs that are relevant for the given league.
    private func cbsSlugs(for league: League) -> [(String, League?)] {
        var result: [(String, League?)] = [("", nil)]  // always fetch general feed
        switch league.group {
        case .football:
            if league.path.contains("nfl") { result.append(("nfl", league)) }
            else if league.path.contains("college") { result.append(("college-football", league)) }
        case .basketball:
            if league.path.contains("nba") { result.append(("nba", league)) }
            else if league.path.contains("college") { result.append(("college-basketball", league)) }
        case .baseball:
            result.append(("mlb", league))
        case .hockey:
            result.append(("nhl", league))
        case .soccer:
            result.append(("soccer", nil))
        case .golf:
            result.append(("golf", league))
        case .tennis:
            result.append(("tennis", league))
        default:
            break
        }
        return result
    }

}
