import AppIntents
import Foundation

/// Spoken-language errors — Siri reads `errorDescription` back to the user. Kept generic
/// on purpose: never surface stream URLs, HTTP codes, or provider details through Siri.
enum BannerIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noGameFound(String)
    case noConfirmedBroadcast
    case noEpisodeAvailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noGameFound(let team): return "I couldn't find a live or upcoming game for \(team)."
        case .noConfirmedBroadcast: return "No confirmed broadcast available for that game."
        case .noEpisodeAvailable: return "I couldn't find an episode to play."
        }
    }
}

/// "Play the Senators game on Banner." / "Play the Ottawa game."
/// Reuses the exact same pipeline as CarPlay's Listen Live button — same ranked/confirmed
/// sources, same strict event-identity rule, same shared player — triggered from Siri
/// instead of a CarPlay tap. Runs equally well with or without CarPlay connected.
struct PlayTeamGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Team's Game"
    static let description = IntentDescription("Plays the live broadcast for a followed team's game on Banner.")

    @Parameter(title: "Team") var team: TeamEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$team)'s game")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = BannerAppEnvironment.shared
        guard let league = League.all.first(where: { $0.bannerKey == team.leagueBannerKey }) else {
            throw BannerIntentError.noGameFound(team.name)
        }
        let snapshot = await SportsRepository.shared.liveMatchSnapshot(leagues: [league], startingSoonWindow: 24 * 3600, nextLimit: 10)
        guard let favorite = env.preferences.favoriteTeams.first(where: { $0.canonicalTeamID == team.id }),
              let match = snapshot.live.first(where: { match in
                  [match.home, match.away].contains {
                      $0.canonicalIDString == favorite.canonicalTeamID || $0.teamID == favorite.teamID
                  }
              }) else { throw BannerIntentError.noGameFound(team.name) }
        guard await CarPlayPlaybackCoordinator.shared.playVerifiedGame(match) else {
            throw BannerIntentError.noConfirmedBroadcast
        }
        return .result(dialog: "Playing \(CarPlayPlaybackCoordinator.shared.matchTitle(match)) on Banner.")
    }
}

/// "Play RDS on Banner." / "Play TSN on Banner." — plays a sports channel directly,
/// bypassing event matching since the user named the channel, not a game.
struct PlayChannelIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Sports Channel"
    static let description = IntentDescription("Plays a sports channel's live audio on Banner.")

    @Parameter(title: "Channel") var channel: SportsChannelEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let realChannel = BannerAppEnvironment.shared.playlistStore.allChannels.first(where: { $0.id == channel.id }) else {
            throw BannerIntentError.noGameFound(channel.name)
        }
        CarPlayPlaybackCoordinator.shared.playChannelDirectly(realChannel)
        return .result(dialog: "Playing \(channel.name) on Banner.")
    }
}

/// "What's playing on RDS?" — reuses the existing cache-first EPG repository; no new guide
/// lookup logic.
struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description = IntentDescription("Reads the current programme on a sports channel.")

    @Parameter(title: "Channel") var channel: SportsChannelEntity

    static var parameterSummary: some ParameterSummary {
        Summary("What's playing on \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let realChannel = BannerAppEnvironment.shared.playlistStore.allChannels.first(where: { $0.id == channel.id }) else {
            throw BannerIntentError.noGameFound(channel.name)
        }
        let now = BannerAppEnvironment.shared.epgRepository.currentProgramme(for: realChannel.tvgId ?? realChannel.id)
        guard let now else {
            return .result(dialog: "I don't have programme information for \(channel.name) right now.")
        }
        return .result(dialog: "\(channel.name) is playing \(now.title).")
    }
}

/// "Play my latest sports podcast."
struct PlayLatestPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Latest Podcast"
    static let description = IntentDescription("Plays the latest episode from your followed podcasts.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = BannerAppEnvironment.shared.podcastStore
        await store.ensureCatalogLoaded()
        let subscribed = store.followedPodcasts
        for podcast in subscribed.prefix(12) { await store.loadEpisodes(for: podcast.feedURL) }
        let latest = subscribed.flatMap { store.episodes(for: $0) }.max { $0.publishedAt < $1.publishedAt }
        guard let latest else { throw BannerIntentError.noEpisodeAvailable }
        store.play(latest)
        return .result(dialog: "Playing \(latest.title) from \(latest.podcastTitle).")
    }
}

/// "Play 32 Thoughts." — plays a named podcast's latest episode.
struct PlayPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Podcast"
    static let description = IntentDescription("Plays the latest episode of a followed podcast on Banner.")

    @Parameter(title: "Podcast") var podcast: BannerPodcastEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$podcast)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = BannerAppEnvironment.shared.podcastStore
        await store.ensureCatalogLoaded()
        guard let show = store.followedPodcasts.first(where: { $0.id == podcast.id }) else {
            throw BannerIntentError.noEpisodeAvailable
        }
        await store.loadEpisodes(for: show.feedURL)
        guard let episode = store.episodes(for: show).max(by: { $0.publishedAt < $1.publishedAt }) else {
            throw BannerIntentError.noEpisodeAvailable
        }
        store.play(episode)
        return .result(dialog: "Playing \(episode.title).")
    }
}

/// "Show my live games." — the one intent that needs the app visible, since it's
/// presenting a list, not just starting audio. `openAppWhenRun` is the deprecated
/// predecessor of iOS 26's `supportedModes: IntentModes`; this project's deployment
/// target (iOS 18) predates that API, so this intent uses the still-supported flag.
struct ShowLiveGamesIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Live Games"
    static let description = IntentDescription("Opens Banner to the Live tab.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        BannerAppEnvironment.shared.requestedTab = .live
        return .result()
    }
}

struct BannerAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayTeamGameIntent(),
            phrases: [
                "Play the \(\.$team) game on \(.applicationName)",
                "Play \(\.$team) on \(.applicationName)"
            ],
            shortTitle: "Play Team's Game",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: PlayChannelIntent(),
            phrases: [
                "Play \(\.$channel) on \(.applicationName)"
            ],
            shortTitle: "Play Channel",
            systemImageName: "antenna.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: WhatsPlayingIntent(),
            phrases: [
                "What's playing on \(\.$channel) on \(.applicationName)"
            ],
            shortTitle: "What's Playing",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: PlayLatestPodcastIntent(),
            phrases: [
                "Play my latest sports podcast on \(.applicationName)",
                "Play my latest \(.applicationName) podcast"
            ],
            shortTitle: "Play Latest Podcast",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: PlayPodcastIntent(),
            phrases: [
                "Play \(\.$podcast) on \(.applicationName)"
            ],
            shortTitle: "Play Podcast",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: ShowLiveGamesIntent(),
            phrases: [
                "Show my live games on \(.applicationName)",
                "Show \(.applicationName) live games"
            ],
            shortTitle: "Show Live Games",
            systemImageName: "list.bullet"
        )
    }
}
