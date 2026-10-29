import Foundation
import Testing
@testable import BannerTV

@Suite("Complete experience policies")
@MainActor
struct CompleteExperienceTests {
    private func episode(_ season: Int, _ number: Int, available: Bool = true) -> EntertainmentItem {
        let id = "\(season)-\(number)"
        var source = EntertainmentSource(sourceID: UUID(), itemID: id, kind: .episode, container: "mp4")
        source.availability = available ? .available : .unavailable
        return EntertainmentItem(id: id, kind: .episode, providerTitle: id, sources: [source],
            seriesID: "show", seasonNumber: season, episodeNumber: number)
    }

    @Test func navigationRestoresOnlyBoundedIdentifiers() {
        let path = ["movie:provider:1", "series:provider:2"]
        #expect(EntertainmentNavigationState.decode(EntertainmentNavigationState.encode(path)) == path)
        #expect(EntertainmentNavigationState.decode("invalid").isEmpty)
        #expect(EntertainmentNavigationState.decode(EntertainmentNavigationState.encode(Array(repeating: "id", count: 100))).count == 32)
    }

    @Test func allModesRoundTripWithoutChangingOtherPreferences() throws {
        for mode in ViewingExperience.allCases {
            var preferences = UserPreferences()
            preferences.viewingExperience = mode
            preferences.selectedLeagueIDs = ["hockey/nhl"]
            preferences.spoilerFreeMode = true
            let decoded = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))
            #expect(decoded == preferences)
        }
    }

    @Test func episodeOrderingCrossesSeasonsAndSkipsSpecialsAndUnavailable() throws {
        let last = episode(1, 12), next = episode(2, 2)
        let entries = [next, episode(0, 1), episode(2, 1, available: false), last]
        let state = try #require(EntertainmentProgress.recording(contentID: last.id, variant: "source", position: 99, duration: 100))
        #expect(EntertainmentDiscovery.nextEpisode(seriesID: "show", episodes: entries, progress: [last.id: state])?.id == next.id)
        #expect(EntertainmentDiscovery.nextEpisode(seriesID: "other", episodes: entries, progress: [:]) == nil)
    }

    @Test func unfinishedOfflineEpisodeDoesNotSkipAhead() throws {
        let first = episode(1, 1, available: false), second = episode(1, 2)
        let state = try #require(EntertainmentProgress.recording(contentID: first.id, variant: "source", position: 40, duration: 100))
        #expect(EntertainmentDiscovery.nextEpisode(seriesID: "show", episodes: [second, first], progress: [first.id: state]) == nil)
    }

    @Test func historyIdentitySurvivesMissingInventory() throws {
        let suite = "complete-history-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = episode(1, 1)
        let repository = EntertainmentRepository(defaults: defaults)
        let progress = try #require(EntertainmentProgress.recording(contentID: item.id, variant: "source", position: 99, duration: 100))
        repository.record(progress, item: item)
        let restored = EntertainmentRepository(defaults: defaults)
        #expect(restored.item(for: item.id)?.title == item.title)
        #expect(restored.item(for: item.id)?.isPlayable == false)
        #expect(restored.watchProgress(for: item)?.completed == true)
    }

    @Test func futureEpisodeIsNotSuggested() {
        var future = episode(1, 1)
        future.airDate = "2999-01-01"
        #expect(EntertainmentDiscovery.nextEpisode(seriesID: "show", episodes: [future], progress: [:]) == nil)
    }

    @Test func completedSeriesHasNoNextEpisode() throws {
        let last = episode(2, 4)
        let state = try #require(EntertainmentProgress.recording(contentID: last.id, variant: "source", position: 99, duration: 100))
        #expect(EntertainmentDiscovery.nextEpisode(seriesID: "show", episodes: [last], progress: [last.id: state]) == nil)
    }

    @Test func resumeIsDeduplicatedAndExcludesCompleted() throws {
        let first = episode(1, 1), second = episode(1, 2)
        let unfinished = try #require(EntertainmentProgress.recording(contentID: first.id, variant: "a", position: 30, duration: 100))
        let completed = try #require(EntertainmentProgress.recording(contentID: second.id, variant: "a", position: 99, duration: 100))
        let result = EntertainmentDiscovery.continuing(items: [first, first, second], progress: [first.id: unfinished, second.id: completed])
        #expect(result.map(\.id) == [first.id])
    }

    @Test func searchRanksExactMatchAndFiltersKind() {
        var exact = episode(1, 1); exact.providerTitle = "Arrival"
        var broad = episode(1, 2); broad.providerTitle = "The Arrival Story"
        let movie = EntertainmentItem(id: "movie", kind: .movie, providerTitle: "Arrival")
        #expect(EntertainmentDiscovery.search([broad, exact], query: "arrival").first?.id == exact.id)
        #expect(EntertainmentDiscovery.search([movie, exact], query: "arrival", kind: .movie).map(\.id) == ["movie"])
        #expect(EntertainmentDiscovery.search([movie], query: " ").isEmpty)
    }

    @Test func recommendationsNeverInventInventoryOrRepeatCompletedTitles() throws {
        var movie = episode(1, 1); movie.kind = .movie
        let metadataOnly = EntertainmentItem(id: "metadata", kind: .movie, providerTitle: "Metadata")
        #expect(EntertainmentDiscovery.recommendations(items: [metadataOnly], kind: .movie, progress: [:], watchlist: []).isEmpty)
        #expect(EntertainmentDiscovery.recommendations(items: [movie, movie], kind: .movie, progress: [:], watchlist: []).count == 1)
        let completed = try #require(EntertainmentProgress.recording(contentID: movie.id, variant: "a", position: 99, duration: 100))
        #expect(EntertainmentDiscovery.recommendations(items: [movie], kind: .movie, progress: [movie.id: completed], watchlist: []).isEmpty)
    }

    @Test func hidingContinueWatchingPreservesProgressAndRestores() throws {
        let suite = "complete-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = episode(1, 1)
        let repository = EntertainmentRepository(defaults: defaults)
        let progress = try #require(EntertainmentProgress.recording(contentID: item.id, variant: "source", position: 30, duration: 100))
        repository.record(progress)
        repository.hideFromContinueWatching(item)
        let restored = EntertainmentRepository(defaults: defaults)
        #expect(restored.watchProgress(for: item) == progress)
        #expect(restored.hiddenContinueWatching.contains(item.progressID))
        restored.record(progress)
        #expect(!restored.hiddenContinueWatching.contains(item.progressID))
    }

    @Test func savedWatchlistSurvivesMissingProviderWithoutFakePlayback() throws {
        let suite = "complete-watchlist-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = episode(1, 1)
        defaults.set([item.id], forKey: "banner.entertainment.watchlist.v1")
        defaults.set(try JSONEncoder().encode([item.id: item]), forKey: "banner.entertainment.watchlistItems.v1")
        let repository = EntertainmentRepository(defaults: defaults)
        let saved = try #require(repository.item(for: item.id))
        #expect(saved.title == item.title)
        #expect(!saved.isPlayable)
        #expect(repository.watchlist.contains(item.id))
    }

    @Test func completionPolicyHandlesShortAndUnknownDuration() {
        #expect(EntertainmentProgress.recording(contentID: "short", variant: "a", position: 20, duration: 20)?.completed == true)
        #expect(EntertainmentProgress.recording(contentID: "unknown", variant: "a", position: 1000, duration: nil)?.completed == false)
        #expect(EntertainmentProgress.recording(contentID: "movie", variant: "a", position: 90, duration: 100, completionFraction: 0.99)?.completed == false)
    }

    @Test func largeSearchAndRankingRemainBounded() {
        let entries = (0..<10000).map { index in
            EntertainmentItem(id: String(index), kind: index % 2 == 0 ? .movie : .series, providerTitle: "Title \(index)")
        }
        let start = ContinuousClock.now
        let result = EntertainmentDiscovery.search(entries, query: "Title 42")
        #expect(result.count <= 100)
        #expect(result.first?.id == "42")
        print("Phase 3 search, 10000 titles: \(start.duration(to: .now))")
    }
}
