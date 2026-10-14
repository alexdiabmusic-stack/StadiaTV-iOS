import Foundation

/// Ranks existing, playable episodes; team relationships come from the shared discovery pipeline.
@MainActor
enum AudioRecommendations {
    struct Recommendation: Identifiable {
        let episode: PodcastEpisode
        let reason: String
        var id: String { episode.id }
    }

    static func rank(store: PodcastStore, teamPodcastIDs: Set<String> = []) -> [Recommendation] {
        var seen = Set<String>()
        let candidates = store.episodesByFeed.values.flatMap { $0 }.filter {
            !store.isPlayed($0) && !$0.isVideo && seen.insert($0.id).inserted &&
            (store.subscribedIDs.contains($0.podcastID) || teamPodcastIDs.contains($0.podcastID))
        }
        func score(_ episode: PodcastEpisode) -> Double {
            let age = max(0, Date().timeIntervalSince(episode.publishedAt) / 86_400)
            let followed = store.subscribedIDs.contains(episode.podcastID) ? 100.0 : 0
            let team = teamPodcastIDs.contains(episode.podcastID) ? 80.0 : 0
            let familiar = store.listeningLibrary.history.contains { $0.podcastID == episode.podcastID } ? 20.0 : 0
            return followed + team + familiar + max(0, 30 - age)
        }
        return candidates.sorted {
            let lhs = score($0), rhs = score($1)
            return lhs == rhs ? $0.publishedAt > $1.publishedAt : lhs > rhs
        }.map {
            Recommendation(episode: $0, reason: teamPodcastIDs.contains($0.podcastID)
                ? String(localized: "For your teams") : String(localized: "From your podcasts"))
        }
    }
}
