import Foundation

/// Sports Drive uses the same persisted podcast queue as the phone and CarPlay.
@MainActor
final class SportsDrivePlayer {
    static let shared = SportsDrivePlayer()
    private var runTask: Task<Void, Never>?

    init(narrator: SportsDriveNarrator = SilentSportsDriveNarrator()) {}

    func start(favoriteMatches: [Match], otherLiveMatches: [Match], upcomingFavoriteMatches: [Match]) {
        stop()
        guard CarPlayRollout.shared.sportsDrive else { return }
        runTask = Task {
            let store = BannerAppEnvironment.shared.podcastStore
            await store.ensureCatalogLoaded()
            for podcast in store.followedPodcasts.prefix(12) {
                guard !Task.isCancelled else { return }
                await store.loadEpisodes(for: podcast.feedURL)
            }
            guard !Task.isCancelled, CarPlayRollout.shared.sportsDrive else { return }
            let episodes = Array(AudioRecommendations.rank(store: store).prefix(20).map(\.episode))
            store.playQueue(episodes)
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
    }
}
