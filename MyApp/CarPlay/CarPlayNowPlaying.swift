import Foundation
import MediaPlayer
import AVFoundation
#if canImport(CarPlay)
import CarPlay
#endif

/// Publishes CarPlay's current audio (live game or sports channel) to
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`. `CPNowPlayingTemplate` mirrors
/// `MPNowPlayingInfoCenter` automatically, so this is the only Now Playing wiring CarPlay
/// needs — no separate CarPlay-specific Now Playing UI to maintain.
///
/// Shares synchronous NowPlayingOwnership with the phone video and podcast publishers,
/// so only one publisher owns system commands and asynchronous artwork at a time.
@MainActor
final class CarPlayNowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var playbackObservation: NSKeyValueObservation?
    private let ownershipID = UUID()
    private(set) var isActive = false

    func activate(controller: PlaybackController, onStop: @escaping @MainActor () -> Void) {
        guard !isActive else { return }
        NowPlayingOwnership.shared.claim(ownershipID) { [weak self] in self?.deactivate() }
        isActive = true
        NotificationCenter.default.post(name: .bannerVideoTookRemoteCommands, object: nil)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        // Live audio can't skip or scrub.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        playbackObservation = controller.player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor [weak self] in
                guard let self, self.isActive,
                      var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
                info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                NotificationCenter.default.post(name: .bannerAudioLibraryChanged, object: nil)
            }
        }

        targets = [
            (center.playCommand, center.playCommand.addTarget { [weak controller] _ in
                Task { @MainActor in controller?.play() }
                return .success
            }),
            (center.pauseCommand, center.pauseCommand.addTarget { [weak controller] _ in
                Task { @MainActor in controller?.pause() }
                return .success
            }),
            (center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak controller] _ in
                Task { @MainActor in controller?.togglePlayPause() }
                return .success
            }),
            (center.stopCommand, center.stopCommand.addTarget { _ in
                Task { @MainActor in onStop() }
                return .success
            })
        ]
    }

    /// `title`/`subtitle` carry the game matchup and live score/status (e.g.
    /// "Ottawa Senators vs Toronto Maple Leafs" / "OTT 3 — TOR 2 · 3rd 8:42 · TSN5").
    func update(title: String, subtitle: String?, isLive: Bool, isPlaying: Bool) {
        guard isActive else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func updateSports(_ match: Match, favorites: [FavoriteTeam]) {
        #if canImport(CarPlay)
        guard isActive else { return }
        if #available(iOS 26.0, *) {
            // Racing and golf are not two-team sports; respect the shared spoiler preference.
            guard CarPlayRollout.shared.sportsMode, !BannerAppEnvironment.shared.preferences.prefs.spoilerFreeMode, !["racing/f1", "golf/pga"].contains(match.league.path) else {
                CPNowPlayingTemplate.shared.nowPlayingMode = nil
                return
            }
            func team(_ side: TeamSide) -> CPNowPlayingSportsTeam {
                let favorite = favorites.contains {
                    ($0.leaguePath == match.league.path || $0.leagueBannerKey == match.league.bannerKey) &&
                    ($0.canonicalTeamID == side.canonicalIDString || $0.teamID == side.teamID)
                }
                return CPNowPlayingSportsTeam(name: side.displayName,
                    logo: CPNowPlayingSportsTeamLogo(teamInitials: side.abbreviation),
                    teamStandings: nil, eventScore: side.score ?? "–",
                    possessionIndicator: nil, favorite: favorite)
            }
            // Provider snapshots are not synchronized to stream latency. A paused clock
            // faithfully displays the last received game time without inventing ticks.
            let clock: CPNowPlayingSportsClock?
            if match.state == .live, let remaining = match.liveContext.clock?.remainingSeconds,
               remaining >= 0, !match.league.path.hasPrefix("soccer/") {
                clock = CPNowPlayingSportsClock(timeRemaining: TimeInterval(remaining), paused: true)
            } else { clock = nil }
            let status = CPNowPlayingSportsEventStatus(
                eventStatusText: [MatchAudioPresentation.status(match), String(localized: "Scores may be ahead of audio")],
                eventStatusImage: nil, eventClock: clock)
            CPNowPlayingTemplate.shared.nowPlayingMode = CPNowPlayingModeSports(
                leftTeam: team(match.away), rightTeam: team(match.home), eventStatus: status,
                backgroundArtwork: nil)
        }
        #endif
    }

    func clearSports() {
        #if canImport(CarPlay)
        if #available(iOS 26.0, *) { CPNowPlayingTemplate.shared.nowPlayingMode = nil }
        #endif
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        playbackObservation?.invalidate()
        playbackObservation = nil
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        if NowPlayingOwnership.shared.release(ownershipID) {
            clearSports()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        NotificationCenter.default.post(name: .bannerVideoReleasedRemoteCommands, object: nil)
    }
}
