import AVFoundation
import AVKit
import AetherEngine
import BannerPlaybackContract
import Combine
import MediaPlayer
import UIKit

/// Hosts the engine's `AetherPlayerView` inside the app's existing player surface.
final class AetherContainerViewController: UIViewController {
    let playerView = AetherPlayerView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerView.frame = view.bounds
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(playerView)
    }

    override var prefersStatusBarHidden: Bool { true }
}

/// AetherEngine behind the app's playback contract: one playback surface, one session at a time.
///
/// - Time crosses the boundary in milliseconds; the engine speaks seconds.
/// - State is read from cached values updated by Combine sinks, so the app's polling stays cheap.
/// - Loading is deferred by one main-queue turn so a play/pause that follows `load` immediately (as the app does) decides
///   `autoplay`, and the engine never starts something the viewer already paused.
@MainActor
final class AetherBackend: NSObject, BannerPlaybackBackend, AVPictureInPictureControllerDelegate {
    private let engine: AetherEngine
    private let container = AetherContainerViewController()
    private var cancellables = Set<AnyCancellable>()
    private var clockCancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var destroyed = false

    // Cached engine state.
    private var state: PlaybackState = .idle
    private var phase: PlaybackPhase = .idle
    private var duration: Double = 0
    private var currentTime: Double = 0
    private var sourceTime: Double = 0
    private var bufferedPosition: Double = 0
    private var hasFirstFrame = false
    private var rate: Float = 1
    private var route: VideoRoute = .none
    private var audio: [TrackInfo] = []
    private var subtitles: [TrackInfo] = []
    private var activeAudioId: Int?
    private var activeSubtitleId: Int?
    private var cues: [SubtitleCue] = []
    private var errorInfo: PlaybackErrorInfo?
    private var softwarePiPSource: SoftwarePiPSource?
    private var pipController: AVPictureInPictureController?

    // Intent and request.
    private var wantsPlaying = true
    private var pendingRequest: BannerLoadRequest?
    private var subtitleDelayMs = 0
    private var lastSubtitleText = ""
    private var reportedFirstFrame = false
    private var reportedFailureId: String?
    private var nowPlayingTitle: String?

    // Diagnostics.
    private var loadStartedAt: CFAbsoluteTime = 0
    private var firstFrameAt: CFAbsoluteTime = 0
    private var rebufferCount = 0
    private var wasRebuffering = false

    var onEvent: ((BannerBackendEvent) -> Void)?
    var onSubtitleText: ((String) -> Void)?

    var viewController: UIViewController { container }
    var keepsPlaybackInBackground: Bool { true }

    init(engine: AetherEngine) {
        self.engine = engine
        super.init()
        container.loadViewIfNeeded()
        engine.bind(view: container.playerView)
        // The app owns the screen's transport UI. The engine owns the system Now Playing item and its remote commands, so
        // exactly one component registers them.
        engine.ownsVideoNowPlayingSession = true
        engine.ownsVideoNowPlayingCommands = true
        engine.ownsSoftwareNowPlaying = true
        observeEngine()
    }

    // MARK: observation

    private func observeEngine() {
        engine.$state.removeDuplicates().sink { [weak self] value in self?.stateChanged(value) }.store(in: &cancellables)
        engine.$playbackPhase.removeDuplicates().sink { [weak self] value in self?.phaseChanged(value) }.store(in: &cancellables)
        engine.$errorInfo.sink { [weak self] value in self?.errorInfo = value; self?.failureIfNeeded() }.store(in: &cancellables)
        engine.$duration.sink { [weak self] value in self?.duration = value.isFinite ? value : 0 }.store(in: &cancellables)
        engine.$hasFirstFrameReadyForDisplay.removeDuplicates().sink { [weak self] value in self?.firstFrameChanged(value) }.store(in: &cancellables)
        engine.$videoRoute.removeDuplicates().sink { [weak self] value in self?.route = value }.store(in: &cancellables)
        engine.$audioTracks.sink { [weak self] value in self?.audio = value; self?.onEvent?(.tracksChanged) }.store(in: &cancellables)
        engine.$subtitleTracks.sink { [weak self] value in self?.subtitles = value; self?.onEvent?(.tracksChanged) }.store(in: &cancellables)
        engine.$activeAudioTrackIndex.removeDuplicates().sink { [weak self] value in self?.activeAudioId = value; self?.onEvent?(.tracksChanged) }.store(in: &cancellables)
        engine.$activeSubtitleTrackIndex.removeDuplicates().sink { [weak self] value in self?.activeSubtitleId = value; self?.onEvent?(.tracksChanged) }.store(in: &cancellables)
        engine.$softwarePiPSource.sink { [weak self] value in self?.softwarePiPSourceChanged(value) }.store(in: &cancellables)
        engine.$subtitleCues.sink { [weak self] value in self?.cues = value; self?.refreshSubtitleText() }.store(in: &cancellables)

        // The engine's own clock updates often; only a cheap assignment happens here. The app reads values on its own tick.
        let clock = engine.clock
        clock.$currentTime.sink { [weak self] value in self?.currentTime = value }.store(in: &clockCancellables)
        clock.$bufferedPosition.sink { [weak self] value in self?.bufferedPosition = value }.store(in: &clockCancellables)
        clock.$sourceTime.sink { [weak self] value in
            self?.sourceTime = value
            self?.refreshSubtitleText()
        }.store(in: &clockCancellables)
    }

    private func stateChanged(_ value: PlaybackState) {
        state = value
        switch value {
        case .playing where !wantsPlaying: engine.pause()      // the viewer paused while the source was loading
        case .paused where wantsPlaying && hasFirstFrame && !isSeekingState: break // a pause the system made (call, route change) stays
        case .ended: onEvent?(.ended)
        case .error: failureIfNeeded()
        default: break
        }
    }

    private var isSeekingState: Bool { if case .seeking = state { return true }; return false }

    private func phaseChanged(_ value: PlaybackPhase) {
        phase = value
        let rebuffering = (value == .rebuffering)
        if rebuffering && !wasRebuffering { rebufferCount += 1 }
        wasRebuffering = rebuffering
    }

    private func firstFrameChanged(_ value: Bool) {
        hasFirstFrame = value
        guard value, !reportedFirstFrame else { return }
        reportedFirstFrame = true
        firstFrameAt = CFAbsoluteTimeGetCurrent()
        onEvent?(.firstFrame)
    }

    private func failureIfNeeded() {
        guard case .error(let message) = state else { return }
        let id = "load-\(generation)"
        guard reportedFailureId != id else { return }
        reportedFailureId = id
        onEvent?(.failed(BannerBackendFailure(kind: errorInfo?.kind.rawValue, message: Self.sanitized(message), id: id)))
    }

    // MARK: snapshot

    var snapshot: BannerPlaybackSnapshot {
        var s = BannerPlaybackSnapshot()
        let failed: Bool
        if case .error = state { failed = true } else { failed = false }
        let loading: Bool
        switch phase {
        case .loading, .rebuffering, .stalled: loading = true
        default: loading = !hasFirstFrame && !failed && state != .ended
        }
        s.isLoading = (destroyed || pendingRequest != nil) ? true : loading
        s.isPlaying = phase == .playing
        s.isEnded = state == .ended
        s.positionMs = Int64(max(0, currentTime) * 1000)
        s.durationMs = Int64(max(0, duration) * 1000)
        s.bufferedMs = Int64(max(0, bufferedPosition) * 1000)
        s.speed = rate
        s.videoWidth = Int(engine.sourceVideoWidth)
        s.videoHeight = Int(engine.sourceVideoHeight)
        if case .error(let message) = state { s.errorMessage = Self.sanitized(message) }
        return s
    }

    /// Failure text can quote the source address (which may hold a login). It never leaves this module with one in it.
    static func sanitized(_ message: String) -> String {
        message.replacingOccurrences(of: "https?://[^\\s\"')]+", with: "<address>", options: .regularExpression)
    }

    // MARK: loading

    func load(_ request: BannerLoadRequest) {
        guard !destroyed else { return }
        generation += 1
        loadTask?.cancel()
        reportedFirstFrame = false
        reportedFailureId = nil
        rebufferCount = 0
        firstFrameAt = 0
        loadStartedAt = CFAbsoluteTimeGetCurrent()
        wantsPlaying = request.autoplay
        pendingRequest = request
        let token = generation
        // One turn later, so the app's immediate play()/pause() settles the viewer's intent first.
        DispatchQueue.main.async { [weak self] in self?.startLoad(token: token) }
    }

    private func startLoad(token: Int) {
        guard !destroyed, token == generation, let request = pendingRequest, let url = URL(string: request.url) else {
            if !destroyed, token == generation, pendingRequest != nil {
                pendingRequest = nil
                onEvent?(.failed(BannerBackendFailure(kind: "sourceOpenFailed", message: "The address is not valid.", id: "load-\(token)")))
            }
            return
        }
        pendingRequest = nil
        var options = LoadOptions()
        options.httpHeaders = request.headers
        options.autoplay = wantsPlaying
        options.isLive = request.isLive
        options.preferredAudioLanguages = request.preferredAudioLanguages
        options.preferredSubtitleLanguages = request.preferredSubtitleLanguages
        options.externalSubtitles = request.subtitles.compactMap { source in
            guard let subtitleURL = URL(string: source.url) else { return nil }
            return ExternalSubtitleTrack(url: subtitleURL, name: source.name, language: source.language, httpHeaders: source.headers)
        }
        // Energy: the app shows no generated scrub previews, so the engine is not asked to build them.
        options.generatesBackgroundScrubPreviews = false
        engine.maximumSubtitleDelaySeconds = request.maximumSubtitleDelaySeconds
        engine.maximumSubtitleAdvanceSeconds = request.maximumSubtitleAdvanceSeconds

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.engine.load(url: url, startPosition: request.startSeconds, options: options)
            } catch is CancellationError {
                // A newer load replaced this one: not a failure.
            } catch {
                guard !Task.isCancelled, token == self.generation, !self.destroyed else { return }
                let id = "load-\(token)"
                guard self.reportedFailureId != id else { return }
                self.reportedFailureId = id
                let kind = self.engine.errorInfo?.kind.rawValue
                self.onEvent?(.failed(BannerBackendFailure(kind: kind, message: Self.sanitized("\(error)"), id: id)))
            }
        }
    }

    // MARK: transport

    func play() {
        wantsPlaying = true
        guard pendingRequest == nil, !destroyed else { return }
        switch state { case .paused, .seeking: engine.play(); default: break }
    }

    func pause() {
        wantsPlaying = false
        guard pendingRequest == nil, !destroyed else { return }
        switch state { case .playing, .seeking: engine.pause(); default: break }
    }

    func seek(toMs: Int64) {
        guard !destroyed else { return }
        let seconds = max(0, Double(toMs) / 1000)
        Task { [weak self] in await self?.engine.seek(to: seconds) }
    }

    func setRate(_ value: Float) { rate = value; engine.setRate(value) }

    var volume: Float {
        get { engine.volume }
        set { engine.volume = newValue }
    }

    private var muted = false
    private var volumeBeforeMute: Float = 1
    func setMuted(_ value: Bool) {
        guard value != muted else { return }
        muted = value
        if value { volumeBeforeMute = engine.volume; engine.volume = 0 } else { engine.volume = volumeBeforeMute }
    }

    func setResizeMode(_ mode: Int) {
        engine.videoGravity = mode == 0 ? .resizeAspect : .resizeAspectFill
    }

    // MARK: tracks

    func audioTracks() -> [BannerMediaTrack] {
        audio.map { BannerMediaTrack(id: $0.id, label: Self.label($0), language: $0.language ?? "", codec: $0.codec, isSelected: $0.id == activeAudioId) }
    }

    func subtitleTracks() -> [BannerMediaTrack] {
        subtitles.map {
            BannerMediaTrack(id: $0.id, label: Self.label($0), language: $0.language ?? "", codec: $0.codec,
                             isSelected: $0.id == activeSubtitleId, isBitmap: Self.isBitmapCodec($0.codec))
        }
    }

    func selectAudioTrack(id: Int) { engine.selectAudioTrack(index: id) }

    func selectSubtitleTrack(id: Int) {
        if id < 0 { engine.clearSubtitle(); lastSubtitleText = ""; onSubtitleText?(""); return }
        if let track = subtitles.first(where: { $0.id == id }), Self.isBitmapCodec(track.codec) {
            // The shared overlay draws text only: a picture subtitle needs the other engine.
            onEvent?(.needsOtherEngine(reason: "bitmapSubtitle", language: track.language ?? ""))
            return
        }
        engine.selectSubtitleTrack(index: id)
    }

    func setSubtitleDelayMs(_ ms: Int) { subtitleDelayMs = ms; refreshSubtitleText() }

    func addExternalSubtitle(_ source: BannerSubtitleSource) {
        guard !destroyed, let url = URL(string: source.url) ?? URL(string: source.url.hasPrefix("/") ? "file://" + source.url : source.url) else { return }
        let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: source.name, language: source.language, httpHeaders: source.headers))
        engine.selectSubtitleTrack(index: track.id)
    }

    static func isBitmapCodec(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c.contains("pgs") || c.contains("dvd_subtitle") || c.contains("dvb_subtitle") || c.contains("dvbsub") || c.contains("hdmv") || c.contains("xsub") || c.contains("vobsub")
    }

    private static func label(_ track: TrackInfo) -> String {
        if !track.name.isEmpty { return track.name }
        if let language = track.language, !language.isEmpty { return language }
        return track.codec
    }

    private func refreshSubtitleText() {
        let text: String
        if activeSubtitleId == nil || cues.isEmpty {
            text = ""
        } else {
            // Cues are placed on the source timeline (sourceTime), and the delay moves them without touching the video.
            let t = sourceTime - Double(subtitleDelayMs) / 1000
            text = cues.last(where: { $0.startTime <= t && t < $0.endTime })?.text ?? ""
        }
        guard text != lastSubtitleText else { return }
        lastSubtitleText = text
        onSubtitleText?(text)
    }

    // MARK: information

    func mediaInfo() -> [String: Any] {
        let hdr: String
        switch engine.videoFormat {
        case .dolbyVision: hdr = "dolby_vision"
        case .hdr10Plus: hdr = "hdr10_plus"
        case .hdr10: hdr = "hdr"
        case .hlg: hdr = "hlg"
        case .sdr: hdr = "sdr"
        }
        let selectedAudio = audio.first { $0.id == activeAudioId } ?? audio.first
        var info: [String: Any] = [
            "engine": "AetherEngine",
            "videoCodec": engine.sourceVideoCodecName ?? "",
            "videoDecoder": engine.activeVideoDecoder ?? "",
            "hdrFormat": hdr,
            "videoWidth": Int(engine.sourceVideoWidth),
            "videoHeight": Int(engine.sourceVideoHeight),
            "fps": engine.sourceVideoFrameRate ?? 0,
            "audioCodec": selectedAudio?.codec ?? "",
            "audioDecoder": engine.activeAudioDecoder ?? "",
            "audioChannels": (selectedAudio?.channels ?? 0) > 0 ? "\(selectedAudio!.channels)" : "",
            "audioSampleRate": (selectedAudio?.sampleRate ?? 0) > 0 ? "\(selectedAudio!.sampleRate)" : "",
            "audioLang": selectedAudio?.language ?? "",
            "videoBitrateKbps": Int(engine.sourceVideoBitrate / 1000),
            "audioBitrateKbps": Int((selectedAudio?.bitrate ?? 0) / 1000),
        ]
        if let profile = engine.sourceDVProfile { info["dvProfile"] = "\(profile)" }
        for (key, value) in diagnostics() { info[key] = value }
        return info
    }

    func diagnostics() -> [String: Any] {
        var d: [String: Any] = [
            "aetherVersion": BannerPlaybackKitEntry.aetherEngineVersion,
            "route": route.rawValue,
            "rendering": Self.renderingLabel(route),
            "rebufferCount": rebufferCount,
            "bufferedSeconds": max(0, bufferedPosition - currentTime),
        ]
        if firstFrameAt > 0, loadStartedAt > 0 { d["firstFrameMs"] = Int((firstFrameAt - loadStartedAt) * 1000) }
        if let startup = engine.startupProgress { d["startupPhase"] = "\(startup)" }
        return d
    }

    static func renderingLabel(_ route: VideoRoute) -> String {
        switch route {
        case .loopback: return "Native AVPlayer / VideoToolbox (local HLS)"
        case .remoteBypass: return "Native AVPlayer / VideoToolbox (direct HLS)"
        case .software: return "Software decode (AetherEngine)"
        case .audio: return "Audio only"
        case .none: return "Not started"
        }
    }

    // MARK: Picture in Picture

    var isPictureInPictureSupported: Bool {
        guard !destroyed, AVPictureInPictureController.isPictureInPictureSupported() else { return false }
        return engine.nativePlayerLayer != nil || softwarePiPSource != nil
    }

    /// The software route builds its PiP controller from the engine's source, and the source changes as the session does: the
    /// controller is rebuilt each time, as the engine documents.
    private func softwarePiPSourceChanged(_ source: SoftwarePiPSource?) {
        softwarePiPSource = source
        guard engine.nativePlayerLayer == nil else { return }
        let wasActive = pipController?.isPictureInPictureActive == true
        pipController = source?.makePictureInPictureController()
        pipController?.delegate = self
        applyAutomaticPiP(pipController)
        if wasActive { pipController?.startPictureInPicture() }
    }

    private func applyAutomaticPiP(_ controller: AVPictureInPictureController?) {
        // Leaving the app while a film plays moves it into a floating window instead of stopping the picture.
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    func startPictureInPicture() {
        guard isPictureInPictureSupported else { return }
        if let layer = engine.nativePlayerLayer {
            if pipController == nil || pipController?.playerLayer !== layer {
                pipController = AVPictureInPictureController(playerLayer: layer)
                pipController?.delegate = self
                applyAutomaticPiP(pipController)
            }
        } else if pipController == nil, let source = softwarePiPSource {
            pipController = source.makePictureInPictureController()
            pipController?.delegate = self
            applyAutomaticPiP(pipController)
        }
        pipController?.startPictureInPicture()
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { engine.pictureInPictureActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { engine.pictureInPictureActive = false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { engine.pictureInPictureActive = false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The player screen is still mounted (leaving it destroys the session), so there is nothing to bring back.
        completionHandler(true)
    }

    // MARK: Now Playing and teardown

    func setNowPlaying(title: String, subtitle: String?, artworkURL: String?) {
        nowPlayingTitle = title
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let subtitle, !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        engine.setNowPlayingInfo(info)
    }

    func clearNowPlaying() { nowPlayingTitle = nil }

    /// Ends this surface's session and releases it. The engine itself stays alive for the next title.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        generation += 1
        pendingRequest = nil
        loadTask?.cancel()
        loadTask = nil
        cancellables.removeAll()
        clockCancellables.removeAll()
        onEvent = nil
        onSubtitleText = nil
        pipController?.stopPictureInPicture()
        pipController = nil
        engine.pictureInPictureActive = false
        engine.stop()
        engine.unbind(view: container.playerView)
    }
}
