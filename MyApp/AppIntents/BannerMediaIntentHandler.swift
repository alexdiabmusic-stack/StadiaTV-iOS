#if os(iOS)
import Foundation
import Intents
import UIKit

@MainActor
final class BannerApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? BannerMediaIntentHandler() : nil
    }
}

/// In-app SiriKit routing. Identifiers resolve only against the user's existing library.
nonisolated final class BannerMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    func resolveMediaItems(for intent: INPlayMediaIntent,
                           with completion: @escaping @Sendable ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        let identifier = intent.mediaItems?.first?.identifier ?? intent.mediaSearch?.mediaIdentifier
        let title = intent.mediaSearch?.mediaName ?? intent.mediaItems?.first?.title
        let resume = intent.resumePlayback == true
        Task { @MainActor in
            let env = BannerAppEnvironment.shared
            await env.podcastStore.ensureCatalogLoaded()
            if resume, let episode = env.podcastStore.continueListeningEpisode {
                let item = INMediaItem(identifier: "episode:" + episode.id, title: episode.title, type: .podcastEpisode, artwork: nil)
                completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .success(with: item))])
                return
            }
            var choices = env.podcastStore.followedPodcasts.map {
                INMediaItem(identifier: "podcast:" + $0.id, title: $0.title, type: .podcastShow, artwork: nil)
            }
            choices += env.playlistStore.allChannels.filter(BannerSportsChannelClassifier.isSportsChannel).map {
                INMediaItem(identifier: "channel:" + $0.id, title: $0.name, type: .radioStation, artwork: nil)
            }
            choices += env.podcastStore.listeningLibrary.history.map {
                INMediaItem(identifier: "episode:" + $0.id, title: $0.title, type: .podcastEpisode, artwork: nil)
            }
            let matches: [INMediaItem]
            if let identifier {
                matches = choices.filter { $0.identifier == identifier }
            } else if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let exact = choices.filter { $0.title?.localizedCaseInsensitiveCompare(title) == .orderedSame }
                matches = exact.isEmpty ? choices.filter { $0.title?.localizedCaseInsensitiveContains(title) == true } : exact
            } else {
                completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .needsValue())])
                return
            }
            if let match = matches.first, matches.count == 1 {
                completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .success(with: match))])
            } else if matches.count > 1 {
                completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .disambiguation(with: Array(matches.prefix(10))))])
            } else {
                completion([INPlayMediaMediaItemResolutionResult(mediaItemResolutionResult: .unsupported())])
            }
        }
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping @Sendable (INPlayMediaIntentResponse) -> Void) {
        let identifier = intent.mediaItems?.first?.identifier
        let resume = intent.resumePlayback == true
        let requestedSpeed = intent.playbackSpeed.map { Float($0) }
        Task { @MainActor in
            let env = BannerAppEnvironment.shared
            let store = env.podcastStore
            let success: Bool
            if let requestedSpeed, PodcastSpeed(rawValue: requestedSpeed) == nil {
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }
            if resume, let episode = store.continueListeningEpisode {
                if store.nowPlaying?.id == episode.id {
                    if !store.isPlaying { store.togglePlayPause() }
                } else { store.play(episode) }
                success = true
            } else if let identifier, identifier.hasPrefix("channel:"),
                      let channel = env.playlistStore.allChannels.first(where: { "channel:" + $0.id == identifier }) {
                CarPlayPlaybackCoordinator.shared.playChannelDirectly(channel)
                success = true
            } else if let identifier, identifier.hasPrefix("podcast:") {
                await store.ensureCatalogLoaded()
                if let podcast = store.followedPodcasts.first(where: { "podcast:" + $0.id == identifier }) {
                    await store.loadEpisodes(for: podcast.feedURL)
                    if let episode = store.episodes(for: podcast).max(by: { $0.publishedAt < $1.publishedAt }) {
                        store.play(episode)
                        success = true
                    } else { success = false }
                } else { success = false }
            } else if let identifier, let episode = store.listeningLibrary.history.first(where: { "episode:" + $0.id == identifier }) {
                store.play(episode)
                success = true
            } else { success = false }
            if success, let requestedSpeed, let speed = PodcastSpeed(rawValue: requestedSpeed),
               !((identifier ?? "").hasPrefix("channel:")) { store.setSpeed(speed) }
            completion(INPlayMediaIntentResponse(code: success ? .success : .failure, userActivity: nil))
        }
    }
}
#endif
