import Foundation
import AVFoundation
#if os(iOS)
import MediaPlayer
import UIKit
#endif

extension Notification.Name {
    /// The live TV player is taking over lock-screen / Control Center / AirPods commands.
    static let bannerVideoTookRemoteCommands = Notification.Name("bannertv.videoTookRemoteCommands")
    /// The live TV player closed; the podcast player can reclaim the remote commands.
    static let bannerVideoReleasedRemoteCommands = Notification.Name("bannertv.videoReleasedRemoteCommands")
}

// MARK: - Aspect

/// How the video fills the player area. Remembered per channel.
enum PlayerAspectMode: String, CaseIterable, Identifiable {
    case fit, fill, stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        }
    }

    var subtitle: String {
        switch self {
        case .fit: return "Whole picture, may letterbox"
        case .fill: return "Fill the screen, may crop edges"
        case .stretch: return "Fill the screen, may distort"
        }
    }

    var systemImage: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.left.and.right.square"
        }
    }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }

    var next: PlayerAspectMode {
        switch self {
        case .fit: return .fill
        case .fill: return .stretch
        case .stretch: return .fit
        }
    }

    private static let storageKey = "bannertv.player.aspectByChannel.v1"

    static func saved(for channelID: String) -> PlayerAspectMode {
        let map = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        return map[channelID].flatMap(PlayerAspectMode.init(rawValue:)) ?? .fit
    }

    static func save(_ mode: PlayerAspectMode, for channelID: String) {
        var map = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        if mode == .fit { map[channelID] = nil } else { map[channelID] = mode.rawValue }
        UserDefaults.standard.set(map, forKey: storageKey)
    }
}

// MARK: - Quality

/// Resolution cap for the current stream. `auto` lets AVPlayer adapt freely.
enum PlayerQualityCap: Hashable, Identifiable {
    case auto
    case height(Int)

    var id: String { title }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .height(let h): return "\(h)p"
        }
    }

    /// Standard caps offered when the stream advertises at least that height.
    static let standardHeights = [1080, 720, 480]

    var maximumResolution: CGSize {
        switch self {
        case .auto: return .zero
        case .height(let h): return CGSize(width: CGFloat(h) * 16 / 9, height: CGFloat(h))
        }
    }

    /// Rough peak bitrate per cap, applied alongside the resolution limit for variant selection.
    var peakBitRate: Double {
        switch self {
        case .auto: return 0
        case .height(let h) where h >= 1080: return 8_000_000
        case .height(let h) where h >= 720: return 4_500_000
        case .height: return 2_000_000
        }
    }
}

// MARK: - Now Playing

/// Publishes the live channel to the lock screen / Control Center and routes remote
/// play/pause to the video while the player is on screen.
@MainActor
final class VideoNowPlaying {
    #if os(iOS)
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkTask: Task<Void, Never>?
    #endif
    private(set) var isActive = false

    func activate(controller: PlaybackController) {
        #if os(iOS)
        guard !isActive else { return }
        isActive = true
        NotificationCenter.default.post(name: .bannerVideoTookRemoteCommands, object: nil)
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        // Live streams can't skip or scrub.
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
            })
        ]
        #endif
    }

    func update(title: String, subtitle: String?, artworkURL: URL?, isPlaying: Bool) {
        #if os(iOS)
        guard isActive else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork],
           MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == title {
            info[MPMediaItemPropertyArtwork] = existing
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        artworkTask?.cancel()
        guard let artworkURL, info[MPMediaItemPropertyArtwork] == nil else { return }
        artworkTask = Task { [weak self] in
            guard let cgImage = try? await ImagePipeline.shared.cgImage(for: artworkURL, maxPixelSize: 512),
                  !Task.isCancelled, let self, self.isActive else { return }
            let uiImage = UIImage(cgImage: cgImage)
            let artwork = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
            var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? info
            current[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = current
        }
        #endif
    }

    func deactivate() {
        #if os(iOS)
        guard isActive else { return }
        isActive = false
        artworkTask?.cancel()
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NotificationCenter.default.post(name: .bannerVideoReleasedRemoteCommands, object: nil)
        #endif
    }
}
