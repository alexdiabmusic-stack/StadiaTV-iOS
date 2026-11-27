import BannerPlaybackContract
import ComposeApp
import Foundation
import UIKit

// The hybrid player: AetherEngine (native, energy-efficient) with libmpv as the compatibility fallback.
//
// What the Kotlin player sees is still one `NuvioPlayerBridge`. Underneath, `HybridPlayerBridgeImpl`
//  - passes every call straight to the existing mpv bridge when the Playback Engine setting is libmpv or AetherEngine cannot
//    be used (iOS below 18, framework missing): that path is exactly the old behaviour, with no wrapper view;
//  - otherwise picks a backend per request (PlaybackBackendPolicy), hosts its view, replays the settings the app applied
//    before the choice was made, and runs the bounded fallback (PlaybackFallbackPolicy) when AetherEngine fails.
// Only one backend decodes at a time: the failing one is fully destroyed before its replacement starts.

/// Holds whichever backend's view is active, so the one view controller Compose keeps can change engines underneath.
final class HybridHostViewController: UIViewController {
    private(set) var child: UIViewController?
    var onLeftParent: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    func attach(_ newChild: UIViewController) {
        detach()
        addChild(newChild)
        newChild.view.autoresizingMask = []
        newChild.view.frame = view.bounds
        view.addSubview(newChild.view)
        newChild.didMove(toParent: self)
        child = newChild
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    func detach() {
        guard let child else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        self.child = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let childView = child?.viewIfLoaded, childView.frame != view.bounds { childView.frame = view.bounds }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { onLeftParent?() }
    }

    override var childForStatusBarHidden: UIViewController? { child }
    override var childForStatusBarStyle: UIViewController? { child }
    override var childForHomeIndicatorAutoHidden: UIViewController? { child }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { child }
}

/// A request as the Kotlin side sends it, kept so a handoff can load the same source again.
private struct HybridRequest {
    let url: String
    let audioUrl: String?
    let headersJson: String?
    let subtitlesJson: String?
}

@MainActor
final class HybridPlayerBridgeImpl: NSObject, NuvioPlayerBridge {
    private static let failureMemory = AetherFailureMemory()

    private let choice: PlaybackEngineChoice
    private let factory: BannerPlaybackBackendFactory?
    private let passthrough: Bool

    private var mpv: MPVPlayerBridgeImpl?
    private var aether: AetherBridgeAdapter?
    private var activeKind: PlaybackBackendKind?
    private let host = HybridHostViewController()
    private let ledger = PlaybackSessionLedger()
    private var attempt: PlaybackAttempt?
    private var request: HybridRequest?

    // Intent and settings the app applied before / between backends.
    private var wantsPlaying = true
    private var embeddedPreview = false
    private var replayKeys: [String] = []
    private var replay: [String: (NuvioPlayerBridge) -> Void] = [:]

    // Diagnostics.
    private var selectionReason: PlaybackSelectionReason?
    private var fallbackReason: String?
    private var loadBeganAt: CFAbsoluteTime = 0
    private var cachedInfo: (at: CFAbsoluteTime, json: String)?

    override init() {
        let stored = PlaybackEngineChoice.stored()
        let factory = (stored == .mpv) ? nil : BannerPlaybackKitLoader.makeFactory()
        self.choice = stored
        self.factory = factory
        self.passthrough = (stored == .mpv) || factory == nil
        super.init()
        if passthrough {
            let bridge = MPVPlayerBridgeImpl()
            mpv = bridge
            activeKind = .mpv
            selectionReason = stored == .mpv ? .userChoseMpv : .aetherUnavailable
        } else {
            host.onLeftParent = { [weak self] in self?.mpv?.hostDidLeaveParent() }
        }
    }

    /// The bridge calls reach. Nil in hybrid mode until a backend has been chosen.
    private var target: NuvioPlayerBridge? {
        switch activeKind {
        case .mpv: return mpv
        case .aether: return aether
        case nil: return nil
        }
    }

    /// Applies a setting to the active backend now and remembers it for the next one.
    private func record(_ key: String, _ apply: @escaping (NuvioPlayerBridge) -> Void) {
        if !passthrough {
            if replay[key] == nil { replayKeys.append(key) }
            replay[key] = apply
        }
        if let target { apply(target) }
    }

    private func replaySettings(onto bridge: NuvioPlayerBridge) {
        for key in replayKeys { replay[key]?(bridge) }
    }

    // MARK: view

    func createPlayerViewController() -> UIViewController {
        if passthrough, let mpv { return mpv.createPlayerViewController() }
        return host
    }

    // MARK: loading and backend choice

    func loadFile(url: String) { loadFileWithAudio(videoUrl: url, audioUrl: nil, headersJson: nil, subtitlesJson: nil) }

    func loadFileWithAudio(videoUrl: String, audioUrl: String?, headersJson: String?, subtitlesJson: String?) {
        if passthrough { mpv?.loadFileWithAudio(videoUrl: videoUrl, audioUrl: audioUrl, headersJson: headersJson, subtitlesJson: subtitlesJson); return }
        let req = HybridRequest(url: videoUrl, audioUrl: audioUrl, headersJson: headersJson, subtitlesJson: subtitlesJson)
        request = req
        beginAttempt(req)
    }

    private func traits(for req: HybridRequest) -> PlaybackRequestTraits {
        var traits = PlaybackRequestTraits.make(
            url: req.url, audioURL: req.audioUrl,
            subtitleURLs: PlaybackRequestJSON.subtitles(req.subtitlesJson).map(\.url),
            isLive: false, needsMpvOnlyFeature: false
        )
        traits.isEmbeddedPreview = embeddedPreview
        return traits
    }

    private func beginAttempt(_ req: HybridRequest) {
        let token = ledger.begin()          // every earlier session's callbacks are stale from here
        tearDownActive()
        loadBeganAt = CFAbsoluteTimeGetCurrent()
        fallbackReason = nil
        let t = traits(for: req)
        let decision = PlaybackBackendPolicy.decide(
            choice: choice, traits: t, aetherAvailable: factory != nil,
            aetherFailedBefore: Self.failureMemory.hasFailed(t.url)
        )
        selectionReason = decision.reason
        attempt = PlaybackAttempt(token: token, backend: decision.backend)
        switch decision.backend {
        case .aether: if !startAether(req, resume: nil) { startMpv(req, resume: nil) }
        case .mpv: startMpv(req, resume: nil)
        }
    }

    @discardableResult
    private func startAether(_ req: HybridRequest, resume: PlaybackHandoff?) -> Bool {
        guard let factory, let backend = factory.makeBackend() else { selectionReason = .aetherUnavailable; return false }
        guard let sessionToken = attempt?.token else { return false }
        let adapter = AetherBridgeAdapter(backend: backend)
        backend.onEvent = { [weak self] event in self?.handle(event, session: sessionToken) }
        aether = adapter
        activeKind = .aether
        host.attach(adapter.createPlayerViewController())
        replaySettings(onto: adapter)
        var load = BannerLoadRequest(
            url: req.url, startSeconds: resume?.resumeSeconds,
            headers: PlaybackRequestJSON.headers(req.headersJson),
            subtitles: PlaybackRequestJSON.subtitles(req.subtitlesJson),
            autoplay: resume?.wantsPlaying ?? true,
            maximumSubtitleDelaySeconds: 60, maximumSubtitleAdvanceSeconds: 60
        )
        load.autoplay = resume?.wantsPlaying ?? wantsPlaying
        adapter.load(load)
        return true
    }

    private func startMpv(_ req: HybridRequest, resume: PlaybackHandoff?, reselectSubtitleLanguage: String? = nil) {
        let bridge = MPVPlayerBridgeImpl()
        mpv = bridge
        activeKind = .mpv
        if attempt?.backend != .mpv { attempt?.markFellBack() }
        host.attach(bridge.createPlayerViewController())
        replaySettings(onto: bridge)
        bridge.loadFileWithAudio(videoUrl: req.url, audioUrl: req.audioUrl, headersJson: req.headersJson, subtitlesJson: req.subtitlesJson)
        let wants = resume?.wantsPlaying ?? wantsPlaying
        if wants { bridge.play() } else { bridge.pause() }
        if let seconds = resume?.resumeSeconds, let token = attempt?.token {
            resumeMpv(bridge, atMs: Int64(seconds * 1000), subtitleLanguage: reselectSubtitleLanguage, session: token)
        } else if let language = reselectSubtitleLanguage, let token = attempt?.token {
            resumeMpv(bridge, atMs: nil, subtitleLanguage: language, session: token)
        }
    }

    /// libmpv has no start-position argument on this bridge, so the resume seek waits until the file is open. Bounded, and
    /// dropped if the viewer has moved on.
    private func resumeMpv(_ bridge: MPVPlayerBridgeImpl, atMs: Int64?, subtitleLanguage: String?, session: PlaybackSessionToken, tries: Int = 0) {
        guard ledger.isCurrent(session), mpv === bridge else { return }
        if bridge.getDurationMs() > 0 && !bridge.getIsLoading() {
            if let atMs { bridge.seekTo(positionMs: atMs) }
            if let language = subtitleLanguage?.lowercased(), !language.isEmpty {
                let count = Int(bridge.getSubtitleTrackCount())
                for index in 0..<count where bridge.getSubtitleTrackLang(at: Int32(index)).lowercased().hasPrefix(language.prefix(2)) {
                    if let id = Int32(bridge.getSubtitleTrackId(at: Int32(index))) { bridge.selectSubtitleTrack(trackId: id) }
                    break
                }
            }
            return
        }
        guard tries < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.resumeMpv(bridge, atMs: atMs, subtitleLanguage: subtitleLanguage, session: session, tries: tries + 1)
        }
    }

    // MARK: events and fallback

    private func handle(_ event: BannerBackendEvent, session: PlaybackSessionToken) {
        guard ledger.isCurrent(session), activeKind == .aether else { return }
        switch event {
        case .failed(let failure):
            guard attempt?.recordFailure(id: failure.id) == true, let currentAttempt = attempt else { return }
            let action = AetherFailureClassifier.classify(kind: failure.kind)
            let decision = PlaybackFallbackPolicy.decide(
                choice: choice, failedBackend: .aether, action: action, attempt: currentAttempt,
                sessionIsCurrent: ledger.isCurrent(session),
                emergencyFallbackEnabled: PlaybackEngineChoice.emergencyFallbackEnabled()
            )
            Self.failureMemory.remember(URL(string: request?.url ?? ""))
            if decision.outcome == .fallBack {
                handOffToMpv(why: "AetherEngine failed (\(failure.kind ?? "unknown")); libmpv took over", subtitleLanguage: nil)
            } else {
                fallbackReason = "AetherEngine failed (\(failure.kind ?? "unknown")): \(Self.reasonText(decision.outcome))"
            }
        case .needsOtherEngine(let reason, let language):
            handOffToMpv(why: reason == "bitmapSubtitle" ? "Picture subtitles need libmpv" : "A feature needs libmpv", subtitleLanguage: language)
        case .firstFrame, .ended, .tracksChanged:
            break
        }
    }

    private static func reasonText(_ outcome: PlaybackFallbackDecision.Outcome) -> String {
        guard case .fail(let reason) = outcome else { return "" }
        switch reason {
        case .sourceProblem: return "a source or account problem, so libmpv was not tried"
        case .choiceForbidsFallback: return "Playback Engine is set to AetherEngine"
        case .alreadyFellBack: return "already switched once"
        default: return "no fallback"
        }
    }

    /// Captures where the viewer was, destroys the failing engine completely, and continues in libmpv.
    private func handOffToMpv(why: String, subtitleLanguage: String?) {
        guard let req = request, let adapter = aether else { return }
        let snapshot = adapter.backend.snapshot
        let handoff = PlaybackHandoff.make(
            lastPositionSeconds: Double(snapshot.positionMs) / 1000,
            durationSeconds: snapshot.durationMs > 0 ? Double(snapshot.durationMs) / 1000 : nil,
            wantsPlaying: wantsPlaying, sourceIsSeekable: snapshot.durationMs > 0
        )
        tearDownActive()                       // one decoder at a time
        fallbackReason = why
        selectionReason = .aetherFailureFallback
        attempt?.markFellBack()
        startMpv(req, resume: handoff, reselectSubtitleLanguage: subtitleLanguage)
    }

    private func tearDownActive() {
        if let aether { aether.destroy() }
        aether = nil
        if let mpv { mpv.destroy() }
        mpv = nil
        host.detach()
        activeKind = nil
        cachedInfo = nil
    }

    func destroy() {
        ledger.invalidate()                    // a late callback must not restart anything
        if passthrough { mpv?.destroy(); return }
        tearDownActive()
        replay.removeAll(); replayKeys.removeAll()
    }

    // MARK: transport (intent is remembered across backends)

    func play() { wantsPlaying = true; target?.play() }
    func pause() { wantsPlaying = false; target?.pause() }
    func seekTo(positionMs: Int64) { target?.seekTo(positionMs: positionMs) }
    func seekBy(offsetMs: Int64) { target?.seekBy(offsetMs: offsetMs) }
    func retry() { target?.retry() }

    func setPlaybackSpeed(speed: Float) { record("speed") { $0.setPlaybackSpeed(speed: speed) } }
    func setVolume(volume: Float) { record("volume") { $0.setVolume(volume: volume) } }
    func setMuted(muted: Bool) { record("muted") { $0.setMuted(muted: muted) } }
    func getVolume() -> Float { target?.getVolume() ?? 1 }
    func setResizeMode(mode: Int32) { record("resize") { $0.setResizeMode(mode: mode) } }
    func setVideoZoom(scale: Double) { record("zoom") { $0.setVideoZoom(scale: scale) } }
    func syncVideoSurfaceLayout(width: Double, height: Double) { record("layout") { $0.syncVideoSurfaceLayout(width: width, height: height) } }
    func setEmbeddedPreviewMode(enabled: Bool) {
        embeddedPreview = enabled
        record("preview") { $0.setEmbeddedPreviewMode(enabled: enabled) }
    }

    func setSystemControlHandler(handler: PlayerSystemControlHandler?) { record("systemControl") { $0.setSystemControlHandler(handler: handler) } }
    func getKeepsPlaybackInBackground() -> Bool { target?.getKeepsPlaybackInBackground() ?? false }
    func setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: Bool) {
        record("singlePip") { $0.setExperimentalSinglePrimaryPictureInPictureEnabled(enabled: enabled) }
    }
    func isPictureInPictureSupported() -> Bool { target?.isPictureInPictureSupported() ?? false }
    func startPictureInPicture() { target?.startPictureInPicture() }
    func updateNowPlayingMetadata(title: String, subtitle: String?, artworkUrl: String?) {
        record("nowPlaying") { $0.updateNowPlayingMetadata(title: title, subtitle: subtitle, artworkUrl: artworkUrl) }
    }
    func clearNowPlayingInfo() { replay["nowPlaying"] = nil; replayKeys.removeAll { $0 == "nowPlaying" }; target?.clearNowPlayingInfo() }
    func setKeyboardShortcutsEnabled(enabled: Bool) { record("kbEnabled") { $0.setKeyboardShortcutsEnabled(enabled: enabled) } }
    func setKeyboardShortcutHandler(handler: ((String) -> Void)?) { record("kbHandler") { $0.setKeyboardShortcutHandler(handler: handler) } }

    func configureVideoOutput(hardwareDecoder: String, targetColorspaceHint: Bool, toneMapping: String, hdrComputePeak: Bool, targetPrimaries: String, targetTransfer: String, extendedDynamicRange: Bool, deband: Bool, interpolation: Bool, brightness: Int32, contrast: Int32, saturation: Int32, gamma: Int32) {
        record("videoOutput") {
            $0.configureVideoOutput(hardwareDecoder: hardwareDecoder, targetColorspaceHint: targetColorspaceHint, toneMapping: toneMapping, hdrComputePeak: hdrComputePeak, targetPrimaries: targetPrimaries, targetTransfer: targetTransfer, extendedDynamicRange: extendedDynamicRange, deband: deband, interpolation: interpolation, brightness: brightness, contrast: contrast, saturation: saturation, gamma: gamma)
        }
    }
    func configureAudioOutput(audioOutput: String) { record("audioOutput") { $0.configureAudioOutput(audioOutput: audioOutput) } }
    func setNightMode(enabled: Bool, filter: String, label: String) { record("nightMode") { $0.setNightMode(enabled: enabled, filter: filter, label: label) } }
    func isNightModeSupported() -> Bool { target?.isNightModeSupported() ?? MPVPlayerViewController.nightModeSupported }
    func applyAudioLanguagePreferences(languages: [String]) { record("audioLangs") { $0.applyAudioLanguagePreferences(languages: languages) } }
    func setSubtitleDelayMs(delayMs: Int32) { record("subDelay") { $0.setSubtitleDelayMs(delayMs: delayMs) } }
    func setSubtitleTextHandler(handler: SubtitleTextHandler?) { record("subText") { $0.setSubtitleTextHandler(handler: handler) } }
    func applySubtitleStyle(textColor: String, backgroundColor: String, outlineColor: String, outlineSize: Float, bold: Bool, fontSize: Float, subPos: Int32, stripSdh: Bool, styledOverlay: Bool, outlineBlur: Int32) {
        record("subStyle") { $0.applySubtitleStyle(textColor: textColor, backgroundColor: backgroundColor, outlineColor: outlineColor, outlineSize: outlineSize, bold: bold, fontSize: fontSize, subPos: subPos, stripSdh: stripSdh, styledOverlay: styledOverlay, outlineBlur: outlineBlur) }
    }

    // MARK: tracks and subtitles

    func getAudioTrackCount() -> Int32 { target?.getAudioTrackCount() ?? 0 }
    func getAudioTrackIndex(at: Int32) -> Int32 { target?.getAudioTrackIndex(at: at) ?? 0 }
    func getAudioTrackId(at: Int32) -> String { target?.getAudioTrackId(at: at) ?? "0" }
    func getAudioTrackLabel(at: Int32) -> String { target?.getAudioTrackLabel(at: at) ?? "" }
    func getAudioTrackLang(at: Int32) -> String { target?.getAudioTrackLang(at: at) ?? "" }
    func isAudioTrackSelected(at: Int32) -> Bool { target?.isAudioTrackSelected(at: at) ?? false }
    func getSubtitleTrackCount() -> Int32 { target?.getSubtitleTrackCount() ?? 0 }
    func getSubtitleTrackIndex(at: Int32) -> Int32 { target?.getSubtitleTrackIndex(at: at) ?? 0 }
    func getSubtitleTrackId(at: Int32) -> String { target?.getSubtitleTrackId(at: at) ?? "0" }
    func getSubtitleTrackLabel(at: Int32) -> String { target?.getSubtitleTrackLabel(at: at) ?? "" }
    func getSubtitleTrackLang(at: Int32) -> String { target?.getSubtitleTrackLang(at: at) ?? "" }
    func isSubtitleTrackSelected(at: Int32) -> Bool { target?.isSubtitleTrackSelected(at: at) ?? false }
    func selectAudioTrack(trackId: Int32) { target?.selectAudioTrack(trackId: trackId) }
    func selectSubtitleTrack(trackId: Int32) { target?.selectSubtitleTrack(trackId: trackId) }
    func setSubtitleUrl(url: String) { target?.setSubtitleUrl(url: url) }
    func replaceExternalSubtitle(replacedUrl: String, path: String) { target?.replaceExternalSubtitle(replacedUrl: replacedUrl, path: path) }
    func clearExternalSubtitle() { target?.clearExternalSubtitle() }
    func clearExternalSubtitleAndSelect(trackId: Int32) { target?.clearExternalSubtitleAndSelect(trackId: trackId) }

    // MARK: state

    func getIsLoading() -> Bool { target?.getIsLoading() ?? true }
    func getIsPlaying() -> Bool { target?.getIsPlaying() ?? false }
    func getIsEnded() -> Bool { target?.getIsEnded() ?? false }
    func getDurationMs() -> Int64 { target?.getDurationMs() ?? 0 }
    func getPositionMs() -> Int64 { target?.getPositionMs() ?? 0 }
    func networkSpeedBytesPerSecond() -> Int64 { target?.networkSpeedBytesPerSecond() ?? -1 }
    func getBufferedMs() -> Int64 { target?.getBufferedMs() ?? 0 }
    func getPlaybackSpeed() -> Float { target?.getPlaybackSpeed() ?? 1 }
    func getVideoWidth() -> Int32 { target?.getVideoWidth() ?? 0 }
    func getVideoHeight() -> Int32 { target?.getVideoHeight() ?? 0 }
    func getErrorMessage() -> String { target?.getErrorMessage() ?? "" }
    func getProperty(name: String) -> String { target?.getProperty(name: name) ?? "" }

    /// The engine's media information plus what the information panel shows about the choice: which engine was asked for,
    /// which is running and why, the rendering route, any fallback, and the device's thermal and power state. Rebuilt at most
    /// once a second, because the app asks on every poll.
    func getMediaInfoJson() -> String {
        let now = CFAbsoluteTimeGetCurrent()
        if let cachedInfo, now - cachedInfo.at < 1 { return cachedInfo.json }
        var info: [String: Any] = [:]
        if let data = target?.getMediaInfoJson().data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { info = parsed }
        if info["engine"] == nil, let kind = activeKind { info["engine"] = kind.displayName }
        if activeKind == .mpv, info["rendering"] == nil { info["rendering"] = "libmpv (Vulkan / MoltenVK / Metal)" }
        info["requestedEngine"] = Self.label(choice)
        if let selectionReason { info["selectionReason"] = selectionReason.rawValue }
        if let fallbackReason { info["fallbackReason"] = fallbackReason }
        info["thermalState"] = Self.thermalLabel(ProcessInfo.processInfo.thermalState)
        info["lowPowerMode"] = ProcessInfo.processInfo.isLowPowerModeEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 { info["batteryPercent"] = Int((level * 100).rounded()) }
        let json = (try? JSONSerialization.data(withJSONObject: info, options: [])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        cachedInfo = (now, json)
        return json
    }

    private static func label(_ choice: PlaybackEngineChoice) -> String {
        switch choice { case .automatic: return "Automatic"; case .aether: return "AetherEngine"; case .mpv: return "libmpv" }
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state { case .nominal: return "Nominal"; case .fair: return "Fair"; case .serious: return "Serious"; case .critical: return "Critical"; @unknown default: return "Unknown" }
    }
}

// MARK: - Creator

final class HybridPlayerBridgeCreator: NSObject, NuvioPlayerBridgeCreator {
    func createBridge() -> any NuvioPlayerBridge {
        // Kotlin creates and drives the bridge on the main thread.
        MainActor.assumeIsolated { HybridPlayerBridgeImpl() }
    }

    func closeParkedPictureInPicture() {
        DispatchQueue.main.async {
            guard PlayerPictureInPictureParking.shared.hasParkedPlayer else { return }
            PlayerPictureInPictureParking.shared.closeParked()
        }
    }
}
