import Foundation
import MediaPlayer

/// Publishes CarPlay's current audio (live game or sports channel) to
/// `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`. `CPNowPlayingTemplate` mirrors
/// `MPNowPlayingInfoCenter` automatically, so this is the only Now Playing wiring CarPlay
/// needs — no separate CarPlay-specific Now Playing UI to maintain.
///
/// Mirrors `VideoNowPlaying`'s remote-command handoff convention (posting the same
/// `.bannerVideoTookRemoteCommands` / `.bannerVideoReleasedRemoteCommands` notifications)
/// so the podcast player yields/reclaims exactly as it already does for the phone video
/// player — no new coordination notifications needed.
@MainActor
final class CarPlayNowPlaying {
    private var targets: [(MPRemoteCommand, Any)] = []
    private(set) var isActive = false

    func activate(controller: PlaybackController, onChangeBroadcast: (() -> Void)? = nil) {
        guard !isActive else { return }
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
            (center.stopCommand, center.stopCommand.addTarget { [weak controller] _ in
                Task { @MainActor in controller?.stop() }
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

    func deactivate() {
        guard isActive else { return }
        isActive = false
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.post(name: .bannerVideoReleasedRemoteCommands, object: nil)
    }
}
