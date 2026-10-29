import Foundation
import Testing
@testable import BannerTV

@Suite("Phase 2 entertainment foundation")
@MainActor
struct EntertainmentFoundationTests {
    @Test func legacyPreferencesKeepSportsAndOtherData() throws {
        let data = Data(#"{"hasCompletedOnboarding":true,"selectedLeagueIDs":["hockey/nhl"],"spoilerFreeMode":true}"#.utf8)
        let preferences = try JSONDecoder().decode(UserPreferences.self, from: data)
        #expect(preferences.viewingExperience == .sports)
        #expect(preferences.sportsIntegration == .compact)
        #expect(preferences.selectedLeagueIDs == ["hockey/nhl"])
        #expect(preferences.spoilerFreeMode)
        #expect(preferences.hasCompletedOnboarding)
    }

    @Test func modeRoundTripPreservesSelections() throws {
        var preferences = UserPreferences()
        preferences.selectedLeagueIDs = ["hockey/nhl"]
        preferences.viewingExperience = .liveTV
        preferences.sportsIntegration = .hidden
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
        #expect(NavigationConfiguration.configuration(for: decoded.viewingExperience).tabs == [.home, .channels, .guide, .library, .settings])
        preferences.viewingExperience = .sports
        #expect(preferences.selectedLeagueIDs == ["hockey/nhl"])
        #expect(NavigationConfiguration.configuration(for: .sports).tabs == [.home, .following, .live, .discover, .settings])
        #expect(ViewingExperience.allCases.count == 2)
    }

    @Test func unknownFutureModeFallsBackWithoutResettingData() throws {
        let value = try JSONDecoder().decode(UserPreferences.self,
            from: Data(#"{"viewingExperience":"complete","selectedLeagueIDs":["hockey/nhl"]}"#.utf8))
        #expect(value.viewingExperience == .sports)
        #expect(value.selectedLeagueIDs.contains("hockey/nhl"))
    }

    @Test func titleMatchingRejectsAmbiguityAndRemakes() {
        var original = EntertainmentMetadata()
        original.canonicalTitle = "Example Film"
        original.year = 1980
        original.tmdbID = 1
        var remake = original
        remake.year = 2020; remake.tmdbID = 2
        #expect(EntertainmentMatching.match(title: "Example:  Film", year: 1980, candidates: [original, remake])?.tmdbID == 1)
        #expect(EntertainmentMatching.match(title: "Example Film", year: nil, candidates: [original, remake]) == nil)
        #expect(EntertainmentMatching.match(title: "Example Film", year: 1980, candidates: [original, original]) == nil)
    }

    @Test func cautiousEpisodeParsing() {
        #expect(EntertainmentMatching.episodeNumbers("Show S00E02")?.season == 0)
        #expect(EntertainmentMatching.episodeNumbers("Show Season 1 Episode 12")?.episode == 12)
        #expect(EntertainmentMatching.episodeNumbers("Show S01E01-E02") == nil)
        #expect(EntertainmentMatching.episodeNumbers("Show S01E01E02") == nil)
        #expect(EntertainmentMatching.episodeNumbers("News at 10") == nil)
    }

    @Test func progressRequiresPlaybackAndKnownDurationForCompletion() {
        #expect(EntertainmentProgress.recording(contentID: "a", variant: "b", position: .nan, duration: 100) == nil)
        #expect(EntertainmentProgress.recording(contentID: "a", variant: "b", position: 1, duration: 100)?.completed == false)
        #expect(EntertainmentProgress.recording(contentID: "a", variant: "b", position: 99, duration: nil)?.completed == false)
        #expect(EntertainmentProgress.recording(contentID: "a", variant: "b", position: 99, duration: 100)?.completed == true)
    }

    @Test func progressPersistsWithoutPlaybackURLs() throws {
        let suite = "phase2-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = EntertainmentRepository(defaults: defaults)
        let progress = try #require(EntertainmentProgress.recording(contentID: "movie:1", variant: "provider:1", position: 42, duration: 100))
        repository.record(progress)
        repository.toggleWatchlist("movie:1")
        let restored = EntertainmentRepository(defaults: defaults)
        #expect(restored.progress["movie:1"] == progress)
        #expect(restored.watchlist.contains("movie:1"))
        let encoded = try #require(defaults.data(forKey: "banner.entertainment.progress.v1"))
        let string = String(decoding: encoded, as: UTF8.self)
        #expect(!string.contains("http"))
        #expect(!string.contains("password"))
    }

    @Test func providerSeasonInventoryIsAuthoritative() throws {
        let sourceID = UUID()
        let series = EntertainmentItem(id: "series:1", kind: .series, providerTitle: "Example")
        let json = try JSONDecoder().decode(EntertainmentJSON.self, from: Data(#"""
        {"episodes":{"0":[{"id":"900","title":"Special","episode_num":1,"container_extension":"mp4"}],
        "1":[{"id":901,"title":"First","episode_num":"1","container_extension":"mkv"},
             {"id":902,"title":"Missing number","container_extension":"mp4"}]}}
        """#.utf8))
        let seasons = try XtreamEntertainmentAdapter.parseSeasons(json, series: series, sourceID: sourceID)
        #expect(seasons.count == 2)
        #expect(seasons[0].number == 0)
        #expect(seasons[1].episodes.count == 2)
        #expect(seasons[1].episodes[1].episodeNumber == nil)
        #expect(seasons[1].episodes[0].sources[0].itemID == "901")
        #expect(seasons[1].episodes[0].isPlayable)
    }

    @Test func unknownAvailabilityCannotPlay() {
        var source = EntertainmentSource(sourceID: UUID(), itemID: "1", kind: .movie, container: "mp4")
        source.availability = .unknown
        let item = EntertainmentItem(id: "1", kind: .movie, providerTitle: "Example",
            metadata: EntertainmentMetadata(canonicalTitle: "Rich metadata", tmdbID: 10), sources: [source])
        #expect(!item.isPlayable)
        #expect(!EntertainmentItem(id: "2", kind: .episode, providerTitle: "Metadata only").isPlayable)
    }

    @Test func artworkRejectsAuthenticatedEndpoints() {
        #expect(XtreamEntertainmentAdapter.safeArtwork("https://example.test/poster.jpg") != nil)
        #expect(XtreamEntertainmentAdapter.safeArtwork("https://example.test/poster?password=private") == nil)
        #expect(XtreamEntertainmentAdapter.safeArtwork("https://user:private@example.test/poster.jpg") == nil)
        #expect(XtreamEntertainmentAdapter.safeArtwork("https://example.test/movie/user/private/1.mp4") == nil)
    }

    @Test func largeInventoryClassificationIsConservative() throws {
        let source = UUID()
        let url = try #require(URL(string: "https://example.invalid/content.mp4"))
        let channels = (0..<22000).map {
            Channel(id: String($0), name: "Title \($0)", streamURL: url, logoURL: nil,
                group: $0 < 5000 ? "Movies" : "News", playlistID: source, playlistName: "Fixture")
        }
        let start = ContinuousClock.now
        let items = EntertainmentRepository.classifyM3U(channels)
        let elapsed = start.duration(to: .now)
        #expect(items.count == 5000)
        #expect(Set(items.map(\.id)).count == items.count)
        print("Phase 2 classification: 22000 entries, 5000 movies, elapsed \(elapsed)")
    }

    @Test func verifiedIdentityGroupsSourcesButNotUnmatchedTitles() {
        let firstSource = EntertainmentSource(sourceID: UUID(), itemID: "1", kind: .movie, container: "mp4")
        let secondSource = EntertainmentSource(sourceID: UUID(), itemID: "2", kind: .movie, container: "mp4")
        var first = EntertainmentItem(id: firstSource.id, kind: .movie, providerTitle: "Example", sources: [firstSource])
        var second = EntertainmentItem(id: secondSource.id, kind: .movie, providerTitle: "Example", sources: [secondSource])
        #expect(EntertainmentRepository.canonicalPresentation([first, second]).count == 2)
        first.metadata.tmdbID = 101; first.metadata.confidence = .verifiedIdentifier
        second.metadata = first.metadata
        let merged = EntertainmentRepository.canonicalPresentation([first, second])
        #expect(merged.count == 1)
        #expect(merged[0].sources.count == 2)
        #expect(first.progressID == second.progressID)
        second.providerTitle = "Example Extended Edition"
        #expect(first.progressID != second.progressID)
        #expect(EntertainmentRepository.canonicalPresentation([first, second]).count == 2)
    }

    @Test func m3uSeriesRequireExplicitGroupAndNumbering() throws {
        let sourceID = UUID()
        let url = try #require(URL(string: "https://example.invalid/episode.mp4"))
        let channel = Channel(id: "episode-1", name: "Example S00E01", streamURL: url,
            logoURL: nil, group: "TV Shows", playlistID: sourceID, playlistName: "Test")
        let result = EntertainmentRepository.classifyM3USeries([channel])
        #expect(result.items.count == 1)
        let season = try #require(result.seasons.values.first?.first)
        #expect(season.number == 0)
        #expect(season.episodes.first?.episodeNumber == 1)
        #expect(season.episodes.first?.sources.first?.itemID == channel.id)
        #expect(EntertainmentRepository.classifyM3USeries([channel.renamed(to: "News tonight")]).items.isEmpty)
    }

    @Test func xtreamInventoryUsesSecureReferencesAndToleratesNumericStrings() async throws {
        let sourceID = UUID()
        try KeychainStore.saveXtreamCredentials(.init(username: "fixture-user", password: "fixture-password"), for: sourceID)
        defer { KeychainStore.deleteXtreamCredentials(for: sourceID) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EntertainmentFixtureProtocol.self]
        let playlist = Playlist(id: sourceID, name: "Fixture", kind: .xtream, host: "https://provider.example.test")
        let adapter = XtreamEntertainmentAdapter(playlist: playlist, session: URLSession(configuration: config))
        let movies = try await adapter.inventory(kind: .movie)
        #expect(movies.count == 1)
        #expect(movies.first?.sources.first?.itemID == "123")
        #expect(movies.first?.sources.first?.category == "Drama")
        let encoded = String(decoding: try JSONEncoder().encode(movies), as: UTF8.self)
        #expect(!encoded.contains("fixture-password"))
        #expect(!encoded.contains("fixture-user"))
        let source = try #require(movies.first?.sources.first)
        let resolved = try await adapter.resolve(source)
        #expect(resolved.pathExtension == "mp4")
        #expect(resolved.path.hasSuffix("/123.mp4"))
    }

    private func metadataService() -> TMDBMetadataService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EntertainmentFixtureProtocol.self]
        return TMDBMetadataService(token: "fixture-token", session: URLSession(configuration: config))
    }

    @Test func metadataValidatesProviderIdentifiers() async throws {
        let service = metadataService()
        var item = EntertainmentItem(id: "movie:1", kind: .movie, providerTitle: "Example")
        item.metadata.tmdbID = 101
        item.metadata.year = 2020
        let enriched = try await service.enrich(item, language: "fr-CA")
        #expect(enriched.confidence == .verifiedIdentifier)
        #expect(enriched.overview == "English fallback")
        #expect(enriched.poster?.absoluteString == "https://images.example.test/w500/poster.jpg")
        item.providerTitle = "Unrelated Movie"
        await #expect(throws: EntertainmentError.self) { try await service.enrich(item, language: "en-CA") }
    }

    @Test func metadataNeverCreatesPlayableEpisodes() async throws {
        let source = EntertainmentSource(sourceID: UUID(), itemID: "901", kind: .episode, container: "mp4")
        let episode = EntertainmentItem(id: source.id, kind: .episode, providerTitle: "Provider episode",
            sources: [source], seriesID: "series:1", seasonNumber: 1, episodeNumber: 1)
        let season = EntertainmentSeason(seriesID: "series:1", number: 1, episodes: [episode])
        let enriched = try await metadataService().enrichSeason(season, seriesTMDBID: 101, language: "en-CA")
        #expect(enriched.episodes.count == 1)
        #expect(enriched.episodes[0].title == "First Episode")
        #expect(enriched.episodes[0].sources == [source])
    }

    @Test func disabledMetadataDoesNotInventResults() async {
        let item = EntertainmentItem(id: "1", kind: .movie, providerTitle: "Example")
        await #expect(throws: EntertainmentError.self) { try await TMDBMetadataService().enrich(item, language: "en-CA") }
    }
}

private final class EntertainmentFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        let body: String
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "action" })?.value
        if action == "get_vod_streams" {
            body = #"[{"stream_id":"123","name":"Example","container_extension":"mp4","category_id":5,"year":"2020"}]"#
        } else if action == "get_vod_categories" {
            body = #"[{"category_id":"5","category_name":"Drama"}]"#
        } else if url.path.hasSuffix("/configuration") {
            body = #"{"images":{"secure_base_url":"https://images.example.test/","poster_sizes":["w500"],"backdrop_sizes":["w780"],"still_sizes":["w300"],"logo_sizes":["w300"]}}"#
        } else if url.path.contains("/season/") {
            body = #"{"name":"Season One","episodes":[{"id":1,"season_number":1,"episode_number":1,"name":"First Episode"},{"id":2,"season_number":1,"episode_number":2,"name":"Unavailable Episode"}]}"#
        } else if url.query?.contains("language=en-US") == true {
            body = #"{"id":101,"title":"Example","original_title":"Example","release_date":"2020-01-01","overview":"English fallback"}"#
        } else {
            body = #"{"id":101,"title":"Example","original_title":"Example","release_date":"2020-01-01","poster_path":"/poster.jpg","overview":"","credits":{"cast":[]},"genres":[]}"#
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
