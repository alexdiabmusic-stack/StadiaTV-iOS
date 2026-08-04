import Foundation

struct YouTubeManifest: Decodable {
    let coreChannels: [CoreChannel]
    let teamChannels: [TeamChannel]

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coreChannels = try c.decode([CoreChannel].self, forKey: .coreChannels)
        teamChannels = try c.decode([TeamChannel].self, forKey: .teamChannels)
    }

    private enum CodingKeys: String, CodingKey { case coreChannels, teamChannels }
}

struct CoreChannel: Decodable, Hashable {
    let key: String
    let name: String
    let handle: String
    let channelId: String
    let uploadsPlaylistId: String
}

struct TeamChannel: Decodable, Hashable {
    let key: String
    let name: String
    let league: String
    let handleCandidates: [String]
    let expectedTitleAliases: [String]
}

struct YouTubeChannelListResponse: Decodable {
    let items: [YouTubeChannel]

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([YouTubeChannel].self, forKey: .items)
    }

    private enum CodingKeys: String, CodingKey { case items }
}

struct YouTubeChannel: Decodable {
    let id: String
    let snippet: Snippet
    let contentDetails: ContentDetails

    struct Snippet: Decodable {
        let title: String
    }

    struct ContentDetails: Decodable {
        let relatedPlaylists: RelatedPlaylists

        struct RelatedPlaylists: Decodable {
            let uploads: String
        }
    }
}

struct ResolvedYouTubeChannel: Codable, Hashable {
    let channelId: String
    let uploadsPlaylistId: String
    let title: String
    let resolvedHandle: String
    let resolvedAt: Date

    nonisolated init(channelId: String, uploadsPlaylistId: String, title: String,
                     resolvedHandle: String, resolvedAt: Date) {
        self.channelId = channelId
        self.uploadsPlaylistId = uploadsPlaylistId
        self.title = title
        self.resolvedHandle = resolvedHandle
        self.resolvedAt = resolvedAt
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channelId = try c.decode(String.self, forKey: .channelId)
        uploadsPlaylistId = try c.decode(String.self, forKey: .uploadsPlaylistId)
        title = try c.decode(String.self, forKey: .title)
        resolvedHandle = try c.decode(String.self, forKey: .resolvedHandle)
        resolvedAt = try c.decode(Date.self, forKey: .resolvedAt)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channelId, forKey: .channelId)
        try c.encode(uploadsPlaylistId, forKey: .uploadsPlaylistId)
        try c.encode(title, forKey: .title)
        try c.encode(resolvedHandle, forKey: .resolvedHandle)
        try c.encode(resolvedAt, forKey: .resolvedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case channelId, uploadsPlaylistId, title, resolvedHandle, resolvedAt
    }
}

actor YouTubeChannelResolver {
    enum ResolverError: Error {
        case invalidURL
        case invalidResponse
        case noMatchingOfficialChannel
    }

    private let apiKey: String
    private let session: URLSession
    private let cacheKeyPrefix = "youtube.resolved.channel."
    private let cacheLifetime: TimeInterval = 30 * 24 * 60 * 60

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func resolve(_ team: TeamChannel) async throws -> ResolvedYouTubeChannel {
        if let cached = loadCached(team: team),
           Date().timeIntervalSince(cached.resolvedAt) < cacheLifetime {
            return cached
        }

        for handle in team.handleCandidates {
            guard var components = URLComponents(
                string: "https://www.googleapis.com/youtube/v3/channels"
            ) else {
                throw ResolverError.invalidURL
            }

            components.queryItems = [
                URLQueryItem(name: "part", value: "id,snippet,contentDetails"),
                URLQueryItem(name: "forHandle", value: handle),
                URLQueryItem(name: "key", value: apiKey)
            ]

            guard let url = components.url else {
                throw ResolverError.invalidURL
            }

            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                continue
            }

            let decoded = try JSONDecoder().decode(
                YouTubeChannelListResponse.self,
                from: data
            )

            guard let item = decoded.items.first else {
                continue
            }

            guard titleMatches(
                returnedTitle: item.snippet.title,
                expectedAliases: team.expectedTitleAliases
            ) else {
                continue
            }

            let resolved = ResolvedYouTubeChannel(
                channelId: item.id,
                uploadsPlaylistId: item.contentDetails.relatedPlaylists.uploads,
                title: item.snippet.title,
                resolvedHandle: handle,
                resolvedAt: Date()
            )

            saveCached(resolved, team: team)
            return resolved
        }

        throw ResolverError.noMatchingOfficialChannel
    }

    private func titleMatches(
        returnedTitle: String,
        expectedAliases: [String]
    ) -> Bool {
        let normalizedTitle = normalize(returnedTitle)
        return expectedAliases.contains {
            let normalizedAlias = normalize($0)
            return normalizedTitle == normalizedAlias
                || normalizedTitle.contains(normalizedAlias)
                || normalizedAlias.contains(normalizedTitle)
        }
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func cacheKey(for team: TeamChannel) -> String {
        "\(cacheKeyPrefix)\(team.league).\(team.key)"
    }

    private func saveCached(
        _ value: ResolvedYouTubeChannel,
        team: TeamChannel
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(for: team))
    }

    private func loadCached(
        team: TeamChannel
    ) -> ResolvedYouTubeChannel? {
        guard let data = UserDefaults.standard.data(
            forKey: cacheKey(for: team)
        ) else {
            return nil
        }

        return try? JSONDecoder().decode(
            ResolvedYouTubeChannel.self,
            from: data
        )
    }
}
