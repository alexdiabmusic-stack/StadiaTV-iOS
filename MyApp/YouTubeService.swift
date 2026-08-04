import Foundation

// MARK: - Public video item

struct YouTubeVideoItem: Identifiable, Hashable {
    enum Source: Hashable {
        case league, home, away, team
        var label: String {
            switch self {
            case .league: "LEAGUE"
            case .home:   "HOME"
            case .away:   "AWAY"
            case .team:   "TEAM"
            }
        }
    }

    let id: String
    let videoId: String
    let title: String
    let description: String
    let thumbnailURL: URL?
    let publishedAt: Date?
    let source: Source
}

// MARK: - Private decoding

private struct PlaylistItemsResponse: Decodable {
    let items: [Item]

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([Item].self, forKey: .items)
    }

    private enum CodingKeys: String, CodingKey { case items }

    struct Item: Decodable {
        let snippet: Snippet

        nonisolated init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            snippet = try c.decode(Snippet.self, forKey: .snippet)
        }

        private enum CodingKeys: String, CodingKey { case snippet }

        struct Snippet: Decodable {
            let publishedAt: String?
            let title: String
            let description: String
            let thumbnails: Thumbnails?
            let resourceId: ResourceId

            nonisolated init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                publishedAt = try? c.decode(String.self, forKey: .publishedAt)
                title = (try? c.decode(String.self, forKey: .title)) ?? ""
                description = (try? c.decode(String.self, forKey: .description)) ?? ""
                thumbnails = try? c.decode(Thumbnails.self, forKey: .thumbnails)
                resourceId = try c.decode(ResourceId.self, forKey: .resourceId)
            }

            private enum CodingKeys: String, CodingKey {
                case publishedAt, title, description, thumbnails, resourceId
            }

            struct Thumbnails: Decodable {
                let medium: Thumbnail?
                let high: Thumbnail?
                struct Thumbnail: Decodable { let url: String }
            }

            struct ResourceId: Decodable { let videoId: String }
        }
    }
}

private struct RawPlaylistItem: Sendable {
    let videoId: String
    let title: String
    let description: String
    let thumbnailURL: URL?
    let publishedAt: Date?
}

private struct PlaylistCacheEntry {
    let items: [RawPlaylistItem]
    let fetchedAt: Date
}

// MARK: - Service

actor YouTubeService {
    @MainActor
    static let shared: YouTubeService? = {
        guard let key = AppConfiguration.youtubeAPIKey else { return nil }
        let url = Bundle.main.url(forResource: "sports_youtube_manifest", withExtension: "json")!
        let data = try! Data(contentsOf: url)
        let manifest = try! JSONDecoder().decode(YouTubeManifest.self, from: data)
        return YouTubeService(apiKey: key, manifest: manifest)
    }()

    /// Maps League.path → manifest coreChannel key.
    nonisolated static let supportedLeaguePaths: [String: String] = [
        "basketball/nba":       "nba",
        "hockey/nhl":           "nhl",
        "football/nfl":         "nfl",
        "baseball/mlb":         "mlb",
        "soccer/usa.1":         "mls",
        "soccer/eng.1":         "premier_league",
        "soccer/uefa.champions": "uefa",
        "soccer/fifa.world":    "fifa",
        "racing/f1":            "formula1",
    ]

    private static let highlightKeywords: [String] = [
        "highlight", "highlights", "recap", "goals", "top plays",
        "best plays", "best moments", "finish", "saves",
        "home run", "touchdown", "race highlight", "qualifying",
    ]

    private static let iso8601ms: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private let apiKey: String
    private let resolver: YouTubeChannelResolver
    private let manifest: YouTubeManifest
    private let session: URLSession
    private var playlistCache: [String: PlaylistCacheEntry] = [:]
    private let cacheTTL: TimeInterval = 45 * 60

    init(apiKey: String, manifest: YouTubeManifest, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.manifest = manifest
        self.session = session
        self.resolver = YouTubeChannelResolver(apiKey: apiKey, session: session)
    }

    // MARK: - Public API

    /// Fetches and merges league, home, and away highlights for a match.
    /// Returns newest-first deduplicated results.
    func fetchHighlights(for match: Match) async -> [YouTubeVideoItem] {
        let leagueKey = Self.supportedLeaguePaths[match.league.path]
        async let leagueItems = fetchLeagueHighlights(for: match, leagueKey: leagueKey)
        async let teamItems   = fetchTeamHighlights(for: match)
        let (league, teams) = await (leagueItems, teamItems)
        return deduplicated(teams + league)
    }

    /// Fetches recent highlight videos from a league's core channel.
    func fetchLatestHighlights(leagueKey: String, limit: Int = 10) async -> [YouTubeVideoItem] {
        guard let core = manifest.coreChannels.first(where: { $0.key == leagueKey }) else { return [] }
        let raw = (try? await fetchPlaylistItems(playlistId: core.uploadsPlaylistId)) ?? []
        return raw.filter { isHighlight($0.title) }.prefix(limit).map { makeItem($0, source: .league) }
    }

    /// Fetches recent highlight videos from a team's own YouTube channel.
    func fetchHighlights(teamKey: String, leagueKey: String, limit: Int = 8) async -> [YouTubeVideoItem] {
        guard let team = manifest.teamChannels.first(where: { $0.key == teamKey && $0.league == leagueKey }),
              let resolved = try? await resolver.resolve(team) else { return [] }
        let raw = (try? await fetchPlaylistItems(playlistId: resolved.uploadsPlaylistId)) ?? []
        return raw.filter { isHighlight($0.title) }.prefix(limit).map { makeItem($0, source: .team) }
    }

    // MARK: - Private

    private func fetchLeagueHighlights(for match: Match, leagueKey: String?) async -> [YouTubeVideoItem] {
        guard let key = leagueKey,
              let core = manifest.coreChannels.first(where: { $0.key == key }) else { return [] }
        let raw = (try? await fetchPlaylistItems(playlistId: core.uploadsPlaylistId)) ?? []
        let tokens = teamTokens(for: match.home) + teamTokens(for: match.away)
        return raw
            .filter { item in
                let lower = item.title.lowercased()
                return tokens.contains { lower.contains($0) } || isHighlight(item.title)
            }
            .map { makeItem($0, source: .league) }
    }

    private func fetchTeamHighlights(for match: Match) async -> [YouTubeVideoItem] {
        let leagueKey = Self.supportedLeaguePaths[match.league.path] ?? ""
        let homeTeam = manifest.teamChannels.first {
            $0.league == leagueKey && $0.key == match.home.abbreviation.lowercased()
        }
        let awayTeam = manifest.teamChannels.first {
            $0.league == leagueKey && $0.key == match.away.abbreviation.lowercased()
        }
        return await withTaskGroup(of: [YouTubeVideoItem].self) { group in
            group.addTask { await self.resolveAndFetch(team: homeTeam, source: .home) }
            group.addTask { await self.resolveAndFetch(team: awayTeam, source: .away) }
            var results: [YouTubeVideoItem] = []
            for await items in group { results += items }
            return results
        }
    }

    private func resolveAndFetch(team: TeamChannel?, source: YouTubeVideoItem.Source) async -> [YouTubeVideoItem] {
        guard let team, let resolved = try? await resolver.resolve(team) else { return [] }
        let raw = (try? await fetchPlaylistItems(playlistId: resolved.uploadsPlaylistId)) ?? []
        return raw
            .filter { isHighlight($0.title) }
            .map { makeItem($0, source: source) }
    }

    private func fetchPlaylistItems(playlistId: String) async throws -> [RawPlaylistItem] {
        if let cached = playlistCache[playlistId],
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.items
        }
        var comps = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
        comps.queryItems = [
            URLQueryItem(name: "part",        value: "snippet"),
            URLQueryItem(name: "playlistId",  value: playlistId),
            URLQueryItem(name: "maxResults",  value: "20"),
            URLQueryItem(name: "key",         value: apiKey),
        ]
        let (data, response) = try await session.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(PlaylistItemsResponse.self, from: data)
        let items: [RawPlaylistItem] = decoded.items.map { item in
            let s = item.snippet
            let thumbStr = s.thumbnails?.high?.url ?? s.thumbnails?.medium?.url
            return RawPlaylistItem(
                videoId: s.resourceId.videoId,
                title: s.title,
                description: s.description,
                thumbnailURL: thumbStr.flatMap(URL.init(string:)),
                publishedAt: s.publishedAt.flatMap(Self.parseDate)
            )
        }
        playlistCache[playlistId] = PlaylistCacheEntry(items: items, fetchedAt: Date())
        return items
    }

    // MARK: - Helpers

    private static func parseDate(_ string: String) -> Date? {
        iso8601ms.date(from: string) ?? iso8601.date(from: string)
    }

    private func makeItem(_ raw: RawPlaylistItem, source: YouTubeVideoItem.Source) -> YouTubeVideoItem {
        YouTubeVideoItem(id: raw.videoId, videoId: raw.videoId, title: raw.title,
                         description: raw.description, thumbnailURL: raw.thumbnailURL,
                         publishedAt: raw.publishedAt, source: source)
    }

    private func isHighlight(_ title: String) -> Bool {
        let lower = title.lowercased()
        return Self.highlightKeywords.contains { lower.contains($0) }
    }

    private func teamTokens(for team: TeamSide) -> [String] {
        [team.displayName, team.shortName, team.abbreviation]
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    private func deduplicated(_ items: [YouTubeVideoItem]) -> [YouTubeVideoItem] {
        var seen = Set<String>()
        var result: [YouTubeVideoItem] = []
        for item in items where seen.insert(item.videoId).inserted {
            result.append(item)
        }
        return result.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }
}
