import Foundation
import AVFoundation

// MARK: - Buffer Profile

/// How aggressively AVPlayer trades start-up speed for stall resistance.
/// Persisted in `UserPreferences.playerBufferProfile`.
nonisolated enum PlayerBufferProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case fast = "Fast"
    case balanced = "Balanced"
    case stable = "Stable"

    var id: String { rawValue }

    /// `preferredForwardBufferDuration`; 0 lets AVPlayer choose.
    var forwardBufferDuration: TimeInterval {
        switch self {
        case .fast: return 2
        case .balanced: return 0
        case .stable: return 30
        }
    }

    var waitsToMinimizeStalling: Bool {
        self == .stable
    }

    /// How long the start-up watchdog waits for a first frame before giving up on a source.
    var startupTimeout: TimeInterval {
        self == .fast ? 7 : 10
    }

    var description: String {
        switch self {
        case .fast: return "Starts quickest, small buffer"
        case .balanced: return "Fast start, system buffer (default)"
        case .stable: return "Waits to buffer, fewest stalls"
        }
    }
}

// MARK: - Item factory

/// Builds AVURLAssets/AVPlayerItems the same way for the main player and multiscreen tiles.
nonisolated enum PlaybackItemFactory {
    /// Creates an asset that sends the channel's provider headers on every request
    /// (playlist, variant playlists, segments and keys).
    static func makeAsset(url: URL, headers: [String: String]?) -> AVURLAsset {
        var options: [String: Any] = [:]
        var remaining = headers ?? [:]
        if let userAgentKey = remaining.keys.first(where: { $0.caseInsensitiveCompare(StreamHTTPHeaders.userAgentKey) == .orderedSame }),
           let userAgent = remaining.removeValue(forKey: userAgentKey) {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        if !remaining.isEmpty {
            // No public constant exists for arbitrary headers; this undocumented key is the
            // one AVFoundation honours and IPTV players commonly rely on.
            options["AVURLAssetHTTPHeaderFieldsKey"] = remaining
        }
        return AVURLAsset(url: url, options: options)
    }

    static func makeItem(
        url: URL,
        headers: [String: String]?,
        profile: PlayerBufferProfile,
        peakBitRate: Double = 0
    ) -> AVPlayerItem {
        let item = AVPlayerItem(asset: makeAsset(url: url, headers: headers))
        // NOTE: `startsOnFirstEligibleVariant` used to be forced on here to skip AVPlayer's
        // initial bandwidth probe. With no peak-bitrate/resolution cap set (the default,
        // `.auto`), "first eligible variant" means "whichever rendition is listed first in
        // the master playlist" with nothing to fall back to — for genuine multi-bitrate
        // streams (e.g. a real 4K ABR ladder) that's often the highest-bitrate rendition,
        // which hangs forever if the network can't sustain it. Single-variant IPTV feeds
        // (the majority of channels) have no choice to force either way, so leaving this at
        // AVPlayer's default adaptive selection only affects genuine multi-variant streams,
        // restoring the ability to step down to a sustainable bitrate.
        item.preferredForwardBufferDuration = profile.forwardBufferDuration
        item.preferredPeakBitRate = peakBitRate
        return item
    }

    static func apply(_ profile: PlayerBufferProfile, to player: AVPlayer) {
        player.automaticallyWaitsToMinimizeStalling = profile.waitsToMinimizeStalling
        player.currentItem?.preferredForwardBufferDuration = profile.forwardBufferDuration
    }

    /// URLs to try, in order, as HLS for a stream. AVPlayer can't play raw MPEG-TS, so an Xtream-shaped `.ts` or
    /// extension-less URL is tried as its HLS `.m3u8` form first, keeping the original as a fallback. (The ways of
    /// playing a channel, including converting a transport stream, are `PlaybackCandidates`.)
    static func playbackURLCandidates(for url: URL) -> [URL] {
        PlaybackCandidates.hlsURLCandidates(for: url)
    }

    /// Rewrites `http(s)://host[:port]/{user}/{pass}/{id}` and
    /// `/live/{user}/{pass}/{id}[.ts]` to `/live/{user}/{pass}/{id}.m3u8`.
    static func xtreamHLSURL(for url: URL) -> URL? {
        PlaybackCandidates.xtreamHLSURL(for: url)
    }
}
