import Foundation

/// Drives CarPlay's playback. Reuses `PlaybackController` and `StreamAvailabilityStore`'s
/// ranked/confirmed sources exactly as the phone player does — this file adds no new
/// matching, ranking, or stream-resolution logic of its own.
///
/// `playbackController` is `BannerAppEnvironment.shared.playbackController` — the same
/// single `AVPlayer`-owning instance the phone's `PlayerView` uses — not a separate one.
/// That's what makes continuity real rather than a hint: if the phone is already playing a
/// channel, `load()`'s existing "already playing this channel" short-circuit means CarPlay
/// (or Siri) asking to play the same one is a no-op that just starts reflecting state,
/// and vice versa. `BannerAppEnvironment.activeLivePlaybackContext` still exists as a
/// higher-level "which *match* is live right now" signal for UI (e.g. Live Activity
/// priority), separate from the player identity question this now solves directly.
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

    private init() {}

    /// `PlaybackController.onFailure`/`onItemReady`/etc. are single-closure callbacks, not
    /// multicast — and the controller is now shared with the phone's `PlayerView`, which
    /// reassigns them to its own closures every time it appears. So CarPlay must (re)claim
    /// them right before *it* starts playback too, the same way `PlayerView.startPlayback()`
    /// already does, rather than once in `init`. Whichever surface most recently started
    /// playback owns the callbacks — consistent with "whichever surface the user is
    /// actively driving wins" being the right behavior for a single shared player.
    private func claimCallbacks() {
        playbackController.onFailure = { [weak self] reason in
            self?.onFailure?(.streamUnavailable(reason))
        }
    }

    /// Entry point for "Listen Live": ranks this match's sources through the existing
    /// `StreamAvailabilityStore`, picks the top confirmed one, and starts it. Never falls
    /// back to an unconfirmed/possible source — that would break the strict event-identity
    /// rule the phone app already enforces.
    func listenLive(to match: Match) {
        guard match.state != .final else {
            onFailure?(.gameEnded)
            return
        }
        let ranked = BannerAppEnvironment.shared.streamStore.topRanked(for: match.id, limit: 5)
        guard let best = ranked.first(where: \.isConfirmed) else {
            onFailure?(.noConfirmedBroadcast)
            return
        }
        play(match: match, source: best, allSources: ranked)
    }

    /// "Change Broadcast": swaps to a different already-ranked source for the same match.
    /// Never accepts a source for a different match — the context carries one event identity.
    func changeBroadcast(to source: RankedSource) {
        guard let match = currentContext?.match, let sources = currentContext?.rankedSources else { return }
        play(match: match, source: source, allSources: sources)
    }

    func stop() {
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
        nowPlaying.activate(controller: playbackController)
        nowPlaying.update(title: matchTitle(match), subtitle: nowPlayingSubtitle(match: match, source: source),
                           isLive: match.state == .live, isPlaying: true)
        BannerAppEnvironment.shared.noteActiveLivePlayback(context)
        if match.state == .live {
            LiveActivityManager.shared.setExplicitlyTracked(matchID: match.id)
        }
        onStateChange?()
    }

    /// Plays a sports channel directly (CarPlay's Listen tab, Siri's `PlayChannelIntent`) —
    /// no `Match`/event identity involved, so there's no `MatchPlaybackContext` to carry.
    func playChannelDirectly(_ channel: Channel) {
        currentContext = nil
        claimCallbacks()
        playbackController.load(channel, audioOnly: true)
        nowPlaying.activate(controller: playbackController)
        nowPlaying.update(title: channel.name, subtitle: nil, isLive: true, isPlaying: true)
        onStateChange?()
    }

    func matchTitle(_ match: Match) -> String {
        "\(match.home.displayName) vs \(match.away.displayName)"
    }

    /// e.g. "OTT 3 — TOR 2 · 3rd 8:42 · TSN5"
    func nowPlayingSubtitle(match: Match, source: RankedSource) -> String {
        var parts: [String] = []
        if match.hasDisplayScore {
            parts.append("\(match.home.abbreviation) \(match.home.score ?? "0") — \(match.away.abbreviation) \(match.away.score ?? "0")")
        }
        if !match.statusDetail.isEmpty { parts.append(match.statusDetail) }
        parts.append(source.channel.name)
        return parts.joined(separator: " · ")
    }
}
