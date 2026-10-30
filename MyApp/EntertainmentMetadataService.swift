import Foundation

nonisolated protocol EntertainmentMetadataProvider: Sendable {
    func enrich(_ item: EntertainmentItem, language: String) async throws -> EntertainmentMetadata
    func enrichSeason(_ season: EntertainmentSeason, seriesTMDBID: Int, language: String) async throws -> EntertainmentSeason
}

/// Original TMDB implementation. No API secret is embedded in the application.
/// Production remains disabled until an authorized metadata configuration is supplied.
actor TMDBMetadataService: EntertainmentMetadataProvider {
    static let shared = TMDBMetadataService()
    private let token: String?
    private let session: URLSession
    private var cache: [String: (Date, EntertainmentJSON)] = [:]
    private var inFlight: [String: Task<EntertainmentJSON, Error>] = [:]
    private var activeRequests = 0

    init(token: String? = nil, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    var isConfigured: Bool { token?.isEmpty == false }

    private func request(_ path: String, query: [URLQueryItem] = [], freshness: TimeInterval = 86400) async throws -> EntertainmentJSON {
        guard let token, !token.isEmpty else { throw EntertainmentError.metadataDisabled }
        guard var url = URLComponents(string: "https://api.themoviedb.org/3/" + path) else { throw EntertainmentError.configuration }
        url.queryItems = query
        guard let endpoint = url.url else { throw EntertainmentError.configuration }
        let key = endpoint.absoluteString
        if let cached = cache[key], Date().timeIntervalSince(cached.0) < freshness { return cached.1 }
        if let pending = inFlight[key] { return try await pending.value }
        while activeRequests >= 4 {
            try await Task.sleep(for: .milliseconds(100))
            if let pending = inFlight[key] { return try await pending.value }
        }
        activeRequests += 1
        let session = session
        let task = Task<EntertainmentJSON, Error> {
            var request = URLRequest(url: endpoint, timeoutInterval: 20)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            for attempt in 0..<3 {
                try Task.checkCancellation()
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw EntertainmentError.unavailable }
                if http.statusCode == 429 || http.statusCode >= 500 {
                    guard attempt < 2 else { throw EntertainmentError.rateLimited }
                    let delay = min(15, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? pow(2, Double(attempt))))
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                if [401, 403].contains(http.statusCode) { throw EntertainmentError.authentication }
                guard (200..<300).contains(http.statusCode), data.count <= 5_000_000 else { throw EntertainmentError.unavailable }
                return try JSONDecoder().decode(EntertainmentJSON.self, from: data)
            }
            throw EntertainmentError.unavailable
        }
        inFlight[key] = task
        defer { inFlight[key] = nil; activeRequests -= 1 }
        let result = try await task.value
        if cache.count >= 128, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache[oldest] = nil }
        cache[key] = (Date(), result)
        try Task.checkCancellation()
        return result
    }

    func enrich(_ item: EntertainmentItem, language: String) async throws -> EntertainmentMetadata {
        let type = item.kind == .movie ? "movie" : "tv"
        var tmdbID = item.metadata.tmdbID
        var identifierProvided = tmdbID != nil
        if tmdbID == nil, let imdb = item.metadata.imdbID,
           imdb.range(of: #"^tt\d+$"#, options: .regularExpression) != nil {
            let found = try await request("find/" + imdb, query: [URLQueryItem(name: "external_source", value: "imdb_id")])
            let candidates = found[type == "movie" ? "movie_results" : "tv_results"].array
            if candidates.count == 1 { tmdbID = candidates.first?["id"].int; identifierProvided = true }
        }
        if tmdbID == nil {
            var query = [URLQueryItem(name: "query", value: item.providerTitle), URLQueryItem(name: "language", value: language)]
            if let year = item.metadata.year { query.append(URLQueryItem(name: type == "movie" ? "year" : "first_air_date_year", value: String(year))) }
            let results = try await request("search/" + type, query: query)
            let candidates = results["results"].array.map { Self.primaryMetadata($0, kind: item.kind) }
            tmdbID = EntertainmentMatching.match(title: item.providerTitle, year: item.metadata.year, candidates: candidates)?.tmdbID
        }
        guard let tmdbID, tmdbID > 0 else { throw EntertainmentError.unavailable }
        let details = try await request("\(type)/\(tmdbID)", query: [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "append_to_response", value: "credits,external_ids,images"),
            URLQueryItem(name: "include_image_language", value: "\(language.prefix(2)),en,null")
        ], freshness: item.kind == .movie ? 604800 : 86400)
        var result = Self.primaryMetadata(details, kind: item.kind)
        // A supplied ID is evidence, not authority: conflicting titles or years must not overwrite the provider.
        let providerTitle = EntertainmentMatching.normalized(item.providerTitle)
        let titles = [result.canonicalTitle, result.originalTitle].compactMap { $0 }.map(EntertainmentMatching.normalized)
        guard titles.contains(providerTitle),
              item.metadata.year == nil || result.year == item.metadata.year else { throw EntertainmentError.unavailable }
        if result.overview?.isEmpty != false, !language.hasPrefix("en") {
            let fallback = try? await request("\(type)/\(tmdbID)", query: [URLQueryItem(name: "language", value: "en-US")])
            result.overview = fallback?["overview"].string
        }
        result.confidence = identifierProvided ? .verifiedIdentifier : .highConfidence
        result.imdbID = details["imdb_id"].string ?? details["external_ids"]["imdb_id"].string
        result.genres = details["genres"].array.compactMap { $0["name"].string }
        result.runtimeMinutes = details["runtime"].int ?? details["episode_run_time"].array.first?.int
        result.cast = details["credits"]["cast"].array.prefix(30).compactMap {
            guard let name = $0["name"].string else { return nil }
            return EntertainmentCredit(name: name, role: $0["character"].string)
        }
        result.director = details["credits"]["crew"].array.first { $0["job"].string == "Director" }?["name"].string
        if let rating = details["vote_average"].double, (details["vote_count"].int ?? 0) > 0 {
            result.ratings = [EntertainmentRating(value: rating, scale: 10, source: "TMDB")]
        }
        result.firstAirDate = details["first_air_date"].string
        result.lastAirDate = details["last_air_date"].string
        result.status = details["status"].string
        if let config = try? await request("configuration", freshness: 604800) {
            result.poster = Self.imageURL(details["poster_path"].string, configuration: config, type: "poster", preferred: "w500")
            result.backdrop = Self.imageURL(details["backdrop_path"].string, configuration: config, type: "backdrop", preferred: "w780")
            let logos = details["images"]["logos"].array
            let logo = logos.first { $0["iso_639_1"].string == String(language.prefix(2)) } ?? logos.first
            result.titleLogo = Self.imageURL(logo?["file_path"].string, configuration: config, type: "logo", preferred: "w300")
        }
        result.provenance = ["title": .tmdb, "overview": .tmdb, "artwork": .tmdb, "credits": .tmdb, "ratings": .tmdb]
        return result
    }

    func enrichSeason(_ season: EntertainmentSeason, seriesTMDBID: Int, language: String) async throws -> EntertainmentSeason {
        let json = try await request("tv/\(seriesTMDBID)/season/\(season.number)", query: [URLQueryItem(name: "language", value: language)])
        let config = try? await request("configuration", freshness: 604800)
        var result = season
        result.name = json["name"].string
        result.overview = json["overview"].string
        result.airDate = json["air_date"].string
        // Enrich only provider-backed episodes. A metadata episode never creates a source.
        let groups = Dictionary(grouping: json["episodes"].array, by: { $0["episode_number"].int })
        let providerGroups = Dictionary(grouping: season.episodes, by: \.episodeNumber)
        result.episodes = season.episodes.map { episode in
            guard let number = episode.episodeNumber, providerGroups[number]?.count == 1,
                  let matches = groups[number], matches.count == 1, let raw = matches.first,
                  raw["season_number"].int == season.number else { return episode }
            var episode = episode
            episode.metadata.canonicalTitle = raw["name"].string
            episode.metadata.overview = raw["overview"].string ?? episode.metadata.overview
            episode.metadata.runtimeMinutes = raw["runtime"].int ?? episode.metadata.runtimeMinutes
            episode.metadata.tmdbID = raw["id"].int
            episode.metadata.confidence = .highConfidence
            episode.airDate = raw["air_date"].string
            if let config {
                episode.metadata.poster = Self.imageURL(raw["still_path"].string, configuration: config, type: "still", preferred: "w300") ?? episode.metadata.poster
            }
            episode.metadata.provenance["episode"] = .tmdb
            return episode
        }
        return result
    }

    nonisolated static func primaryMetadata(_ raw: EntertainmentJSON, kind: EntertainmentKind) -> EntertainmentMetadata {
        var result = EntertainmentMetadata()
        result.tmdbID = raw["id"].int
        result.canonicalTitle = raw[kind == .movie ? "title" : "name"].string
        result.originalTitle = raw[kind == .movie ? "original_title" : "original_name"].string
        result.year = raw[kind == .movie ? "release_date" : "first_air_date"].string.flatMap { Int($0.prefix(4)) }
        result.overview = raw["overview"].string
        return result
    }

    nonisolated static func imageURL(_ path: String?, configuration: EntertainmentJSON, type: String, preferred: String) -> URL? {
        guard let path, path.hasPrefix("/"), !path.contains(".."),
              let base = configuration["images"]["secure_base_url"].string, base.hasPrefix("https://") else { return nil }
        let sizes = configuration["images"][type + "_sizes"].array.compactMap(\.string)
        guard let size = sizes.first(where: { $0 == preferred }) ?? sizes.first(where: { $0 != "original" }) else { return nil }
        return URL(string: base + size + path)
    }
}
