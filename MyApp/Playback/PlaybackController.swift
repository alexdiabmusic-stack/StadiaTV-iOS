import Foundation
import AVFoundation
import Combine
import os
#if canImport(UIKit)
import UIKit
#endif

/// Owns the single AVPlayer for a player presentation.
///
/// The player outlives any view that shows it, so rotating the device or rebuilding the
/// layout re-attaches the same AVPlayer instead of re-buffering from zero. Changing
/// channel or source swaps the current item on that same player.
///
/// Live channels play through the stream engine (`StreamEngineSession`): it holds the provider
/// connection, keeps a reserve of programme ahead of the picture, reconnects and splices in the
/// background, and serves AVPlayer a steady local HLS stream. The engine's referee owns network
/// recovery; this controller only rebuilds the player item when AVPlayer itself gets stuck, and
/// applies the engine's playback pace. Streams the engine doesn't carry (on-demand, catch-up,
/// adaptive or encrypted HLS) play directly, as does everything when the engine is turned off.
///
/// The main player can skip AVPlayer for engine channels: `NativeLivePlayer` renders the engine's
/// samples itself and shows a picture as soon as the first keyframe is in, where AVPlayer waits for
/// seconds of playlist. If it can't play a channel (a codec it doesn't take, no picture in time,
/// AirPlay), the engine starts again for AVPlayer.
///
/// Responsibilities:
/// - start-up tuning (buffer profile, first eligible variant, play immediately when ready)
/// - start-up watchdog and fallback URLs (e.g. an Xtream `.ts` URL tried as `.m3u8` first)
/// - direct playback stall recovery: reconnect with backoff, then report failure so Auto can fail over
/// - detecting video streams that play with no picture (only when the manifest advertises video)
/// - audio-session interruptions, headphone unplug, foreground return and live-edge tracking
@MainActor
final class PlaybackController: ObservableObject {
    /// Where this controller plays: multiview tiles keep a small reserve so several fit in memory.
    enum Role {
        case primary
        case multiviewTile
    }

    enum State: Equatable {
        case idle
        case loading
        case preparing
        case connecting
        case recovering
        case ended
        case playing
        case buffering
        case paused
        case failed(String)
    }

    static let maxReconnectAttempts = 4
    private static let reconnectDelays: [Double] = [0.5, 1, 2, 4]
    /// How long a mid-stream stall may last before the stream is rebuilt.
    private static let stallReconnectDelay: Duration = .seconds(6)
    /// How long playback may run with no picture before a video stream counts as broken.
    private static let videolessFailureSeconds = 8
    /// Buffering shorter than this doesn't show a spinner.
    private static let bufferingIndicatorDelay: Duration = .milliseconds(700)
    /// Paused (or backgrounded) longer than this resumes at the live edge instead of a stale buffer.
    private static let staleBufferInterval: TimeInterval = 30
    /// Distance behind the recommended live offset at which "Go Live" appears.
    private static let behindLiveThreshold: Double = 15

    @Published private(set) var state: State = .idle
    /// True once the current channel has shown its first frame (or, for audio-only
    /// streams, started playing). Stays true across reconnects of the same channel.
    @Published private(set) var firstFrameRendered = false
    @Published private(set) var currentItem: AVPlayerItem?
    /// Non-zero while a reconnect is in progress (1…`maxReconnectAttempts`).
    @Published private(set) var reconnectAttempt = 0
    /// Buffering has lasted long enough to be worth showing.
    @Published private(set) var showsBufferingIndicator = false
    @Published private(set) var isBehindLiveEdge = false
    @Published private(set) var isUserPaused = false
    @Published private(set) var isMuted = false
    /// Heights (e.g. 1080, 720) advertised by the current HLS stream, for the quality picker.
    @Published private(set) var availableHeights: [Int] = []
    @Published private(set) var qualityCap: PlayerQualityCap = .auto
    /// DEBUG-only start-up timing line for the on-screen overlay.
    @Published private(set) var metricsSummary: String?
    /// The stream engine's live telemetry; nil while AVPlayer plays the provider URL directly.
    @Published private(set) var engineStatus: StreamEngineStatus?

    let player = AVPlayer()
    let role: Role
    private(set) var channel: Channel?
    private(set) var bufferProfile: PlayerBufferProfile
    /// Set by the `audioOnly` argument to the most recent `load(_:audioOnly:)` call. Drives
    /// which audio-session category an interruption resume re-activates, since this
    /// controller is now shared across a video presentation (phone `PlayerView`) and
    /// audio-only ones (CarPlay, Siri) rather than owned by a single always-video caller.
    private(set) var isAudioOnlySession = false
    private var peakBitRate: Double = 0

    /// Called when the current stream can't be played (after fallback URLs and reconnects
    /// are exhausted). The owner decides whether to fail over or show an error.
    var onFailure: ((String) -> Void)?
    private var failureObservers: [UUID: (String) -> Void] = [:]

    func observeFailures(owner: UUID, handler: @escaping (String) -> Void) {
        failureObservers[owner] = handler
    }

    func removeFailureObserver(owner: UUID) {
        failureObservers.removeValue(forKey: owner)
    }
    /// Called once per channel when the first frame renders, with time-to-first-frame in ms.
    var onFirstFrame: ((Channel, Int?) -> Void)?
    /// Called when a new item becomes ready, e.g. to read its audio/subtitle groups.
    var onItemReady: ((AVPlayerItem) -> Void)?
    var onMetadata: ((StreamRuntimeMetadata) -> Void)?

    private var metrics: PlaybackMetrics?
    private var pendingTapDate: Date?
    private var hasLoadedOnce = false
    private var urlCandidates: [URL] = []
    private var urlIndex = 0
    /// Bumped whenever the current item is replaced; async work from older items checks it and bails.
    private var generation = 0
    private var isWaitingToReconnect = false
    /// The current item reached `.playing` at least once.
    private var itemHasPlayed = false
    private var didNotifyItemReady = false
    private var pausedAt: Date?
    private var backgroundedAt: Date?
    private var wasPlayingBeforeInterruption = false
    /// True while this controller asks background refreshers to wait (tap → first frame).
    private var holdsPlaybackPriority = false

    private var itemObservations: [NSKeyValueObservation] = []
    private let itemTokens = NotificationTokens()
    private let systemTokens = NotificationTokens()
    private var timeControlObservation: NSKeyValueObservation?

    private var watchdogTask: Task<Void, Never>?
    private var stallTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var bufferingTask: Task<Void, Never>?

    // Stream engine.
    private var engineSession: StreamEngineSession?
    /// The current item plays the engine's local stream.
    private var usesEngine = false
    private var engineConfiguration = StreamEngineConfiguration.profile(.balanced)
    /// Pitch-corrected rate the engine asked for.
    private var engineRate: Double = 1.0
    /// Times AVPlayer's item was rebuilt on the same engine session, for rate limiting.
    private var engineItemRebuilds: [Date] = []
    private var externalPlaybackObservation: NSKeyValueObservation?
    private static let maxEngineItemRebuilds = 3
    private static let engineItemRebuildWindow: TimeInterval = 120

    // Native player.
    /// The native player's picture, which the video surfaces show.
    private(set) lazy var nativeVideo = NativeVideoOutput()
    /// The engine's samples play through `NativeLivePlayer` rather than AVPlayer.
    @Published private(set) var usesNativePlayer = false
    /// The native player's picture size (AVPlayer's is its item's).
    @Published private(set) var nativeVideoSize: CGSize = .zero
    private var nativePlayer: NativeLivePlayer?
    /// Distinguishes the current native player's events from those of one already stopped.
    private var nativeToken: UUID?
    /// The current engine session feeds the native player.
    private var engineUsesNative = false
    /// The native player couldn't play the current channel; until the next one, AVPlayer plays it.
    private var nativeRefused = false
    /// The native player has played sound (a picture may not follow: radio, or a codec it lacks).
    private var nativeAudioStarted = false
    /// Something other than the viewer holds the native player still (an interruption, the background).
    private var nativeHeld = false
    /// A picture-in-picture window shows the native picture, so it keeps playing in the background.
    private var isPictureInPictureActive = false
    /// How long the native player may take from the engine's first segment to a picture.
    private static let nativeStartTimeout: Duration = .seconds(6)
    private var nativePictureTask: Task<Void, Never>?

    init(tapDate: Date? = nil, bufferProfile: PlayerBufferProfile = .balanced, role: Role = .primary) {
        self.pendingTapDate = tapDate
        self.bufferProfile = bufferProfile
        self.role = role
        #if !os(visionOS)
        player.allowsExternalPlayback = true
        #endif
        player.appliesMediaSelectionCriteriaAutomatically = true
        PlaybackItemFactory.apply(bufferProfile, to: player)
        observePlayer()
        observeSystemEvents()
    }

    // MARK: - Public API

    /// Something is loaded or on its way: a player item, or a stream engine session.
    var hasStream: Bool { currentItem != nil || engineSession != nil }

    /// The picture's size, whichever player shows it.
    var presentationSize: CGSize {
        usesNativePlayer ? nativeVideoSize : (player.currentItem?.presentationSize ?? .zero)
    }

    /// Which player shows the picture, for diagnostics.
    var playerDescription: String? {
        guard usesEngine else { return nil }
        return usesNativePlayer ? "Instant Start (native renderer)" : "AVPlayer"
    }

    /// Loads the engine's actual track groups for any platform presentation.
    /// Re-check item ownership after each suspension; old track menus must never reach a new feed.
    func mediaSelections(for item: AVPlayerItem, preferences: PreferencesStore) async -> (audio: AVMediaSelectionGroup?, subtitles: AVMediaSelectionGroup?, audioIndex: Int?, subtitleIndex: Int?)? {
        let requestGeneration = generation
        let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        guard !Task.isCancelled, generation == requestGeneration, currentItem === item else { return nil }
        let subtitles = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, generation == requestGeneration, currentItem === item else { return nil }
        if let audio, let option = audio.options.first(where: { $0.extendedLanguageTag == preferences.preferredAudioLanguage }) {
            item.select(option, in: audio)
        }
        if let subtitles {
            if preferences.preferredSubtitleLanguage == "off" { item.select(nil, in: subtitles) }
            else if let option = subtitles.options.first(where: { $0.extendedLanguageTag == preferences.preferredSubtitleLanguage }) {
                item.select(option, in: subtitles)
            }
        }
        let audioIndex = audio.flatMap { group in
            item.currentMediaSelection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }
        }
        let subtitleIndex = subtitles.flatMap { group in
            item.currentMediaSelection.selectedMediaOption(in: group).flatMap { group.options.firstIndex(of: $0) }
        }
        return (audio, subtitles, audioIndex, subtitleIndex)
    }

    func selectMedia(index: Int?, group: AVMediaSelectionGroup?, isSubtitle: Bool, preferences: PreferencesStore) {
        guard let item = currentItem, let group else { return }
        let option = index.flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
        guard option != nil || isSubtitle else { return }
        item.select(option, in: group)
        if isSubtitle { preferences.setPreferredSubtitleLanguage(option == nil ? "off" : (option?.extendedLanguageTag ?? "")) }
        else { preferences.setPreferredAudioLanguage(option?.extendedLanguageTag ?? "") }
    }

    /// Records the tap timestamp for the *next* `load()` call's time-to-first-frame metric.
    /// The controller is now a long-lived shared instance (one per process, reused across
    /// presentations and across CarPlay/phone — see `BannerAppEnvironment.playbackController`)
    /// rather than constructed fresh per presentation, so callers that used to pass `tapDate`
    /// to `init` call this immediately before their own `load()` instead.
    func notePendingTapDate(_ date: Date) {
        pendingTapDate = date
    }

    /// Starts `channel` on the shared player, replacing whatever was playing.
    /// - Parameter audioOnly: true for CarPlay/Siri driving-mode playback — activates the
    ///   `.spokenAudio` session instead of claiming the video/movie-playback session, since
    ///   no video surface will be attached. Defaults to false (today's phone `PlayerView`
    ///   behavior, unchanged).
    var onPlaybackRequested: (() -> Void)?

    private(set) var isOnDemand = false
    private var pendingResumePosition: Double = 0

    func load(_ channel: Channel, audioOnly: Bool = false, onDemand: Bool = false, resumePosition: Double = 0) {
        isOnDemand = onDemand
        pendingResumePosition = resumePosition.isFinite ? max(0, resumePosition) : 0
        onPlaybackRequested?()
        state = .preparing
        isWaitingToReconnect = false
        isAudioOnlySession = audioOnly
        let now = Date()
        let tapDate = pendingTapDate ?? now
        pendingTapDate = nil

        generation += 1
        cancelTasks()
        currentItem?.cancelPendingSeeks()
        detachItemObservers()
        stopEngine()
        // The engine's first segment arrives asynchronously; the previous channel must not keep playing meanwhile.
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        self.channel = channel
        urlCandidates = onDemand ? [channel.streamURL] : PlaybackItemFactory.playbackURLCandidates(for: channel.streamURL)
        urlIndex = 0
        reconnectAttempt = 0
        availableHeights = []
        firstFrameRendered = false
        isUserPaused = false
        isBehindLiveEdge = false
        pausedAt = nil
        nativeRefused = false
        setBuffering(false)

        var metrics = PlaybackMetrics(tapDate: tapDate, url: channel.streamURL)
        if !hasLoadedOnce { metrics.record(.playerAppeared, at: now) }
        self.metrics = metrics
        hasLoadedOnce = true

        guard channel.streamURL.scheme?.lowercased() != "about" else {
            fail("No confirmed stream found.")
            return
        }

        if audioOnly { AudioSessionManager.activateForAudioOnly() } else { AudioSessionManager.activateForVideo() }
        NotificationCenter.default.post(name: .bannerVideoPlaybackWillStart, object: nil)
        setHoldsPlaybackPriority(true)
        if !startEngine(for: channel) {
            startCurrentURL()
        }
    }

    func play() {
        onPlaybackRequested?()
        isUserPaused = false
        if let pausedAt, Date().timeIntervalSince(pausedAt) > Self.staleBufferInterval {
            seekToLiveEdge()
        }
        pausedAt = nil
        resumePlayback()
    }

    func pause() {
        isUserPaused = true
        pausedAt = Date()
        watchdogTask?.cancel()
        stallTask?.cancel()
        player.pause()
        updateNativePause()
        if currentItem != nil || nativePlayer != nil { state = .paused }
        setBuffering(false)
    }

    func stop() {
        setHoldsPlaybackPriority(false)
        generation += 1
        cancelTasks()
        detachItemObservers()
        stopEngine()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        channel = nil
        state = .idle
        setBuffering(false)
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
        nativePlayer?.setMuted(muted)
        isMuted = muted
    }

    func togglePlayPause() {
        if isUserPaused || (nativePlayer == nil && player.timeControlStatus == .paused) { play() } else { pause() }
    }

    /// Caps resolution and bitrate on the current (and future) items.
    func setQualityCap(_ cap: PlayerQualityCap) {
        qualityCap = cap
        peakBitRate = cap.peakBitRate
        currentItem?.preferredPeakBitRate = cap.peakBitRate
        currentItem?.preferredMaximumResolution = cap.maximumResolution
    }

    /// Applies a buffer profile to the live player and item immediately. The stream engine's
    /// reserve profile takes effect from the next channel load.
    func setBufferProfile(_ profile: PlayerBufferProfile) {
        bufferProfile = profile
        PlaybackItemFactory.apply(profile, to: player)
        if usesEngine { player.automaticallyWaitsToMinimizeStalling = false }
    }

    func setPreferredPeakBitRate(_ bitRate: Double) {
        peakBitRate = bitRate
        currentItem?.preferredPeakBitRate = bitRate
    }

    /// Jumps to the live point of a live stream.
    func seekToLiveEdge() {
        guard !isOnDemand else { return }
        if usesEngine, let session = engineSession {
            // Hand the whole reserve to the player and rejoin near its newest programme: the native
            // player is handed it from there, AVPlayer needs a new item.
            session.jumpToLive()
            isBehindLiveEdge = false
            if nativePlayer == nil, currentItem != nil { startEngineItem(url: session.playlistURL) }
            return
        }
        guard let item = currentItem, item.duration.isIndefinite,
              let range = item.seekableTimeRanges.last?.timeRangeValue,
              let target = Self.liveSeekTarget(
                rangeStart: range.start.seconds,
                rangeEnd: CMTimeRangeGetEnd(range).seconds,
                recommendedOffset: item.recommendedTimeOffsetFromLive.seconds
              ) else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        isBehindLiveEdge = false
    }

    /// A server-provided offset may exceed a short DVR window or be nonnumeric.
    static func liveSeekTarget(rangeStart: Double, rangeEnd: Double, recommendedOffset: Double) -> Double? {
        guard rangeStart.isFinite, rangeEnd.isFinite, rangeEnd > rangeStart else { return nil }
        let offset = recommendedOffset.isFinite ? max(0, recommendedOffset) : 0
        return max(rangeStart, rangeEnd - offset)
    }

    /// Called by the video surface when its AVPlayerLayer has a frame to show.
    func surfaceReadyForDisplay() {
        guard nativePlayer == nil else { return }
        markFirstFrame()
    }

    /// Called by the iOS player surface as its picture-in-picture window opens and closes.
    func pictureInPictureChanged(isActive: Bool) {
        isPictureInPictureActive = isActive
        // Closed while the app is in the background: like AVPlayer, the native player stops there.
        if !isActive, backgroundedAt != nil { holdNativeInBackground() }
    }

    // MARK: - Item lifecycle

    private func startCurrentURL() {
        guard let channel, urlCandidates.indices.contains(urlIndex) else { return }
        isWaitingToReconnect = false
        generation += 1
        let generation = generation
        detachItemObservers()
        watchdogTask?.cancel()
        monitorTask?.cancel()
        itemHasPlayed = false
        didNotifyItemReady = false

        let url = urlCandidates[urlIndex]
        let item = PlaybackItemFactory.makeItem(url: url, headers: channel.httpHeaders,
                                                profile: bufferProfile, peakBitRate: peakBitRate)
        item.preferredMaximumResolution = qualityCap.maximumResolution
        attachObservers(to: item)
        currentItem = item
        state = isUserPaused ? .paused : (reconnectAttempt == 0 ? .connecting : .recovering)
        metrics?.record(.itemCreated)
        publishMetrics()

        player.replaceCurrentItem(with: item)
        if !isUserPaused { player.play() }

        startWatchdog(generation: generation)
        startMonitor(item: item, generation: generation)
    }

    /// The stream (or a fallback URL) couldn't start.
    private func startupFailed(_ reason: String) {
        if usesEngine {
            // A rebuilt item that's slow to start is the engine's to handle (it may be riding out
            // an outage). Before the first picture, AVPlayer couldn't play the engine's stream at
            // all (an unsupported codec, say): try the provider URL.
            if !firstFrameRendered { fallbackToDirect(reason: reason) }
        } else if reconnectAttempt > 0 {
            reconnect(reason: reason)
        } else if urlIndex + 1 < urlCandidates.count {
            urlIndex += 1
            PlaybackMetrics.logger.info("Start-up failed (\(reason, privacy: .public)); trying fallback URL \(self.urlIndex + 1)/\(self.urlCandidates.count)")
            startCurrentURL()
        } else {
            fail(reason)
        }
    }

    /// Rebuilds the item for the same URL after a mid-stream failure or long stall.
    private func reconnect(reason: String) {
        if isOnDemand {
            let position = player.currentTime().seconds
            if position.isFinite, position > 0 { pendingResumePosition = position }
        }
        guard reconnectAttempt < Self.maxReconnectAttempts else {
            fail("Lost connection to the stream.")
            return
        }
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let delay = Self.reconnectDelays[min(attempt - 1, Self.reconnectDelays.count - 1)]
        PlaybackMetrics.logger.info("Reconnecting \(attempt)/\(Self.maxReconnectAttempts) in \(delay) s (\(reason, privacy: .public))")

        generation += 1
        let generation = generation
        detachItemObservers()
        watchdogTask?.cancel()
        monitorTask?.cancel()
        stallTask?.cancel()
        isWaitingToReconnect = true
        state = .recovering
        setBuffering(true)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.startCurrentURL()
        }
    }

    /// Gives up on the current stream and hands the decision to the owner.
    private func fail(_ reason: String) {
        setHoldsPlaybackPriority(false)
        generation += 1
        cancelTasks()
        detachItemObservers()
        stopEngine()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        reconnectAttempt = 0
        setBuffering(false)
        state = .failed(reason)
        metrics?.record(.failed, reason: reason)
        publishMetrics()
        if let channel {
            StreamHealthStore.shared.recordFailure(streamID: channel.id)
        }
        onFailure?(reason)
        for handler in Array(failureObservers.values) { handler(reason) }
    }

    /// The current item is playing its programme: the start-up watchdog and any stall timer stand down.
    private func itemStarted() {
        itemHasPlayed = true
        stallTask?.cancel()
        watchdogTask?.cancel()
    }

    private func markFirstFrame() {
        guard !firstFrameRendered, currentItem != nil || nativePlayer != nil else { return }
        firstFrameRendered = true
        setHoldsPlaybackPriority(false)
        metrics?.record(.firstFrame)
        publishMetrics()
        let ttff = metrics?.timeToFirstFrameMs
        if let channel {
            StreamHealthStore.shared.recordSuccess(streamID: channel.id, ttffMs: ttff)
            onFirstFrame?(channel, ttff)
        }
    }

    private func resumePlayback() {
        if let nativePlayer {
            nativeHeld = false
            nativePlayer.setPaused(isUserPaused)
            return
        }
        guard currentItem != nil else { return }
        if usesEngine {
            // The engine decides how much to buffer; AVPlayer plays whatever it has been given.
            player.playImmediately(atRate: effectiveEngineRate)
        } else if !bufferProfile.waitsToMinimizeStalling, currentItem?.status == .readyToPlay {
            player.playImmediately(atRate: 1)
        } else {
            player.play()
        }
    }

    // MARK: - Watchdog & monitor

    /// Fails over when an item never starts playing within the profile's start-up window.
    private func startWatchdog(generation: Int) {
        watchdogTask?.cancel()
        let timeout = bufferProfile.startupTimeout
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, self.generation == generation,
                  !self.itemHasPlayed, !self.isUserPaused else { return }
            PlaybackMetrics.logger.info("No playback within \(timeout) s")
            self.startupFailed("The stream didn't start in time.")
        }
    }

    /// Once-a-second checks for the current item: first-frame fallback, videoless
    /// detection, metadata reads and live-edge distance.
    private func startMonitor(item: AVPlayerItem, generation: Int) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var secondsPlayingWithoutPicture = 0
            var advertisesVideo: Bool?
            var secondsSinceReady = 0
            var metadataReads = 0
            let metadataSchedule: Set<Int> = [2, 4, 7, 12, 20]

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.generation == generation, self.currentItem === item else { return }

                let size = item.presentationSize
                let hasPicture = size.width > 0 && size.height > 0
                let isPlaying = item.status == .readyToPlay && self.player.timeControlStatus == .playing

                if hasPicture {
                    secondsPlayingWithoutPicture = 0
                    if !self.itemHasPlayed { self.itemStarted() }
                    self.markFirstFrame()
                } else if isPlaying {
                    secondsPlayingWithoutPicture += 1
                } else {
                    secondsPlayingWithoutPicture = 0
                }

                // A picture-less stream is only broken if its manifest advertises video;
                // genuine audio-only channels (radio) are left alone and count as started.
                if secondsPlayingWithoutPicture >= 3, advertisesVideo == nil {
                    let result: Bool
                    if self.usesEngine {
                        result = self.engineCarriesVideo
                    } else {
                        result = await Self.manifestAdvertisesVideo(item)
                    }
                    guard !Task.isCancelled, self.generation == generation else { return }
                    advertisesVideo = result
                    if !result {
                        self.itemStarted()
                        self.markFirstFrame()
                    }
                }
                if advertisesVideo == true, secondsPlayingWithoutPicture >= Self.videolessFailureSeconds {
                    PlaybackMetrics.logger.info("Playing \(secondsPlayingWithoutPicture) s with no picture on a video stream")
                    self.fail("This source is playing without a picture.")
                    return
                }

                if item.status == .readyToPlay {
                    secondsSinceReady += 1
                    if metadataSchedule.contains(secondsSinceReady), metadataReads < metadataSchedule.count {
                        metadataReads += 1
                        if let metadata = await StreamMetadataReader.metadata(from: item) {
                            guard !Task.isCancelled, self.generation == generation else { return }
                            self.onMetadata?(metadata)
                        }
                    }
                }

                if self.usesEngine {
                    self.reportEnginePlayback()
                } else {
                    self.updateLiveEdgeDistance(for: item)
                }
            }
        }
    }

    private static func manifestAdvertisesVideo(_ item: AVPlayerItem) async -> Bool {
        guard let asset = item.asset as? AVURLAsset,
              let variants = try? await asset.load(.variants) else { return false }
        return variants.contains { $0.videoAttributes != nil }
    }

    private func updateLiveEdgeDistance(for item: AVPlayerItem) {
        guard item.duration.isIndefinite,
              let range = item.seekableTimeRanges.last?.timeRangeValue,
              range.duration.isNumeric, range.duration.seconds > Self.behindLiveThreshold * 2 else {
            if isBehindLiveEdge { isBehindLiveEdge = false }
            return
        }
        let behind = CMTimeRangeGetEnd(range).seconds - item.currentTime().seconds
        let offset = item.recommendedTimeOffsetFromLive
        let expected = offset.isValid && offset.isNumeric ? offset.seconds : 0
        let isBehind = behind - expected > Self.behindLiveThreshold
        if isBehind != isBehindLiveEdge { isBehindLiveEdge = isBehind }
    }

    // MARK: - Observation

    private func observePlayer() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.timeControlStatusChanged() }
        }
        #if !os(visionOS)
        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in self?.externalPlaybackChanged() }
        }
        #endif
    }

    private func timeControlStatusChanged() {
        guard currentItem != nil, !isWaitingToReconnect else { return }
        switch player.timeControlStatus {
        case .playing:
            if isOnDemand { isUserPaused = false }
            itemHasPlayed = true
            stallTask?.cancel()
            watchdogTask?.cancel()
            // An engine item is told to play immediately, so AVPlayer reports playing before it has
            // anything to show: it has started once it shows a picture (see the monitor).
            if !usesEngine { itemStarted() }
            if reconnectAttempt > 0 {
                PlaybackMetrics.logger.info("Reconnected after \(self.reconnectAttempt) attempt(s)")
                reconnectAttempt = 0
            }
            state = .playing
            setBuffering(false)
        case .waitingToPlayAtSpecifiedRate:
            guard !isUserPaused else { return }
            if itemHasPlayed {
                state = .buffering
                // With the engine, a stall means the reserve ran dry; rebuilding the item would
                // only throw away what's buffered. The engine's referee owns that recovery.
                if !usesEngine { startStallTimer() }
            }
            setBuffering(true)
        case .paused:
            // Native AVKit controls operate the same player directly for on-demand media.
            if isOnDemand, itemHasPlayed, state != .ended {
                isUserPaused = true
                stallTask?.cancel()
                watchdogTask?.cancel()
            }
            if isUserPaused, state != .ended { state = .paused }
            setBuffering(false)
        @unknown default:
            break
        }
        reportEnginePlayback()
    }

    private func startStallTimer() {
        guard stallTask == nil || stallTask?.isCancelled == true else { return }
        let generation = generation
        stallTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stallReconnectDelay)
            guard let self, !Task.isCancelled, self.generation == generation, !self.isUserPaused,
                  self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            self.stallTask = nil
            self.reconnect(reason: "stalled")
        }
    }

    private func setBuffering(_ buffering: Bool) {
        bufferingTask?.cancel()
        guard buffering else {
            if showsBufferingIndicator { showsBufferingIndicator = false }
            return
        }
        bufferingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.bufferingIndicatorDelay)
            guard let self, !Task.isCancelled else { return }
            self.showsBufferingIndicator = true
        }
    }

    private func attachObservers(to item: AVPlayerItem) {
        let observedGeneration = generation
        itemObservations = [
            item.observe(\.status, options: [.new]) { @Sendable [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.generation == observedGeneration,
                          self.currentItem === item else { return }
                    self.itemStatusChanged()
                }
            }
        ]
        let center = NotificationCenter.default
        itemTokens.add(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let message = Self.safeErrorMessage(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            MainActor.assumeIsolated {
                guard self?.generation == observedGeneration else { return }
                self?.itemFailedMidStream(message)
            }
        })
        itemTokens.add(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == observedGeneration else { return }
                self.cancelTasks()
                self.setHoldsPlaybackPriority(false)
                self.setBuffering(false)
                self.state = .ended
            }
        })
        itemTokens.add(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.generation == observedGeneration else { return }
                self?.itemStalled()
            }
        })
        itemTokens.add(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.generation == observedGeneration else { return }
                self?.logLatestErrorLogEntry()
            }
        })
    }

    /// Never surface provider error descriptions: they may contain signed URLs or credentials.
    nonisolated static func safeErrorMessage(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "Stream unavailable. Try again or choose another broadcast." }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "Network unavailable. Check your connection and retry."
            case NSURLErrorTimedOut:
                return "The stream timed out. Try again."
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
                return "Access denied. Check your IPTV account."
            case NSURLErrorCannotDecodeContentData, NSURLErrorCannotDecodeRawData:
                return "The stream could not be decoded. Choose another broadcast."
            default: break
            }
        }
        return "Stream unavailable or unsupported. Try again or choose another broadcast."
    }

    /// A conservative resource budget, not a guarantee of simultaneous codec support.
    static var multiviewCapacity: Int {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical {
            return 2
        }
        return info.physicalMemory >= 6 * 1_024 * 1_024 * 1_024 ? 4 : 2
    }

    func seek(by seconds: Double) {
        guard let item = currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue,
              range.duration.isNumeric, range.duration.seconds > 30,
              range.start.seconds.isFinite, CMTimeRangeGetEnd(range).seconds.isFinite,
              seconds.isFinite, item.currentTime().seconds.isFinite else { return }
        let target = min(CMTimeRangeGetEnd(range).seconds, max(range.start.seconds, item.currentTime().seconds + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func detachItemObservers() {
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        itemTokens.removeAll()
    }

    private func itemStatusChanged() {
        guard let item = currentItem else { return }
        switch item.status {
        case .readyToPlay:
            metrics?.record(.readyToPlay)
            publishMetrics()
            if !isUserPaused { resumePlayback() }
            if !didNotifyItemReady {
                didNotifyItemReady = true
                if isOnDemand, pendingResumePosition > 0 {
                    let target = pendingResumePosition
                    pendingResumePosition = 0
                    player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
                }
                onItemReady?(item)
                loadAvailableHeights(for: item)
            }
        case .failed:
            let reason = Self.safeErrorMessage(item.error)
            if usesEngine {
                // Once the channel has shown a picture the engine still holds its programme, so a new
                // item rejoins it; before that, AVPlayer couldn't play the engine's stream at all.
                if firstFrameRendered { rebuildEngineItem(reason: "player item failed") } else { startupFailed(reason) }
            } else if itemHasPlayed {
                reconnect(reason: reason)
            } else {
                startupFailed(reason)
            }
        default:
            break
        }
    }

    /// Logs HTTP/segment errors AVPlayer recovered from on its own (no URLs, which carry credentials).
    private func loadAvailableHeights(for item: AVPlayerItem) {
        let generation = generation
        Task { [weak self] in
            guard let asset = item.asset as? AVURLAsset,
                  let variants = try? await asset.load(.variants) else { return }
            let heights = Set(variants.compactMap { $0.videoAttributes?.presentationSize.height }.map { Int($0.rounded()) })
            guard let self, self.generation == generation else { return }
            self.availableHeights = heights.sorted(by: >)
        }
    }

    private func logLatestErrorLogEntry() {
        guard let event = currentItem?.errorLog()?.events.last else { return }
        PlaybackMetrics.logger.debug("Stream error log: \(event.errorDomain, privacy: .public) \(event.errorStatusCode)")
    }

    private func itemFailedMidStream(_ message: String?) {
        guard currentItem != nil else { return }
        if usesEngine {
            rebuildEngineItem(reason: message ?? "failed to play to end")
        } else {
            reconnect(reason: message ?? "failed to play to end")
        }
    }

    private func itemStalled() {
        metrics?.record(.firstStall)
        publishMetrics()
        guard itemHasPlayed, !isUserPaused else { return }
        state = .buffering
        setBuffering(true)
        if usesEngine {
            reportEnginePlayback()
        } else {
            startStallTimer()
        }
    }

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        #if os(iOS) || os(tvOS)
        systemTokens.add(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated { self?.handleInterruption(rawType: rawType, rawOptions: rawOptions) }
        })
        systemTokens.add(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                // Headphones unplugged: pause rather than blasting the speaker.
                if rawReason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                   self?.currentItem != nil || self?.nativePlayer != nil, self?.isUserPaused == false {
                    self?.pause()
                }
                self?.audioRouteChanged()
            }
        })
        #endif
        #if canImport(UIKit)
        systemTokens.add(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        })
        systemTokens.add(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnedToForeground() }
        })
        #endif
    }

    #if os(iOS) || os(tvOS)
    private func handleInterruption(rawType: UInt?, rawOptions: UInt) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType),
              currentItem != nil || nativePlayer != nil else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = !isUserPaused && (nativePlayer != nil || player.timeControlStatus != .paused)
            player.pause()
            if nativePlayer != nil {
                nativeHeld = true
                updateNativePause()
            }
            pausedAt = Date()
            watchdogTask?.cancel()
            stallTask?.cancel()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume), wasPlayingBeforeInterruption, !isUserPaused {
                if isAudioOnlySession { AudioSessionManager.activateForAudioOnly() } else { AudioSessionManager.activateForVideo() }
                if let pausedAt, Date().timeIntervalSince(pausedAt) > Self.staleBufferInterval {
                    seekToLiveEdge()
                }
                pausedAt = nil
                resumePlayback()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }
    #endif

    private func enteredBackground() {
        backgroundedAt = Date()
        guard nativePlayer != nil else { return }
        // Picture in picture opens as the app leaves; give it a moment before deciding.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.backgroundedAt != nil, !self.isPictureInPictureActive else { return }
            self.holdNativeInBackground()
        }
    }

    /// Off screen, AVPlayer stops a video it shows unless picture in picture has it; so does the
    /// native player, which would otherwise carry on as sound alone.
    private func holdNativeInBackground() {
        guard nativePlayer != nil, !isUserPaused else { return }
        nativeHeld = true
        updateNativePause()
    }

    private func returnedToForeground() {
        defer { backgroundedAt = nil }
        if nativePlayer != nil {
            guard nativeHeld, !isUserPaused else { return }
            if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > Self.staleBufferInterval {
                seekToLiveEdge()
            }
            resumePlayback()
            return
        }
        guard currentItem != nil, !isUserPaused, player.rate == 0 else { return }
        if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > Self.staleBufferInterval {
            seekToLiveEdge()
        }
        resumePlayback()
    }

    // MARK: - Stream engine

    /// Distinguishes the current session's events from those of a session already stopped.
    private var engineToken: UUID?

    /// Hands a live channel to the stream engine. Returns false when the channel should play directly.
    private func startEngine(for channel: Channel) -> Bool {
        guard StreamEngineSettings.isEnabled, !isExternalVideoPlaybackActive,
              let routes = StreamEnginePlanner.routes(for: channel.streamURL) else { return false }
        let profile = StreamEngineConfiguration.profile(bufferProfile.engineProfile)
        var configuration = role == .multiviewTile ? profile.forMultiviewTile() : profile
        // The native player is for the main player's pictures; AirPlay takes only its sound.
        let native = StreamEngineSettings.usesNativePlayer && role == .primary && !isAudioOnlySession
            && !nativeRefused && !Self.audioRouteIsAirPlay
        configuration.nativeOutput = native
        engineConfiguration = configuration
        // Only a known one-stream account makes a quick drop look like another device taking over.
        let singleConnection = XtreamAccountStatusStore.shared.statusByPlaylistID[channel.playlistID]?.maxConnections == 1
        let token = UUID()
        let session: StreamEngineSession
        do {
            session = try StreamEngine.shared.makeSession(
                routes: routes, headers: channel.httpHeaders ?? [:], configuration: engineConfiguration,
                isSingleConnectionAccount: singleConnection) { @Sendable [weak self] event in
                    // The main queue keeps the session's events in order.
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.handleEngineEvent(event, token: token) }
                    }
                }
        } catch {
            PlaybackMetrics.logger.error("Stream engine unavailable: \(String(describing: error), privacy: .public)")
            return false
        }
        engineToken = token
        engineSession = session
        usesEngine = true
        engineUsesNative = native
        engineRate = 1.0
        engineItemRebuilds.removeAll()
        player.automaticallyWaitsToMinimizeStalling = false
        state = isUserPaused ? .paused : .connecting
        PlaybackMetrics.logger.info("Stream engine: \(routes.map(\.label).joined(separator: " → "), privacy: .public), \(self.engineConfiguration.profile.rawValue, privacy: .public) reserve, \(native ? "native player" : "AVPlayer", privacy: .public)")
        session.start()

        // The engine reports failure itself; this only guards against it never answering.
        watchdogTask?.cancel()
        let startGeneration = generation
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.generation == startGeneration,
                  self.usesEngine, self.currentItem == nil, self.nativePlayer == nil else { return }
            self.fallbackToDirect(reason: "the stream engine didn't start in time")
        }
        return true
    }

    private func stopEngine() {
        stopNativePlayer()
        engineSession?.stop()
        engineSession = nil
        engineToken = nil
        usesEngine = false
        engineUsesNative = false
        engineStatus = nil
        engineRate = 1.0
        engineItemRebuilds.removeAll()
        player.defaultRate = 1.0
    }

    private func handleEngineEvent(_ event: StreamEngineSession.Event, token: UUID) {
        guard token == engineToken, usesEngine, let session = engineSession else { return }
        switch event {
        case .ready(let url):
            guard currentItem == nil, nativePlayer == nil else { return }
            if engineUsesNative { startNativePlayer(session) } else { startEngineItem(url: url) }
        case .endpointChanged(let url):
            guard currentItem != nil else { return }
            rebuildEngineItem(url: url, reason: "local server moved")
        case .status(let status):
            engineStatus = status
            // The profile's reserve is deliberate distance from live; only drift well past it counts.
            let behind = status.buffered > engineConfiguration.highBuffer + Self.behindLiveThreshold
            if behind != isBehindLiveEdge { isBehindLiveEdge = behind }
        case .pace(let rate):
            applyEngineRate(rate)
        case .decoderResetRequested:
            if nativePlayer != nil {
                restartNativePlayback(reason: "renderer stalled with programme available", counts: true)
            } else {
                rebuildEngineItem(url: session.playlistURL, reason: "player stalled with programme available")
            }
        case .nativeOutputUnsupported(let codec):
            restartEngineWithoutNative(reason: "\(codec) video")
        case .failed(let failure):
            PlaybackMetrics.logger.info("Stream engine stopped: \(failure.message, privacy: .public)")
            if failure.allowsDirectPlayback, !firstFrameRendered {
                fallbackToDirect(reason: failure.message)
            } else {
                fail(failure.message)
            }
        }
    }

    /// Plays the engine's local stream on a fresh item.
    private func startEngineItem(url: URL) {
        isWaitingToReconnect = false
        generation += 1
        let generation = generation
        detachItemObservers()
        watchdogTask?.cancel()
        monitorTask?.cancel()
        stallTask?.cancel()
        itemHasPlayed = false
        didNotifyItemReady = false

        let item = PlaybackItemFactory.makeEngineItem(url: url)
        item.preferredPeakBitRate = peakBitRate
        item.preferredMaximumResolution = qualityCap.maximumResolution
        attachObservers(to: item)
        currentItem = item
        if !firstFrameRendered { state = isUserPaused ? .paused : .connecting }
        metrics?.record(.itemCreated)
        publishMetrics()

        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: item)
        if !isUserPaused { player.playImmediately(atRate: effectiveEngineRate) }

        startWatchdog(generation: generation)
        startMonitor(item: item, generation: generation)
    }

    /// AVPlayer got stuck or failed while the engine still has programme: replace only the
    /// player item. The connection, reserve and timeline carry on, and the new item rejoins at
    /// the same picture (the playlist's EXT-X-START points at it).
    private func rebuildEngineItem(url: URL? = nil, reason: String) {
        guard let session = engineSession else { return }
        let now = Date()
        engineItemRebuilds.removeAll { now.timeIntervalSince($0) > Self.engineItemRebuildWindow }
        guard engineItemRebuilds.count < Self.maxEngineItemRebuilds else {
            fail(StreamEngineFailure.sourceUnavailable.message)
            return
        }
        engineItemRebuilds.append(now)
        PlaybackMetrics.logger.info("Rebuilding the player item (\(reason, privacy: .public))")
        session.noteDecoderReset()
        startEngineItem(url: url ?? session.playlistURL)
    }

    /// The engine can't carry this stream; let AVPlayer fetch the provider URL itself.
    private func fallbackToDirect(reason: String) {
        PlaybackMetrics.logger.info("Playing the provider URL directly (\(reason, privacy: .public))")
        generation += 1
        detachItemObservers()
        stopEngine()
        PlaybackItemFactory.apply(bufferProfile, to: player)
        urlIndex = 0
        reconnectAttempt = 0
        startCurrentURL()
    }

    /// Tells the engine where AVPlayer is, so it publishes just ahead of the picture and knows
    /// when the viewer is actually waiting.
    private func reportEnginePlayback() {
        guard usesEngine, let session = engineSession, let item = currentItem else { return }
        let programmeTime = item.currentDate().map { $0.timeIntervalSince(session.programmeEpoch) }
        let status = player.timeControlStatus
        // Once the channel has shown a picture, any wait is the viewer waiting (a rebuilt item included).
        let waiting = (itemHasPlayed || firstFrameRendered) && !isUserPaused && status == .waitingToPlayAtSpecifiedRate
        // Until the item shows a picture its position is only where it will start, which the engine
        // mustn't publish against.
        session.reportPlayback(programmeTime: programmeTime, isWaiting: waiting,
                               isPlaying: itemHasPlayed && status == .playing, rate: Double(player.rate))
    }

    private func applyEngineRate(_ rate: Double) {
        engineRate = rate
        nativePlayer?.setRate(rate)
        let effective = effectiveEngineRate
        player.defaultRate = effective
        if player.rate > 0 { player.rate = effective }
    }

    /// The engine's pace, limited to what the current item supports.
    private var effectiveEngineRate: Float {
        guard let item = currentItem else { return Float(engineRate) }
        if engineRate < 1, !item.canPlaySlowForward { return 1 }
        if engineRate > 1, !item.canPlayFastForward { return 1 }
        return Float(engineRate)
    }

    // MARK: - Native player

    /// Plays the engine's samples through the native renderer.
    private func startNativePlayer(_ session: StreamEngineSession) {
        isWaitingToReconnect = false
        generation += 1
        let generation = generation
        detachItemObservers()
        watchdogTask?.cancel()
        monitorTask?.cancel()
        stallTask?.cancel()
        itemHasPlayed = false
        nativeAudioStarted = false
        nativeHeld = false

        let token = UUID()
        let native = NativeLivePlayer(
            feed: session.nativeFeed, renderers: nativeVideo.renderers,
            preferredAudioLanguage: StreamEngineSettings.preferredAudioLanguage,
            reportPlayback: { [weak session] programmeTime, waiting, playing, rate in
                session?.reportPlayback(programmeTime: programmeTime, isWaiting: waiting, isPlaying: playing, rate: rate)
            },
            onEvent: { @Sendable [weak self] event in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.handleNativeEvent(event, token: token) }
                }
            })
        nativeToken = token
        nativePlayer = native
        usesNativePlayer = true
        nativeVideoSize = .zero
        nativeVideo.isActive = true
        native.setMuted(isMuted)
        native.setRate(engineRate)
        native.setPaused(isUserPaused)
        native.start()
        if !firstFrameRendered { state = isUserPaused ? .paused : .connecting }
        metrics?.record(.itemCreated)
        publishMetrics()

        // The engine has a keyframe in by now. No picture in time means the renderer can't show
        // this stream, unless it's sound alone.
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: Self.nativeStartTimeout)
            guard let self, !Task.isCancelled, self.generation == generation, self.nativePlayer != nil,
                  !self.itemHasPlayed, !self.isUserPaused else { return }
            if self.nativeAudioStarted, !self.engineCarriesVideo {
                self.nativeStarted()
            } else {
                self.restartEngineWithoutNative(reason: "no picture from the native renderer")
            }
        }
    }

    private func stopNativePlayer() {
        guard let nativePlayer else { return }
        nativePictureTask?.cancel()
        nativePlayer.stop()
        self.nativePlayer = nil
        nativeToken = nil
        nativeHeld = false
        nativeVideo.isActive = false
        usesNativePlayer = false
        nativeVideoSize = .zero
    }

    private func handleNativeEvent(_ event: NativeLivePlayer.Event, token: UUID) {
        guard token == nativeToken, nativePlayer != nil else { return }
        switch event {
        case .pictureQueued:
            watchForNativePicture()
        case .pictureShown:
            nativeStarted()
        case .audioStarted:
            nativeAudioStarted = true
            // Radio. A video channel's picture may just not be in yet: the watchdog decides.
            if engineStatus != nil, !engineCarriesVideo { nativeStarted() }
        case .waiting(let waiting):
            guard itemHasPlayed, !isUserPaused else { return }
            state = waiting ? .buffering : .playing
            setBuffering(waiting)
        case .videoFormat(let width, let height, let codec, let frameRate):
            nativeVideoSize = CGSize(width: width, height: height)
            onMetadata?(StreamRuntimeMetadata(width: Int(width.rounded()), height: Int(height.rounded()), codec: codec,
                                              frameRate: frameRate, bitrate: nil))
        case .rendererFailed(let reason):
            restartEngineWithoutNative(reason: "renderer failed: \(reason)")
        case .restartNeeded:
            restartNativePlayback(reason: "renderer flushed", counts: false)
        }
    }

    /// The first keyframe is queued: the layer says when it's on screen. Only the main actor may
    /// read that, so it's watched here.
    private func watchForNativePicture() {
        let generation = generation
        nativePictureTask?.cancel()
        nativePictureTask = Task { [weak self] in
            for _ in 0..<100 {
                guard let self, !Task.isCancelled, self.generation == generation,
                      self.nativePlayer != nil, !self.itemHasPlayed else { return }
                if self.nativeVideo.layer.isReadyForDisplay {
                    self.nativeStarted()
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// The native player is showing the channel (or playing its sound, for radio).
    private func nativeStarted() {
        guard !itemHasPlayed else { return }
        itemStarted()
        if !isUserPaused { state = .playing }
        setBuffering(false)
        markFirstFrame()
    }

    private func updateNativePause() {
        nativePlayer?.setPaused(isUserPaused || nativeHeld)
    }

    /// The renderers need the programme again from a keyframe: the engine hands it over from where
    /// the picture is. The system asks for this (back from the background, a new audio output);
    /// a renderer that stalls with programme in hand `counts` towards giving up on it.
    private func restartNativePlayback(reason: String, counts: Bool) {
        guard let session = engineSession else { return }
        if counts {
            let now = Date()
            engineItemRebuilds.removeAll { now.timeIntervalSince($0) > Self.engineItemRebuildWindow }
            guard engineItemRebuilds.count < Self.maxEngineItemRebuilds else {
                restartEngineWithoutNative(reason: "renderer kept stalling")
                return
            }
            engineItemRebuilds.append(now)
        }
        PlaybackMetrics.logger.info("Restarting the native renderer (\(reason, privacy: .public))")
        session.noteDecoderReset()
    }

    /// The native player can't play this channel: the engine starts again, publishing for AVPlayer.
    private func restartEngineWithoutNative(reason: String) {
        guard engineUsesNative, let channel else { return }
        PlaybackMetrics.logger.info("Playing through AVPlayer instead of the native renderer (\(reason, privacy: .public))")
        nativeRefused = true
        generation += 1
        cancelTasks()
        stopEngine()
        if !startEngine(for: channel) {
            PlaybackItemFactory.apply(bufferProfile, to: player)
            urlIndex = 0
            reconnectAttempt = 0
            startCurrentURL()
        }
    }

    /// AirPlay takes only the native player's sound; AVPlayer can send the picture as well.
    private func audioRouteChanged() {
        guard engineUsesNative, Self.audioRouteIsAirPlay else { return }
        restartEngineWithoutNative(reason: "AirPlay")
    }

    private static var audioRouteIsAirPlay: Bool {
        #if os(iOS) || os(tvOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        #else
        return false
        #endif
    }

    private var engineCarriesVideo: Bool {
        guard let codecs = engineStatus?.codecs else { return false }
        return ["H.264", "HEVC", "MPEG-2", "MPEG-1"].contains { codecs.contains($0) }
    }

    private var isExternalVideoPlaybackActive: Bool {
        #if os(visionOS)
        return false
        #else
        return player.isExternalPlaybackActive
        #endif
    }

    /// AirPlay video hands the stream URL to the receiver, which can't reach this device's
    /// loopback server; the receiver gets the provider URL instead.
    private func externalPlaybackChanged() {
        guard usesEngine, isExternalVideoPlaybackActive else { return }
        fallbackToDirect(reason: "AirPlay video")
    }

    // MARK: - Helpers

    private func setHoldsPlaybackPriority(_ holds: Bool) {
        guard holds != holdsPlaybackPriority else { return }
        holdsPlaybackPriority = holds
        if holds { PlaybackPriority.beginLoading() } else { PlaybackPriority.endLoading() }
    }

    private func cancelTasks() {
        watchdogTask?.cancel()
        stallTask?.cancel()
        stallTask = nil
        reconnectTask?.cancel()
        monitorTask?.cancel()
        bufferingTask?.cancel()
    }

    private func publishMetrics() {
        metricsSummary = metrics?.summary
    }
}

/// Holds block-based NotificationCenter tokens and removes them when released,
/// so observers never outlive the controller that registered them.
nonisolated private final class NotificationTokens {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    func removeAll() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    deinit {
        removeAll()
    }
}
