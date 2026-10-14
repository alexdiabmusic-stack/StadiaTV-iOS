import Foundation

/// Drives CarPlay's playback. Reuses `PlaybackController` and `StreamAvailabilityStore`'s
/// ranked/confirmed sources exactly as the phone player does — this file adds no new
/// matching, ranking, or stream-resolution logic of its own.
///
/// `playbackController` is `BannerAppEnvironment.shared.playbackController` — the same
/// single `AVPlayer`-owning instance the phone's `PlayerView` uses — not a separate one.
/// Both surfaces observe the same player. The active live context separately identifies
/// the match for score presentation and existing Live Activity prioritization.
@MainActor
final class CarPlayPlaybackCoordinator {
    enum PlaybackFailure: Equatable {
        case noConfirmedBroadcast
        case streamUnavailable(String)
        case gameEnded
    }

    static let shared = CarPlayPlaybackCoordinator()

    var playbackController: PlaybackController { BannerAppEnvironment.shared.playbackController }
    private let nowPlaying = CarPlayNowPlaying()

    private(set) var currentContext: MatchPlaybackContext?
    /// Set by the owning coordinator so Now Playing metadata and failure UI stay in sync
    /// with the list the user is looking at.
    var onFailure: ((PlaybackFailure) -> Void)?
    var onStateChange: (() -> Void)?

    private var selectionTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var requestID = UUID()
    private let failureObserverID = UUID()

    private init() {}

    /// Observe failures without replacing the phone player's presentation callbacks.
    /// A stable owner identifier prevents duplicate registrations on repeated playback.
    private func claimCallbacks() {
        playbackController.observeFailures(owner: failureObserverID) { [weak self] reason in
            guard let self, self.playbackController.isAudioOnlySession else { return }
            self.onFailure?(.streamUnavailable(reason))
        }
    }

    /// Entry point for "Listen Live": ranks this match's sources through the existing
    /// `StreamAvailabilityStore`, picks the top confirmed one, and starts it. Never falls
    /// back to an unconfirmed/possible source — that would break the strict event-identity
    /// rule the phone app already enforces.
    /// Awaitable entry point for Siri; success means verification accepted the selected stream.
    func playVerifiedGame(_ match: Match) async -> Bool {
        let id = UUID()
        requestID = id
        let env = BannerAppEnvironment.shared
        guard match.state == .live else { return false }
        await env.streamStore.scan(matches: [match], channels: env.playlistStore.allChannels,
                                   epgRepository: env.epgRepository)
        guard requestID == id, !Task.isCancelled,
              let source = confirmedBroadcasts(for: match).first else { return false }
        let confirmed = await env.streamStore.confirmsCurrentBroadcast(
            match: match, channel: source.channel, channels: env.playlistStore.allChannels,
            epgRepository: env.epgRepository)
        guard confirmed, requestID == id, !Task.isCancelled else { return false }
        play(match: match, source: source, allSources: confirmedBroadcasts(for: match))
        return true
    }

    func listenLive(to match: Match, onStarted: (() -> Void)? = nil) {
        selectionTask?.cancel()
        guard match.state == .live else {
            onFailure?(.gameEnded)
            return
        }
        let ranked = BannerAppEnvironment.shared.streamStore.topRanked(for: match.id, limit: 5)
        guard let best = ranked.first(where: \.isConfirmed) else {
            onFailure?(.noConfirmedBroadcast)
            return
        }
        verifyAndPlay(match: match, source: best, allSources: ranked, onStarted: onStarted)
    }

    /// "Change Broadcast": swaps to a different already-ranked source for the same match.
    /// Never accepts a source for a different match — the context carries one event identity.
    func changeBroadcast(to source: RankedSource, onStarted: (() -> Void)? = nil) {
        guard let match = currentContext?.match, let sources = currentContext?.rankedSources,
              source.isConfirmed, sources.contains(where: { $0.channel.id == source.channel.id && $0.isConfirmed }) else { return }
        verifyAndPlay(match: match, source: source, allSources: sources, onStarted: onStarted)
    }

    func playBroadcast(for match: Match, source: RankedSource, onStarted: (() -> Void)? = nil) {
        let sources = confirmedBroadcasts(for: match)
        guard match.state == .live, source.isConfirmed,
              sources.contains(where: { $0.channel.id == source.channel.id && $0.channel.streamURL == source.channel.streamURL }) else {
            onFailure?(.noConfirmedBroadcast)
            return
        }
        verifyAndPlay(match: match, source: source, allSources: sources, onStarted: onStarted)
    }

    private func verifyAndPlay(match: Match, source: RankedSource, allSources: [RankedSource],
                               onStarted: (() -> Void)?) {
        selectionTask?.cancel()
        let id = UUID()
        requestID = id
        selectionTask = Task { [weak self] in
            let env = BannerAppEnvironment.shared
            let confirmed = await env.streamStore.confirmsCurrentBroadcast(
                match: match, channel: source.channel, channels: env.playlistStore.allChannels,
                epgRepository: env.epgRepository)
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            guard confirmed else {
                self.onFailure?(.noConfirmedBroadcast)
                return
            }
            self.play(match: match, source: source, allSources: allSources)
            onStarted?()
        }
    }

    /// Releases CarPlay metadata before the shared podcast player takes ownership.
    func relinquishPlayback() {
        requestID = UUID()
        metadataTask?.cancel()
        selectionTask?.cancel()
        nowPlaying.deactivate()
        currentContext = nil
        BannerAppEnvironment.shared.noteActiveLivePlayback(nil)
    }

    func stop() {
        requestID = UUID()
        metadataTask?.cancel()
        selectionTask?.cancel()
        let stoppingMatchID = currentContext?.match.id
        playbackController.stop()
        nowPlaying.deactivate()
        currentContext = nil
        if BannerAppEnvironment.shared.activeLivePlaybackContext?.match.id == stoppingMatchID {
            BannerAppEnvironment.shared.noteActiveLivePlayback(nil)
        }
        if LiveActivityManager.shared.trackedMatchID == stoppingMatchID {
            LiveActivityManager.shared.setExplicitlyTracked(matchID: nil)
        }
        onStateChange?()
    }

    func confirmedBroadcasts(for match: Match) -> [RankedSource] {
        BannerAppEnvironment.shared.streamStore.topRanked(for: match.id, limit: 5).filter(\.isConfirmed)
    }

    private func play(match: Match, source: RankedSource, allSources: [RankedSource]) {
        let context = MatchPlaybackContext(match: match, channel: source.channel, rankedSources: allSources)
        currentContext = context
        claimCallbacks()
        playbackController.load(source.channel, audioOnly: true)
        nowPlaying.activate(controller: playbackController) { [weak self] in self?.stop() }
        nowPlaying.update(title: matchTitle(match), subtitle: nowPlayingSubtitle(match: match, source: source),
                           isLive: true, isPlaying: playbackController.state == .playing)
        BannerAppEnvironment.shared.noteActiveLivePlayback(context)
        nowPlaying.updateSports(match, favorites: BannerAppEnvironment.shared.preferences.favoriteTeams)
        startMetadataUpdates(for: context)
        if match.state == .live {
            LiveActivityManager.shared.setExplicitlyTracked(matchID: match.id)
        }
        onStateChange?()
    }

    /// Plays a sports channel directly (CarPlay's Listen tab, Siri's `PlayChannelIntent`) —
    /// no `Match`/event identity involved, so there's no `MatchPlaybackContext` to carry.
    func playChannelDirectly(_ channel: Channel) {
        requestID = UUID()
        metadataTask?.cancel()
        selectionTask?.cancel()
        BannerAppEnvironment.shared.noteActiveLivePlayback(nil)
        currentContext = nil
        claimCallbacks()
        playbackController.load(channel, audioOnly: true)
        nowPlaying.activate(controller: playbackController) { [weak self] in self?.stop() }
        nowPlaying.clearSports()
        nowPlaying.update(title: channel.name, subtitle: nil, isLive: true, isPlaying: playbackController.state == .playing)
        onStateChange?()
    }

    private func startMetadataUpdates(for initial: MatchPlaybackContext) {
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.nowPlaying.isActive,
                      self.playbackController.channel?.id == initial.channel.id else { return }
                let matches = try? await SportsRepository.shared.cachedLegacyScoreboard(for: initial.match.league, maxAge: 15)
                guard !Task.isCancelled else { return }
                guard let match = matches?.first(where: { $0.id == initial.match.id }) else { continue }
                let context = MatchPlaybackContext(match: match, channel: initial.channel, rankedSources: initial.rankedSources)
                self.currentContext = context
                BannerAppEnvironment.shared.noteActiveLivePlayback(context)
                self.nowPlaying.update(title: self.matchTitle(match),
                    subtitle: MatchAudioPresentation.status(match) + " · " + initial.channel.name,
                    isLive: true, isPlaying: self.playbackController.state == .playing)
                self.nowPlaying.updateSports(match, favorites: BannerAppEnvironment.shared.preferences.favoriteTeams)
                self.onStateChange?()
                // Preserve postgame audio; only the sports-data polling ends at Final.
                if match.state == .final { return }
            }
        }
    }

    func refreshPresentationPreferences() {
        guard nowPlaying.isActive, let context = currentContext,
              playbackController.channel?.id == context.channel.id else { return }
        nowPlaying.update(title: matchTitle(context.match),
                          subtitle: MatchAudioPresentation.status(context.match) + " · " + context.channel.name,
                          isLive: true, isPlaying: playbackController.state == .playing)
        nowPlaying.updateSports(context.match, favorites: BannerAppEnvironment.shared.preferences.favoriteTeams)
    }

    func matchTitle(_ match: Match) -> String {
        "\(match.home.displayName) vs \(match.away.displayName)"
    }

    /// e.g. "OTT 3 — TOR 2 · 3rd 8:42 · TSN5"
    func nowPlayingSubtitle(match: Match, source: RankedSource) -> String {
        var parts: [String] = []
        if match.hasDisplayScore && !BannerAppEnvironment.shared.preferences.prefs.spoilerFreeMode {
            parts.append("\(match.home.abbreviation) \(match.home.score ?? "0") — \(match.away.abbreviation) \(match.away.score ?? "0")")
        }
        parts.append(MatchAudioPresentation.status(match))
        parts.append(source.channel.name)
        return parts.joined(separator: " · ")
    }
}
