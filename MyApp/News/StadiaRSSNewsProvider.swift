import Foundation

// MARK: - Generic RSS/Atom news provider

struct StadiaRSSFeed {
    let url: URL
    /// Fixed league this feed covers, when known (e.g. CBS NFL feed → NFL).
    let knownLeague: League?
    let accept: String

    init(url: URL, knownLeague: League? = nil) {
        self.url = url
        self.knownLeague = knownLeague
        self.accept = "application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.8, */*;q=0.5"
    }
}

struct StadiaRSSNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    let feeds: [StadiaRSSFeed]
    let publisher: String

    var supportsPagination: Bool { false }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [StadiaNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(metadata.id) }

        var allItems: [(StadiaRSSParser.ParsedItem, League)] = []
        let http = StadiaNewsHTTPClient.shared

        await withTaskGroup(of: [(StadiaRSSParser.ParsedItem, League)].self) { group in
            for feed in feeds {
                group.addTask {
                    do {
                        let data = try await http.dataWithRetry(from: feed.url, accept: feed.accept)
                        let items = StadiaRSSParser.parse(data)
                        return items.compactMap { item -> (StadiaRSSParser.ParsedItem, League)? in
                            // If feed has a fixed league, use it directly.
                            if let fixed = feed.knownLeague {
                                return (item, fixed)
                            }
                            // Otherwise classify by headline keywords.
                            let (_, leagueID) = StadiaNewsDeduplicator.classify(
                                headline: item.title ?? "",
                                description: item.description,
                                tags: item.categories
                            )
                            // Only return articles that match the requested league.
                            guard let leagueID,
                                  leagueID == SportsIdentityResolver.canonicalLeagueID(for: league) else {
                                return nil
                            }
                            return (item, league)
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await batch in group { allItems.append(contentsOf: batch) }
        }

        guard !allItems.isEmpty else { throw SportsDataError.unsupportedCapability(.newsMetadata) }

        let providerID = metadata.id
        let pub = publisher
        let now = Date()
        return allItems.prefix(limit).map { item, matchedLeague in
            let urlString = item.link ?? item.guid ?? ""
            let url = URL(string: urlString)
            let seed = item.guid ?? urlString
            let idHash = StadiaNewsDeduplicator.articleHash(seed)
            return StadiaNewsArticle(
                id: StadiaEntityID(rawValue: "news:\(providerID.rawValue):\(idHash)"),
                headline: item.title ?? "Untitled",
                description: item.description ?? item.content ?? "",
                published: StadiaRSSParser.parseDate(item.publishedRaw),
                url: url,
                imageURL: item.imageURL.flatMap(URL.init(string:)),
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: matchedLeague),
                teamIDs: [],
                playerIDs: [],
                sourceName: nil,
                provenance: DataProvenance(provider: providerID, fetchedAt: now, providerEntityID: seed, confidence: 0.6),
                publisher: pub,
                articleType: nil,
                authorByline: item.author
            )
        }
    }

}

// MARK: - General-purpose RSS provider that returns all articles regardless of league

struct StadiaGeneralRSSNewsProvider: SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    let feeds: [StadiaRSSFeed]
    let publisher: String

    var supportsPagination: Bool { false }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [StadiaNewsArticle] {
        guard page == 1 else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(metadata.id) }

        var allItems: [(StadiaRSSParser.ParsedItem, League?)] = []
        let http = StadiaNewsHTTPClient.shared

        await withTaskGroup(of: [(StadiaRSSParser.ParsedItem, League?)].self) { group in
            for feed in feeds {
                group.addTask {
                    do {
                        let data = try await http.dataWithRetry(from: feed.url, accept: feed.accept)
                        let items = StadiaRSSParser.parse(data)
                        return items.map { item in
                            let fixedLeague = feed.knownLeague
                            if fixedLeague != nil { return (item, fixedLeague) }
                            let (_, leagueID) = StadiaNewsDeduplicator.classify(
                                headline: item.title ?? "",
                                description: item.description,
                                tags: item.categories
                            )
                            let matched = leagueID.flatMap { id in
                                League.all.first { SportsIdentityResolver.canonicalLeagueID(for: $0) == id }
                            }
                            return (item, matched)
                        }
                    } catch {
                        return []
                    }
                }
            }
            for await batch in group { allItems.append(contentsOf: batch) }
        }

        // Filter to the requested league (or articles classifiable to it)
        let leagueID = SportsIdentityResolver.canonicalLeagueID(for: league)
        let filtered = allItems.filter { _, itemLeague in
            guard let l = itemLeague else { return false }
            return SportsIdentityResolver.canonicalLeagueID(for: l) == leagueID
        }

        guard !filtered.isEmpty else { throw SportsDataError.unsupportedCapability(.newsMetadata) }

        let providerID = metadata.id
        let pub = publisher
        let now = Date()
        return filtered.prefix(limit).map { item, _ in
            let urlString = item.link ?? item.guid ?? ""
            let url = URL(string: urlString)
            let seed = item.guid ?? urlString
            let idHash = StadiaNewsDeduplicator.articleHash(seed)
            return StadiaNewsArticle(
                id: StadiaEntityID(rawValue: "news:\(providerID.rawValue):\(idHash)"),
                headline: item.title ?? "Untitled",
                description: item.description ?? item.content ?? "",
                published: StadiaRSSParser.parseDate(item.publishedRaw),
                url: url,
                imageURL: item.imageURL.flatMap(URL.init(string:)),
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                teamIDs: [],
                playerIDs: [],
                sourceName: nil,
                provenance: DataProvenance(provider: providerID, fetchedAt: now, providerEntityID: seed, confidence: 0.6),
                publisher: pub,
                articleType: nil,
                authorByline: item.author
            )
        }
    }

}
