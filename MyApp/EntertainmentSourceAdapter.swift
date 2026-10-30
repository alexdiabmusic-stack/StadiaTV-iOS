import Foundation

nonisolated struct XtreamEntertainmentAdapter: EntertainmentInventoryAdapter, EntertainmentPlaybackResolver {
    let playlist: Playlist
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }()
    var session: URLSession = Self.defaultSession

    func request(_ action: String, item: (String, String)? = nil) async throws -> EntertainmentJSON {
        guard var components = URLComponents(string: playlist.host ?? ""),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              let credentials = try KeychainStore.xtreamCredentials(for: playlist.credentialID) else {
            throw EntertainmentError.configuration
        }
        components.path = "/player_api.php"
        components.queryItems = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
            URLQueryItem(name: "action", value: action)
        ]
        if let item { components.queryItems?.append(URLQueryItem(name: item.0, value: item.1)) }
        guard let url = components.url else { throw EntertainmentError.configuration }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(playlist.userAgent ?? "BannerTV", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw EntertainmentError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw EntertainmentError.unavailable }
        if [401, 403].contains(http.statusCode) { throw EntertainmentError.authentication }
        guard (200..<300).contains(http.statusCode), data.count <= 80_000_000 else { throw EntertainmentError.unavailable }
        let json = try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(EntertainmentJSON.self, from: data)
        }.value
        if json["user_info"]["auth"].int == 0 { throw EntertainmentError.authentication }
        return json
    }

    func inventory() async throws -> [EntertainmentItem] {
        async let movies = inventory(kind: .movie)
        async let series = inventory(kind: .series)
        return try await movies + series
    }

    func inventory(kind: EntertainmentKind) async throws -> [EntertainmentItem] {
        let response = try await request(kind == .movie ? "get_vod_streams" : "get_series")
        guard case .array = response else { throw EntertainmentError.malformed }
        let categoryJSON = try? await request(kind == .movie ? "get_vod_categories" : "get_series_categories")
        let categories = Dictionary((categoryJSON?.array ?? []).compactMap { raw -> (String, String)? in
            guard let id = raw["category_id"].string, let name = raw["category_name"].string else { return nil }
            return (id, name)
        }, uniquingKeysWith: { first, _ in first })
        let playlistID = playlist.id
        return await Task.detached(priority: .utility) {
            var seen = Set<String>()
            return response.array.compactMap { raw in
                guard let itemID = raw[kind == .movie ? "stream_id" : "series_id"].string,
                      let title = raw["name"].string else { return nil }
                let source = EntertainmentSource(sourceID: playlistID, itemID: itemID, kind: kind,
                    container: raw["container_extension"].string, category: raw["category_id"].string.flatMap { categories[$0] } ?? raw["category_id"].string)
                guard seen.insert(source.id).inserted else { return nil }
                var result = EntertainmentItem(id: source.id, kind: kind, providerTitle: title, sources: [source])
                result.metadata = Self.providerMetadata(raw)
                result.addedAt = raw["added"].double.map { Date(timeIntervalSince1970: $0) }
                return result
            }
        }.value
    }

    func movieDetails(_ item: EntertainmentItem) async throws -> EntertainmentItem {
        guard let source = item.sources.first(where: { $0.sourceID == playlist.id }) else { throw EntertainmentError.configuration }
        let json = try await request("get_vod_info", item: ("vod_id", source.itemID))
        var updated = item
        updated.metadata = Self.providerMetadata(json["info"])
        if let container = json["movie_data"]["container_extension"].string,
           let index = updated.sources.firstIndex(where: { $0.id == source.id }) {
            updated.sources[index].container = container
        }
        return updated
    }

    func seasons(for series: EntertainmentItem) async throws -> [EntertainmentSeason] {
        try await seriesDetails(series).seasons
    }

    func seriesDetails(_ series: EntertainmentItem) async throws -> (metadata: EntertainmentMetadata, seasons: [EntertainmentSeason]) {
        guard let source = series.sources.first(where: { $0.sourceID == playlist.id }) else { throw EntertainmentError.configuration }
        let response = try await request("get_series_info", item: ("series_id", source.itemID))
        return (Self.providerMetadata(response["info"]), try Self.parseSeasons(response, series: series, sourceID: playlist.id))
    }

    static func parseSeasons(_ response: EntertainmentJSON, series: EntertainmentItem, sourceID: UUID) throws -> [EntertainmentSeason] {
        let groups = response["episodes"]
        if case .array(let values) = groups, values.isEmpty { return [] }
        guard case .object = groups else { throw EntertainmentError.malformed }
        var seasons: [EntertainmentSeason] = []
        for (key, value) in groups.object {
            guard let number = Int(key), number >= 0 else { continue }
            var seen = Set<String>()
            let episodes: [EntertainmentItem] = value.array.compactMap { raw in
                guard let id = raw["id"].string, seen.insert(id).inserted else { return nil }
                let source = EntertainmentSource(sourceID: sourceID, itemID: id, kind: .episode,
                    container: raw["container_extension"].string)
                var item = EntertainmentItem(id: source.id, kind: .episode,
                    providerTitle: raw["title"].string ?? String(localized: "Episode"),
                    sources: [source], seriesID: series.id, seasonNumber: number,
                    episodeNumber: raw["episode_num"].int)
                item.metadata = providerMetadata(raw["info"])
                item.airDate = raw["info"]["releasedate"].string
                return item
            }
            let seasonInfo = response["seasons"].array.first { $0["season_number"].int == number }
            seasons.append(EntertainmentSeason(seriesID: series.id, number: number,
                name: seasonInfo?["name"].string, overview: seasonInfo?["overview"].string,
                poster: safeArtwork(seasonInfo?["cover"].string), airDate: seasonInfo?["air_date"].string,
                episodes: episodes.sorted { ($0.episodeNumber ?? Int.max, $0.id) < ($1.episodeNumber ?? Int.max, $1.id) }))
        }
        return seasons.sorted { $0.number < $1.number }
    }

    static func providerMetadata(_ raw: EntertainmentJSON) -> EntertainmentMetadata {
        var metadata = EntertainmentMetadata()
        metadata.year = raw["year"].int ?? raw["releaseDate"].string.flatMap { Int($0.prefix(4)) }
            ?? raw["releasedate"].string.flatMap { Int($0.prefix(4)) }
        metadata.overview = raw["plot"].string ?? raw["description"].string
        metadata.poster = safeArtwork(raw["stream_icon"].string ?? raw["cover"].string ?? raw["movie_image"].string)
        metadata.backdrop = safeArtwork(raw["backdrop_path"].array.first?.string)
        metadata.tmdbID = raw["tmdb_id"].int ?? raw["tmdb"].int
        metadata.imdbID = raw["imdb_id"].string
        metadata.runtimeMinutes = raw["duration_secs"].int.map { $0 / 60 }
        metadata.genres = raw["genre"].string?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        metadata.director = raw["director"].string
        metadata.cast = raw["cast"].string?.components(separatedBy: ",").prefix(30).map {
            EntertainmentCredit(name: $0.trimmingCharacters(in: .whitespaces))
        } ?? []
        metadata.provenance = ["title": .provider, "overview": .provider, "artwork": .provider]
        return metadata
    }

    /// Avoid storing authenticated image endpoints in the normalized catalog.
    static func safeArtwork(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.query == nil,
              !["/live/", "/movie/", "/series/", "/player_api.php"].contains(where: { url.path.contains($0) }) else { return nil }
        return url
    }

    func resolve(_ source: EntertainmentSource) async throws -> URL {
        guard source.sourceID == playlist.id, source.kind != .series,
              source.availability == .available,
              let credentials = try KeychainStore.xtreamCredentials(for: playlist.credentialID),
              var components = URLComponents(string: playlist.host ?? ""),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { throw EntertainmentError.configuration }
        // The provider must identify its container. Never invent a playable file extension.
        guard let container = source.container, !container.isEmpty,
              container.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              source.itemID.allSatisfy({ $0.isNumber }) else { throw EntertainmentError.unavailable }
        components.query = nil
        components.fragment = nil
        components.percentEncodedPath = "/\(source.kind == .movie ? "movie" : "series")/\(credentials.username.xtreamPathSegment)/\(credentials.password.xtreamPathSegment)/\(source.itemID).\(container)"
        guard let url = components.url else { throw EntertainmentError.configuration }
        return url
    }
}
