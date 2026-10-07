import Foundation

/// One beat of a Sports Drive script — narration text, optionally paired with an action
/// to take once the narration finishes (e.g. "Playing the broadcast" → actually start it).
/// Content is built entirely from existing Banner data (`Match`, `PodcastEpisode`); this
/// type carries no sports logic of its own.
nonisolated struct SportsDriveSegment: Identifiable {
    enum Action {
        case none
        case playLiveMatch(Match)
        case playPodcastEpisode(PodcastEpisode)
    }

    let id = UUID()
    let narration: String
    let action: Action
}

/// Builds an ordered Sports Drive script from Banner's existing stores — followed teams,
/// current scores, upcoming games, and podcasts. Keeps narration text short and
/// radio-announcer-ish per the product brief's example sequence. Does not fetch anything
/// itself; the caller passes in already-loaded data so this stays synchronous and testable.
@MainActor
enum SportsDriveScriptBuilder {
    static func build(
        favoriteMatches: [Match],
        otherLiveMatches: [Match],
        upcomingFavoriteMatches: [Match],
        latestPodcastEpisode: PodcastEpisode?
    ) -> [SportsDriveSegment] {
        var segments: [SportsDriveSegment] = [SportsDriveSegment(narration: greeting(), action: .none)]

        if let nextUpcoming = upcomingFavoriteMatches.first {
            segments.append(SportsDriveSegment(narration: upcomingLine(for: nextUpcoming), action: .none))
        }

        if let liveFavorite = favoriteMatches.first(where: { $0.state == .live }) {
            segments.append(SportsDriveSegment(narration: liveScoreLine(for: liveFavorite), action: .none))
            segments.append(SportsDriveSegment(narration: "That game is live now. Playing the broadcast.", action: .playLiveMatch(liveFavorite)))
            return segments
        }

        if let otherLive = otherLiveMatches.first {
            segments.append(SportsDriveSegment(narration: liveScoreLine(for: otherLive), action: .none))
        }

        if let episode = latestPodcastEpisode {
            segments.append(SportsDriveSegment(
                narration: "Here's the latest episode of \(episode.podcastTitle): \(episode.title).",
                action: .playPodcastEpisode(episode)))
        }

        return segments
    }

    private static func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning."
        case 12..<17: return "Good afternoon."
        default: return "Good evening."
        }
    }

    private static func upcomingLine(for match: Match) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE 'at' h:mm a"
        return "The \(match.home.displayName) play \(match.away.displayName) \(formatter.string(from: match.date).lowercased())."
    }

    private static func liveScoreLine(for match: Match) -> String {
        "The \(match.home.displayName) \(match.hasDisplayScore ? "lead \(match.away.displayName) \(match.home.score ?? "0") to \(match.away.score ?? "0")" : "are playing \(match.away.displayName)"), \(match.statusDetail)."
    }
}
