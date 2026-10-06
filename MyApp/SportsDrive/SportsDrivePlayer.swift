import Foundation

/// Plays a Sports Drive script: narrates each segment in order, then performs its action
/// through the same shared playback pipeline CarPlay's "Listen Live" and Siri's play
/// intents use (`CarPlayPlaybackCoordinator`) — no separate Sports Drive player. Stops
/// narrating once a segment starts live playback, since the broadcast takes over.
@MainActor
final class SportsDrivePlayer {
    static let shared = SportsDrivePlayer()

    private let narrator: SportsDriveNarrator
    private var runTask: Task<Void, Never>?

    init(narrator: SportsDriveNarrator = SilentSportsDriveNarrator()) {
        self.narrator = narrator
    }

    /// Builds the script from currently-loaded data and plays it. Callers (CarPlay's More
    /// tab, a future phone entry point) pass in whatever they already have loaded —
    /// Sports Drive does not fetch on its own.
    func start(favoriteMatches: [Match], otherLiveMatches: [Match], upcomingFavoriteMatches: [Match]) {
        stop()
        let env = BannerAppEnvironment.shared
        let subscribed = env.podcastStore.catalog.filter { env.podcastStore.subscribedIDs.contains($0.feedURL.absoluteString) }.map { $0.toPodcast() }
        let latestEpisode = subscribed.compactMap { env.podcastStore.episodes(for: $0).first }.max { $0.publishedAt < $1.publishedAt }

        let script = SportsDriveScriptBuilder.build(
            favoriteMatches: favoriteMatches, otherLiveMatches: otherLiveMatches,
            upcomingFavoriteMatches: upcomingFavoriteMatches, latestPodcastEpisode: latestEpisode)

        runTask = Task { [weak self] in
            guard let self else { return }
            for segment in script {
                guard !Task.isCancelled else { return }
                await self.narrator.speak(segment.narration)
                guard !Task.isCancelled else { return }
                switch segment.action {
                case .none:
                    continue
                case .playLiveMatch(let match):
                    CarPlayPlaybackCoordinator.shared.listenLive(to: match)
                    return
                case .playPodcastEpisode(let episode):
                    BannerAppEnvironment.shared.podcastStore.play(episode)
                    return
                }
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
    }
}
