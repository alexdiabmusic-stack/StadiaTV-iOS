import UIKit

// The seam between the app (iOS 16.1+, links libmpv) and BannerPlaybackKit (iOS 18+, links AetherEngine).
//
// This framework has no dependencies and an iOS 16.1 floor, and both sides link it, so the protocol and type identities are
// shared and the app can talk to an engine it never imports. Values cross in the app's own units (milliseconds, strings).

public struct BannerMediaTrack: Sendable, Equatable {
    /// The engine's own id for the track (what `select…Track(id:)` takes back).
    public let id: Int
    public let label: String
    public let language: String
    public let codec: String
    public let isSelected: Bool
    /// A picture subtitle (PGS, DVB, VobSub). The shared subtitle overlay draws text only.
    public let isBitmap: Bool

    public init(id: Int, label: String, language: String, codec: String, isSelected: Bool, isBitmap: Bool = false) {
        self.id = id; self.label = label; self.language = language; self.codec = codec; self.isSelected = isSelected; self.isBitmap = isBitmap
    }
}

public struct BannerSubtitleSource: Sendable, Equatable {
    public let url: String
    public let language: String
    public let name: String?
    public let headers: [String: String]?

    public init(url: String, language: String, name: String?, headers: [String: String]?) {
        self.url = url; self.language = language; self.name = name; self.headers = headers
    }
}

public struct BannerLoadRequest: Sendable {
    public var url: String
    /// Resume position in seconds (a handoff from another engine, or a saved position); nil starts at the beginning.
    public var startSeconds: Double?
    public var headers: [String: String]
    public var subtitles: [BannerSubtitleSource]
    public var preferredAudioLanguages: [String]
    public var preferredSubtitleLanguages: [String]
    public var isLive: Bool
    /// Start playing when ready. The viewer's latest play/pause intent wins over this while the source is loading.
    public var autoplay: Bool
    /// The range the app's subtitle-delay control can reach, so the engine retains only the cues that range needs.
    public var maximumSubtitleDelaySeconds: Double
    public var maximumSubtitleAdvanceSeconds: Double

    public init(
        url: String, startSeconds: Double? = nil, headers: [String: String] = [:], subtitles: [BannerSubtitleSource] = [],
        preferredAudioLanguages: [String] = [], preferredSubtitleLanguages: [String] = [], isLive: Bool = false, autoplay: Bool = true,
        maximumSubtitleDelaySeconds: Double = 60, maximumSubtitleAdvanceSeconds: Double = 60
    ) {
        self.url = url; self.startSeconds = startSeconds; self.headers = headers; self.subtitles = subtitles
        self.preferredAudioLanguages = preferredAudioLanguages; self.preferredSubtitleLanguages = preferredSubtitleLanguages
        self.isLive = isLive; self.autoplay = autoplay
        self.maximumSubtitleDelaySeconds = maximumSubtitleDelaySeconds; self.maximumSubtitleAdvanceSeconds = maximumSubtitleAdvanceSeconds
    }
}

/// Everything the app's polling loop reads each tick, already in milliseconds.
public struct BannerPlaybackSnapshot: Sendable, Equatable {
    public var positionMs: Int64 = 0
    public var durationMs: Int64 = 0
    public var bufferedMs: Int64 = 0
    public var isLoading = true
    public var isPlaying = false
    public var isEnded = false
    public var speed: Float = 1
    public var videoWidth = 0
    public var videoHeight = 0
    /// Empty unless the engine failed. Never contains source addresses.
    public var errorMessage = ""

    public init() {}
}

public struct BannerBackendFailure: Sendable, Equatable {
    /// The engine's machine-readable kind (`PlaybackErrorKind.rawValue`), nil when none was available.
    public let kind: String?
    public let message: String
    /// The same failure is reported twice (thrown and published); equal ids are one failure.
    public let id: String

    public init(kind: String?, message: String, id: String) {
        self.kind = kind; self.message = message; self.id = id
    }
}

public enum BannerBackendEvent: Sendable {
    case failed(BannerBackendFailure)
    /// The viewer asked for something this engine cannot show (a picture-subtitle track). The app may hand the session to libmpv.
    case needsOtherEngine(reason: String, language: String)
    case firstFrame
    case ended
    case tracksChanged
}

@MainActor
public protocol BannerPlaybackBackend: AnyObject {
    var viewController: UIViewController { get }
    var snapshot: BannerPlaybackSnapshot { get }
    var onEvent: ((BannerBackendEvent) -> Void)? { get set }
    /// Receives the text of the current subtitle cue ("" when none). Called only when the text changes.
    var onSubtitleText: ((String) -> Void)? { get set }
    var keepsPlaybackInBackground: Bool { get }

    func load(_ request: BannerLoadRequest)
    func play()
    func pause()
    func seek(toMs: Int64)
    func setRate(_ rate: Float)
    var volume: Float { get set }
    func setMuted(_ muted: Bool)
    /// 0 fit, 1 fill, 2 zoom (the app's own numbering).
    func setResizeMode(_ mode: Int)

    func audioTracks() -> [BannerMediaTrack]
    func subtitleTracks() -> [BannerMediaTrack]
    func selectAudioTrack(id: Int)
    /// `-1` turns subtitles off.
    func selectSubtitleTrack(id: Int)
    func setSubtitleDelayMs(_ ms: Int)
    /// Adds a subtitle file to the running session (an addon's subtitle picked after the film started) and selects it.
    func addExternalSubtitle(_ source: BannerSubtitleSource)

    /// The same keys the libmpv path publishes (videoCodec, hdrFormat, …) plus the engine's own.
    func mediaInfo() -> [String: Any]
    /// Rendering route, startup and first-frame timings, rebuffer count, engine version and similar.
    func diagnostics() -> [String: Any]

    /// Whether Picture in Picture can start now (the route has a layer or source for it, and the system allows it).
    var isPictureInPictureSupported: Bool { get }
    func startPictureInPicture()

    func setNowPlaying(title: String, subtitle: String?, artworkURL: String?)
    func clearNowPlaying()
    func destroy()
}

/// What BannerPlaybackKit hands the app. One factory per process; each `makeBackend()` is one playback surface.
@MainActor
public protocol BannerPlaybackBackendFactory: AnyObject {
    var engineVersion: String { get }
    func makeBackend() -> BannerPlaybackBackend?
}
