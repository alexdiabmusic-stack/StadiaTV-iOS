import Foundation

// MARK: - CBS Sports RSS provider
// Live-verified 2026-09-07: all feeds return HTTP 200 with valid RSS content.

private let cbsLeagueForPath: [(String, League?)] = {
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

struct CBSRSSNewsProvider: SportsNewsProvider {
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

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [StadiaNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.cbsRSS) }

        let base = "https://www.cbssports.com/rss/headlines"
        let http = StadiaNewsHTTPClient.shared
        let now = Date()

        // Determine which CBS feeds could contain this league's news
        let relevantSlugs = cbsSlugs(for: league)

        var collected: [StadiaNewsArticle] = []

        await withTaskGroup(of: [StadiaNewsArticle].self) { group in
            for (slug, fixedLeague) in relevantSlugs {
                group.addTask {
                    let urlString = slug.isEmpty ? base + "/" : "\(base)/\(slug)"
                    guard let url = URL(string: urlString) else { return [] }
                    do {
                        let data = try await http.dataWithRetry(from: url)
                        return StadiaRSSParser.parse(data).compactMap { item -> StadiaNewsArticle? in
                            guard let title = item.title, !title.isEmpty else { return nil }
                            let urlStr = item.link ?? item.guid ?? ""
                            let seed = item.guid ?? urlStr
                            let idHash = StadiaNewsDeduplicator.articleHash(seed)
                            let articleLeague: League
                            if let fixed = fixedLeague {
                                articleLeague = fixed
                            } else {
                                let (_, lid) = StadiaNewsDeduplicator.classify(
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
                            return StadiaNewsArticle(
                                id: StadiaEntityID(rawValue: "news:cbsRSS:\(idHash)"),
                                headline: title,
                                description: item.description ?? item.content ?? "",
                                published: StadiaRSSParser.parseDate(item.publishedRaw),
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
        return StadiaNewsDeduplicator.deduplicate(collected.sorted {
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

// MARK: - CBS Sports JSON editorial provider (game preview/recap/story)
// Endpoint: https://api.cbssports.com/resource/game/content/{kind}/{cbsGameID}
// Requires a CBS game ID from CBSSportsProvider match aliases.

struct CBSJSONEditorialProvider {
    private let base = URL(string: "https://api.cbssports.com")!
    private let http = StadiaNewsHTTPClient.shared

    enum Kind: String {
        case preview, recap, story
    }

    func editorial(cbsGameID: String, kind: Kind) async throws -> StadiaNewsArticle? {
        let path = "/resource/game/content/\(kind.rawValue)/\(cbsGameID)"
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { return nil }
        let data = try await http.dataWithRetry(from: url, accept: "application/json")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json: json, kind: kind, gameID: cbsGameID)
    }

    private func parse(json: [String: Any], kind: Kind, gameID: String) -> StadiaNewsArticle? {
        // CBS wraps in {body: {result: {...}}} or {data: {...}}
        let body: [String: Any]? =
            (json["body"] as? [String: Any])?["result"] as? [String: Any]
            ?? json["data"] as? [String: Any]
            ?? json["result"] as? [String: Any]

        let title = (body?["headline"] as? String)
            ?? (body?["title"] as? String)
            ?? (json["headline"] as? String)
        guard let headline = title, !headline.isEmpty else { return nil }

        let desc = (body?["excerpt"] as? String)
            ?? (body?["description"] as? String)
            ?? ""
        let urlStr = (body?["url"] as? String) ?? (body?["permalink"] as? String)
        let imageStr = (body?["thumbnail"] as? String)
            ?? ((body?["image"] as? [String: Any])?["url"] as? String)

        return StadiaNewsArticle(
            id: StadiaEntityID(rawValue: "news:cbsSports:editorial:\(gameID):\(kind.rawValue)"),
            headline: headline,
            description: desc,
            published: nil,
            url: urlStr.flatMap(URL.init(string:)),
            imageURL: imageStr.flatMap(URL.init(string:)),
            leagueID: nil,
            teamIDs: [],
            playerIDs: [],
            sourceName: nil,
            provenance: DataProvenance(provider: .cbsSports, fetchedAt: Date(), providerEntityID: gameID, confidence: 0.8),
            publisher: "CBS Sports",
            articleType: kind.rawValue,
            authorByline: nil
        )
    }
}
