import Foundation

// Engine selection and fallback rules for the hybrid player (AetherEngine and libmpv).
//
// Everything here is pure: no AetherEngine import (it is iOS 18+ and lives in BannerPlaybackKit), no UIKit, no I/O, so it
// compiles for the app's iOS 16.1 floor and is covered by unit tests. The patterns follow the tvOS coordinator in
// bobsupra/NuvioTVOS (backend policy, session generations, one fallback per attempt), adapted to BannerTV's request shape.

/// The Playback Engine setting.
enum PlaybackEngineChoice: String, CaseIterable {
    /// AetherEngine for what it handles, libmpv for what it cannot, and one fallback on a confirmed engine failure.
    case automatic
    /// Prefer AetherEngine. A failure is reported, not silently handed to libmpv.
    case aether
    /// The existing player, as before.
    case mpv

    static let defaultsKey = "playback.engine"
    /// "Switch to libmpv if AetherEngine fails", honoured even when the explicit AetherEngine choice is set.
    static let emergencyFallbackKey = "playback.engine.emergencyFallback"

    static func emergencyFallbackEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: emergencyFallbackKey)
    }
    static let defaultChoice: PlaybackEngineChoice = .automatic

    /// The saved choice; anything unreadable means the default.
    static func stored(in defaults: UserDefaults = .standard) -> PlaybackEngineChoice {
        defaults.string(forKey: defaultsKey).flatMap(PlaybackEngineChoice.init(rawValue:)) ?? defaultChoice
    }
}

enum PlaybackBackendKind: String, Equatable {
    case aether
    case mpv

    var displayName: String { self == .aether ? "AetherEngine" : "libmpv" }
}

/// What the request needs, read from the request itself (never from a file extension alone).
struct PlaybackRequestTraits: Equatable {
    var url: URL?
    /// A separate audio URL (video and audio loaded from two sources). AetherEngine has no equivalent yet.
    var hasSeparateAudio = false
    /// External subtitle files that come with the request.
    var subtitleFormats: Set<SubtitleFormat> = []
    var isLive = false
    /// Something only mpv can do: its filters, custom options, night-mode filter chain and similar.
    var needsMpvOnlyFeature = false
    /// A small embedded preview (home trailers), not a film: it keeps using the existing player.
    var isEmbeddedPreview = false

    enum SubtitleFormat: String {
        case text      // SRT, WebVTT, plain
        case styled    // ASS / SSA: the libass look is what mpv renders today
        case bitmap    // PGS (SUP), VobSub: pictures, which the shared subtitle overlay does not draw
        case unknown
    }

    init(url: URL?, hasSeparateAudio: Bool = false, subtitleFormats: Set<SubtitleFormat> = [], isLive: Bool = false, needsMpvOnlyFeature: Bool = false) {
        self.url = url
        self.hasSeparateAudio = hasSeparateAudio
        self.subtitleFormats = subtitleFormats
        self.isLive = isLive
        self.needsMpvOnlyFeature = needsMpvOnlyFeature
    }

    /// Reads the format of a subtitle file from its path (a hint: subtitle URLs carry no container to probe before loading).
    static func subtitleFormat(forURL string: String) -> SubtitleFormat {
        let path = (URL(string: string)?.path ?? string).lowercased()
        switch (path as NSString).pathExtension {
        case "srt", "vtt", "webvtt", "txt", "ttml", "dfxp", "sbv", "smi": return .text
        case "ass", "ssa": return .styled
        case "sup", "sub", "idx": return .bitmap
        default: return .unknown
        }
    }

    static func make(url: String, audioURL: String?, subtitleURLs: [String], isLive: Bool, needsMpvOnlyFeature: Bool) -> PlaybackRequestTraits {
        PlaybackRequestTraits(
            url: URL(string: url),
            hasSeparateAudio: !(audioURL ?? "").isEmpty,
            subtitleFormats: Set(subtitleURLs.map(subtitleFormat(forURL:))),
            isLive: isLive,
            needsMpvOnlyFeature: needsMpvOnlyFeature
        )
    }
}

/// Why a backend was chosen. Shown in the player's information panel and in diagnostics.
enum PlaybackSelectionReason: String, Equatable {
    case userChoseMpv = "Playback Engine is set to libmpv"
    case userChoseAether = "Playback Engine is set to AetherEngine"
    case automaticDefault = "Automatic: AetherEngine handles this request"
    case aetherUnavailable = "AetherEngine is not available on this device (needs iOS 18 or later)"
    case separateAudio = "Separate audio and video sources need libmpv"
    case bitmapSubtitles = "Picture subtitles (PGS / VobSub) need libmpv"
    case styledSubtitles = "Styled subtitles (ASS / SSA) are rendered by libmpv"
    case mpvOnlyFeature = "A libmpv-only feature is in use"
    case embeddedPreview = "Previews use libmpv"
    case unsupportedScheme = "The source address type is only handled by libmpv"
    case previousAetherFailure = "AetherEngine already failed on this source"
    case aetherFailureFallback = "AetherEngine failed; libmpv took over"
}

struct PlaybackBackendDecision: Equatable {
    let backend: PlaybackBackendKind
    let reason: PlaybackSelectionReason
}

enum PlaybackBackendPolicy {
    /// Schemes AetherEngine opens: local files and HTTP(S). Anything else (rtmp, rtsp, udp, custom) stays on libmpv.
    static let aetherSchemes: Set<String> = ["http", "https", "file"]

    /// Picks the backend for a new playback attempt.
    ///
    /// - Parameters:
    ///   - aetherAvailable: BannerPlaybackKit loaded (iOS 18+ and embedded).
    ///   - aetherFailedBefore: this source already failed on AetherEngine in this app session.
    static func decide(
        choice: PlaybackEngineChoice,
        traits: PlaybackRequestTraits,
        aetherAvailable: Bool,
        aetherFailedBefore: Bool = false
    ) -> PlaybackBackendDecision {
        if choice == .mpv { return .init(backend: .mpv, reason: .userChoseMpv) }
        if !aetherAvailable { return .init(backend: .mpv, reason: .aetherUnavailable) }

        // Capability gaps apply to both "automatic" and "AetherEngine": a feature AetherEngine does not have cannot be
        // honoured by choosing it, so those requests go to libmpv with the reason shown.
        if traits.isEmbeddedPreview { return .init(backend: .mpv, reason: .embeddedPreview) }
        if traits.hasSeparateAudio { return .init(backend: .mpv, reason: .separateAudio) }
        if traits.needsMpvOnlyFeature { return .init(backend: .mpv, reason: .mpvOnlyFeature) }
        if traits.subtitleFormats.contains(.bitmap) { return .init(backend: .mpv, reason: .bitmapSubtitles) }
        if let scheme = traits.url?.scheme?.lowercased(), !aetherSchemes.contains(scheme) {
            return .init(backend: .mpv, reason: .unsupportedScheme)
        }
        if traits.url == nil { return .init(backend: .mpv, reason: .unsupportedScheme) }

        if choice == .automatic {
            // Automatic keeps libmpv for looks AetherEngine does not reproduce yet and for sources it already failed on.
            if traits.subtitleFormats.contains(.styled) { return .init(backend: .mpv, reason: .styledSubtitles) }
            if aetherFailedBefore { return .init(backend: .mpv, reason: .previousAetherFailure) }
            return .init(backend: .aether, reason: .automaticDefault)
        }
        // Explicit AetherEngine: tried even where a previous attempt failed, because the user asked for it.
        return .init(backend: .aether, reason: .userChoseAether)
    }
}

// MARK: - Failures

/// What to do about an AetherEngine failure.
enum PlaybackFailureAction: Equatable {
    /// Not a failure (a superseded load).
    case ignore
    /// The engine or its format handling could not play this: libmpv may.
    case fallBackToMpv
    /// The source, the account or the device is the problem: another player would meet the same wall.
    case report
}

/// Classifies `PlaybackErrorInfo.kind` (a string-backed struct in AetherEngine, so the raw token is what crosses the module
/// boundary). Never classify on the message text.
enum AetherFailureClassifier {
    /// Kinds that describe the source, the origin, the account or the device. A second player meets the same refusal,
    /// the same meter, the same full disk or the same dropped connection, so a handoff would only repeat it.
    static let reportKinds: Set<String> = [
        "sourceRateLimited", "sourceRefused", "sourceCertificateRejected", "storageExhausted", "sourceFabricatesRanges",
        "liveSourceUnavailable", "vodSourceFailed", "audioSessionFailed",
    ]

    /// Kinds that describe what the engine could not do with a source that may be perfectly playable elsewhere.
    static let fallbackKinds: Set<String> = [
        "sourceOpenFailed", "customSourceProbeFailed", "hlsFormatUnsupported", "hlsIngestFailed", "hlsPlaylistOnRawLivePath",
        "dolbyVisionRequiresHardware", "demuxedAudioLiveUnsupported", "nativeItemFailed", "noPlayableTrackWithinBudget",
        "masterPlaylistRejected", "softwarePipelineFailed", "reloadFailed", "liveReloadNeverReady", "audioTrackSwitchFailed",
        "audioBridgeProducedNoOutput",
    ]

    /// - Parameters:
    ///   - kind: the raw `PlaybackErrorKind` token, nil when the failure carried none.
    ///   - isCancellation: the failure is a `CancellationError` out of `load()` (a newer load replaced this one).
    static func classify(kind: String?, isCancellation: Bool = false) -> PlaybackFailureAction {
        if isCancellation { return .ignore }
        guard let kind else { return .fallBackToMpv }
        if reportKinds.contains(kind) { return .report }
        if fallbackKinds.contains(kind) { return .fallBackToMpv }
        // A kind added in a later release: an engine failure we have no proof is the source's. One fallback, bounded below.
        return .fallBackToMpv
    }
}

struct PlaybackFallbackDecision: Equatable {
    enum Outcome: Equatable {
        case fallBack
        case fail(Reason)
    }
    enum Reason: Equatable {
        case notAFailure
        case wrongBackend
        case sourceProblem
        case choiceForbidsFallback
        case alreadyFellBack
        case staleSession
        case mpvUnavailable
    }
    let outcome: Outcome
}

enum PlaybackFallbackPolicy {
    /// Decides what happens after a backend fails terminally.
    ///
    /// Rules: only AetherEngine hands off to libmpv; at most once per attempt; never for a superseded session; never for a
    /// source problem; and the explicit AetherEngine setting reports the failure instead of switching on its own unless the
    /// user's emergency fallback preference is on.
    static func decide(
        choice: PlaybackEngineChoice,
        failedBackend: PlaybackBackendKind,
        action: PlaybackFailureAction,
        attempt: PlaybackAttempt,
        sessionIsCurrent: Bool,
        emergencyFallbackEnabled: Bool = false
    ) -> PlaybackFallbackDecision {
        if !sessionIsCurrent { return .init(outcome: .fail(.staleSession)) }
        if action == .ignore { return .init(outcome: .fail(.notAFailure)) }
        if failedBackend != .aether { return .init(outcome: .fail(.wrongBackend)) }
        if action == .report { return .init(outcome: .fail(.sourceProblem)) }
        if attempt.fallbackUsed { return .init(outcome: .fail(.alreadyFellBack)) }
        if choice == .aether && !emergencyFallbackEnabled { return .init(outcome: .fail(.choiceForbidsFallback)) }
        if choice == .mpv { return .init(outcome: .fail(.wrongBackend)) }
        return .init(outcome: .fallBack)
    }
}

// MARK: - Sessions and attempts

/// One playback attempt's identity. Every asynchronous completion must check it is still current before touching state.
struct PlaybackSessionToken: Equatable, Hashable {
    let generation: Int
}

/// Hands out session tokens. Starting a new attempt (another episode, another source, closing the player) invalidates every
/// older token, so a late callback cannot restart playback after the user has moved on.
final class PlaybackSessionLedger {
    private(set) var current = PlaybackSessionToken(generation: 0)

    /// Starts a new session; all earlier tokens become stale.
    @discardableResult
    func begin() -> PlaybackSessionToken {
        current = PlaybackSessionToken(generation: current.generation + 1)
        return current
    }

    /// Ends the current session (the player was closed) without starting another.
    func invalidate() { current = PlaybackSessionToken(generation: current.generation + 1) }

    func isCurrent(_ token: PlaybackSessionToken) -> Bool { token == current }
}

/// The bookkeeping of one attempt: which backend runs, whether the one allowed fallback was used, and which failures were
/// already counted (AetherEngine reports a failure both by throwing from `load()` and through its published state).
struct PlaybackAttempt: Equatable {
    let token: PlaybackSessionToken
    private(set) var backend: PlaybackBackendKind
    private(set) var fallbackUsed = false
    private var countedFailures: Set<String> = []

    init(token: PlaybackSessionToken, backend: PlaybackBackendKind) {
        self.token = token
        self.backend = backend
    }

    /// Counts a failure once. Returns false for a failure already counted (the same one reported a second way).
    mutating func recordFailure(id: String) -> Bool {
        countedFailures.insert(id).inserted
    }

    mutating func markFellBack() {
        fallbackUsed = true
        backend = .mpv
        countedFailures.removeAll()
    }
}

/// What to carry from the failing backend to the replacement.
struct PlaybackHandoff: Equatable {
    /// Where to resume, in seconds, or nil to start from the beginning (or the saved resume point).
    let resumeSeconds: Double?
    /// Whether the viewer wanted playback running (false if they had paused).
    let wantsPlaying: Bool

    /// Builds a handoff from the last reported position. A position is trusted only when it is a real number inside the
    /// media; a position within the first second is treated as "the start" and an unseekable source resumes from the start.
    static func make(lastPositionSeconds: Double?, durationSeconds: Double?, wantsPlaying: Bool, sourceIsSeekable: Bool) -> PlaybackHandoff {
        guard sourceIsSeekable, let position = lastPositionSeconds, position.isFinite, position > 1 else {
            return PlaybackHandoff(resumeSeconds: nil, wantsPlaying: wantsPlaying)
        }
        if let duration = durationSeconds, duration.isFinite, duration > 0, position >= duration - 1 {
            return PlaybackHandoff(resumeSeconds: nil, wantsPlaying: wantsPlaying)
        }
        return PlaybackHandoff(resumeSeconds: position, wantsPlaying: wantsPlaying)
    }
}

/// Sources that failed on AetherEngine during this app session, so the next attempt (a retry, the next episode of the same
/// provider URL) goes straight to libmpv under Automatic. Keys drop the query and credentials, which change per signed URL.
final class AetherFailureMemory {
    private var keys: Set<String> = []
    private let limit: Int

    init(limit: Int = 200) { self.limit = limit }

    static func key(for url: URL?) -> String? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return parts.string
    }

    func remember(_ url: URL?) {
        guard let key = Self.key(for: url) else { return }
        if keys.count >= limit { keys.removeAll() }
        keys.insert(key)
    }

    func hasFailed(_ url: URL?) -> Bool {
        Self.key(for: url).map(keys.contains) ?? false
    }
}
