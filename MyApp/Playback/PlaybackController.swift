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
/// Responsibilities:
/// - start-up tuning (buffer profile, first eligible variant, play immediately when ready)
/// - start-up watchdog and fallback URLs (e.g. an Xtream `.ts` URL tried as `.m3u8` first)
/// - stall recovery: reconnect with backoff, then report failure so Auto can fail over
/// - detecting video streams that play with no picture (only when the manifest advertises video)
/// - audio-session interruptions, headphone unplug, foreground return and live-edge tracking
@MainActor
final class PlaybackController: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
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
    /// What the player's log, the converter and the provider say about why the last stream failed, once known. Shown
    /// under the failure message; nil while a stream is loading or playing.
    @Published private(set) var failureDetail: String?

    let player = AVPlayer()
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
    /// Called once per channel when the first frame renders, with time-to-first-frame in ms.
    var onFirstFrame: ((Channel, Int?) -> Void)?
    /// Called when a new item becomes ready, e.g. to read its audio/subtitle groups.
    var onItemReady: ((AVPlayerItem) -> Void)?
    var onMetadata: ((StreamRuntimeMetadata) -> Void)?

    private var metrics: PlaybackMetrics?
    private var pendingTapDate: Date?
    private var hasLoadedOnce = false
    /// The ways of playing the current channel, in order, and which one is being tried.
    private var candidates: [PlaybackCandidate] = []
    private var candidateIndex = 0
    /// The converter serving the current candidate when it is a transport stream.
    private var proxy: TransportStreamProxy?
    private let formatMemory = PlaybackFormatMemory()
    /// When the current channel last needed a reconnect; see `PlaybackPolicy.reconnectBudgetSpent`.
    private var recentReconnects: [Date] = []
    /// Why the last attempts to play this channel failed, for the failure panel: a way that didn't start, or the
    /// reason a stream was lost, which the generic "lost connection" message would otherwise hide.
    private var attemptNotes: [String] = []
    /// Bumped whenever the current item is replaced; async work from older items checks it and bails.
    private var generation = 0
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
    private var firstFrameDeadlineTask: Task<Void, Never>?
    private var candidateDeadlineTask: Task<Void, Never>?
    private var diagnosisTask: Task<Void, Never>?

    init(tapDate: Date? = nil, bufferProfile: PlayerBufferProfile = .balanced) {
        self.pendingTapDate = tapDate
        self.bufferProfile = bufferProfile
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        PlaybackItemFactory.apply(bufferProfile, to: player)
        observePlayer()
        observeSystemEvents()
    }

    // MARK: - Public API

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
    func load(_ channel: Channel, audioOnly: Bool = false) {
        isAudioOnlySession = audioOnly
        let now = Date()
        let tapDate = pendingTapDate ?? now
        pendingTapDate = nil

        cancelTasks()
        detachItemObservers()
        stopProxy()
        self.channel = channel
        candidates = PlaybackCandidates.candidates(
            for: channel.streamURL, prefersTransportStream: formatMemory.prefersTransportStream(for: channel.streamURL)
        )
        candidateIndex = 0
        reconnectAttempt = 0
        recentReconnects.removeAll()
        attemptNotes.removeAll()
        failureDetail = nil
        availableHeights = []
        firstFrameRendered = false
        isUserPaused = false
        isBehindLiveEdge = false
        pausedAt = nil
        setBuffering(false)

        var metrics = PlaybackMetrics(tapDate: tapDate, url: channel.streamURL)
        if !hasLoadedOnce { metrics.record(.playerAppeared, at: now) }
        self.metrics = metrics
        hasLoadedOnce = true

        guard channel.streamURL.scheme?.lowercased() != "about" else {
            // What was playing before says nothing about why this channel has no stream.
            currentItem = nil
            fail("No stream is available for this channel.")
            return
        }

        if audioOnly { AudioSessionManager.activateForAudioOnly() } else { AudioSessionManager.activateForVideo() }
        NotificationCenter.default.post(name: .bannerVideoPlaybackWillStart, object: nil)
        setHoldsPlaybackPriority(true)
        startCurrentURL()
        startFirstFrameDeadline()
    }

    func play() {
        isUserPaused = false
        if let pausedAt, Date().timeIntervalSince(pausedAt) > Self.staleBufferInterval {
            seekToLiveEdge()
        }
        pausedAt = nil
        resumePlayback()
        rearmStartTimersIfNeeded()
    }

    func pause() {
        isUserPaused = true
        pausedAt = Date()
        watchdogTask?.cancel()
        stallTask?.cancel()
        player.pause()
        if currentItem != nil { state = .paused }
        setBuffering(false)
    }

    func stop() {
        setHoldsPlaybackPriority(false)
        generation += 1
        cancelTasks()
        stopProxy()
        detachItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        channel = nil
        state = .idle
        failureDetail = nil
        attemptNotes.removeAll()
        recentReconnects.removeAll()
        setBuffering(false)
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
        isMuted = muted
    }

    func togglePlayPause() {
        if isUserPaused || player.timeControlStatus == .paused { play() } else { pause() }
    }

    /// Caps resolution and bitrate on the current (and future) items.
    func setQualityCap(_ cap: PlayerQualityCap) {
        qualityCap = cap
        peakBitRate = cap.peakBitRate
        currentItem?.preferredPeakBitRate = cap.peakBitRate
        currentItem?.preferredMaximumResolution = cap.maximumResolution
    }

    /// Applies a buffer profile to the live player and item immediately.
    func setBufferProfile(_ profile: PlayerBufferProfile) {
        bufferProfile = profile
        PlaybackItemFactory.apply(profile, to: player)
    }

    func setPreferredPeakBitRate(_ bitRate: Double) {
        peakBitRate = bitRate
        currentItem?.preferredPeakBitRate = bitRate
    }

    /// Jumps to the live point of a live stream.
    func seekToLiveEdge() {
        guard let item = currentItem, let range = item.seekableTimeRanges.last?.timeRangeValue else { return }
        let end = CMTimeRangeGetEnd(range)
        let offset = item.recommendedTimeOffsetFromLive
        let target = offset.isValid && offset.seconds > 0 ? CMTimeSubtract(end, offset) : end
        player.seek(to: target)
        isBehindLiveEdge = false
    }

    /// Called by the video surface when its AVPlayerLayer has a frame to show.
    func surfaceReadyForDisplay() {
        markFirstFrame()
    }

    // MARK: - Item lifecycle

    private func startCurrentURL() {
        guard let channel, candidates.indices.contains(candidateIndex) else { return }
        generation += 1
        let generation = generation
        detachItemObservers()
        watchdogTask?.cancel()
        monitorTask?.cancel()
        candidateDeadlineTask?.cancel()
        // A stall timer from the item being replaced mustn't stand in the way of the new item's own.
        stallTask?.cancel()
        stallTask = nil
        stopProxy()
        itemHasPlayed = false
        didNotifyItemReady = false

        let candidate = candidates[candidateIndex]
        var url = candidate.url
        var headers = channel.httpHeaders
        if candidate.source == .convertedTransportStream {
            // Apple's player can't open a transport stream, so it is turned into HLS here and the player is given
            // the local copy. The provider's headers go to the provider, not to the player.
            let converter = TransportStreamProxy(upstream: candidate.url, headers: channel.httpHeaders)
            let identity = ObjectIdentifier(converter)
            converter.onFailure { [weak self] reason in
                Task { @MainActor [weak self] in self?.converterFailed(reason, identity: identity) }
            }
            do {
                url = try converter.start()
                headers = nil
                proxy = converter
            } catch {
                startupFailed("Couldn't start the stream converter.")
                return
            }
        }
        let item = PlaybackItemFactory.makeItem(url: url, headers: headers,
                                                profile: bufferProfile, peakBitRate: peakBitRate)
        item.preferredMaximumResolution = qualityCap.maximumResolution
        attachObservers(to: item)
        currentItem = item
        if reconnectAttempt == 0 { state = .loading }
        metrics?.record(.itemCreated)
        publishMetrics()

        player.replaceCurrentItem(with: item)
        if !isUserPaused { player.play() }

        startWatchdog(generation: generation)
        startCandidateDeadline(generation: generation)
        startMonitor(item: item, generation: generation)
    }

    /// The stream (or a fallback URL) couldn't start.
    private func startupFailed(_ reason: String) {
        if reconnectAttempt > 0 {
            reconnect(reason: reason)
        } else if candidateIndex + 1 < candidates.count {
            startNextCandidate(after: reason)
        } else {
            fail(reason)
        }
    }

    /// Gives up on the current way of playing the channel and starts the next.
    private func startNextCandidate(after reason: String) {
        noteFailedAttempt(reason)
        candidateIndex += 1
        reconnectAttempt = 0
        reconnectTask?.cancel()
        PlaybackMetrics.logger.info("Start-up failed (\(reason, privacy: .public)); trying fallback \(self.candidateIndex + 1)/\(self.candidates.count)")
        startCurrentURL()
    }

    /// Keeps what went wrong with the current way of playing the channel. For a stream the player opened itself its
    /// own error log says most; for a converted one the log is about the local copy, so the reason the converter
    /// gave is all there is.
    private func noteFailedAttempt(_ reason: String) {
        guard candidates.indices.contains(candidateIndex) else { return }
        let source = candidates[candidateIndex].source
        let logged = source == .direct ? loggedError() : nil
        let label = source == .direct ? "As HLS" : "As MPEG-TS"
        let note = PlaybackPolicy.combine(["\(label): \(reason)", logged], separator: " ") ?? label
        if !attemptNotes.contains(note) { attemptNotes.append(note) }
        if attemptNotes.count > 2 { attemptNotes.removeFirst() }
    }

    /// The latest entry in the current item's error log, worded for a person.
    private func loggedError() -> String? {
        guard let event = currentItem?.errorLog()?.events.last else { return nil }
        return PlaybackPolicy.describeLoggedError(statusCode: event.errorStatusCode, domain: event.errorDomain, comment: event.errorComment)
    }

    /// Rebuilds the item for the same URL after a mid-stream failure or long stall.
    private func reconnect(reason: String) {
        // A channel that has never shown a picture isn't being reconnected: this way of playing it isn't working, so
        // the next is tried rather than the same one again.
        if !firstFrameRendered, candidateIndex + 1 < candidates.count {
            startNextCandidate(after: reason)
            return
        }
        noteFailedAttempt(reason)
        let now = Date()
        recentReconnects = recentReconnects.filter { now.timeIntervalSince($0) < PlaybackPolicy.reconnectWindow }
        guard reconnectAttempt < Self.maxReconnectAttempts,
              !PlaybackPolicy.reconnectBudgetSpent(reconnects: recentReconnects, now: now) else {
            fail("Lost connection to the stream.")
            return
        }
        recentReconnects.append(now)
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
        // The converter's connection to the provider is let go now, not when the next one starts: an account often
        // allows one connection, and the new one would find the old still there.
        stopProxy()
        state = .buffering
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
        // What the player and the converter know is read before the item and the converter are let go.
        let known = describeFailure()
        setHoldsPlaybackPriority(false)
        generation += 1
        cancelTasks()
        stopProxy()
        detachItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        reconnectAttempt = 0
        setBuffering(false)
        state = .failed(reason)
        failureDetail = known
        metrics?.record(.failed, reason: reason)
        publishMetrics()
        if let channel {
            StreamHealthStore.shared.recordFailure(streamID: channel.id)
        }
        scheduleDiagnosis()
        onFailure?(reason)
    }

    /// The converter gave up on the provider's stream: it was refused, wasn't a stream, or kept dropping.
    private func converterFailed(_ reason: String, identity: ObjectIdentifier) {
        guard let proxy, ObjectIdentifier(proxy) == identity, currentItem != nil else { return }
        PlaybackMetrics.logger.info("Converter failed: \(reason, privacy: .public)")
        if itemHasPlayed { reconnect(reason: reason) } else { startupFailed(reason) }
    }

    private func stopProxy() {
        proxy?.stop()
        proxy = nil
    }

    /// What is known about why this stream is failing, other than the message itself: what went wrong with the ways
    /// of playing it that were tried first, then the player's own error log or how far the converter got.
    private func describeFailure() -> String? {
        var parts: [String?] = attemptNotes
        if candidates.indices.contains(candidateIndex), candidates[candidateIndex].source == .convertedTransportStream {
            if let proxy, proxy.failure == nil { parts.append(proxy.progress) }
        } else {
            parts.append(loggedError())
        }
        return PlaybackPolicy.combine(parts)
    }

    /// The converter's own reason when it has one, which says more than the player's.
    private func startFailureReason(_ fallback: String) -> String {
        proxy?.failure ?? fallback
    }

    /// Asks the provider what it actually sends for this channel's HLS address, once the failure has settled (Auto
    /// may start another source straight after `onFailure`), and adds what it finds to `failureDetail`.
    private func scheduleDiagnosis() {
        guard let hls = candidates.first(where: { $0.source == .direct }),
              ["http", "https"].contains(hls.url.scheme?.lowercased() ?? "") else { return }
        let failedGeneration = generation
        let headers = channel?.httpHeaders
        let triedConverting = candidates.contains { $0.source == .convertedTransportStream }
        diagnosisTask?.cancel()
        diagnosisTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.generation == failedGeneration, case .failed = self.state else { return }
            let report = await StreamProbe.run(url: hls.url, headers: headers)
            guard !Task.isCancelled, self.generation == failedGeneration, case let .failed(message) = self.state else { return }
            PlaybackMetrics.logger.info("Stream check: \(report.technical, privacy: .public)")
            // A raw transport stream is what the converter was given, and it has its own reason; telling the person
            // to ask the provider for HLS would be no help. Nor is saying again what the message already says.
            if report.verdict == .rawTransportStream, triedConverting { return }
            if report.summary == message || (self.failureDetail ?? "").contains(report.summary) { return }
            self.failureDetail = PlaybackPolicy.combine([self.failureDetail, report.summary])
        }
    }

    private func markFirstFrame() {
        guard !firstFrameRendered, currentItem != nil else { return }
        firstFrameRendered = true
        firstFrameDeadlineTask?.cancel()
        candidateDeadlineTask?.cancel()
        attemptNotes.removeAll()
        rememberWorkingFormat()
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
        guard currentItem != nil else { return }
        if !bufferProfile.waitsToMinimizeStalling, currentItem?.status == .readyToPlay {
            player.playImmediately(atRate: 1)
        } else {
            player.play()
        }
    }

    // MARK: - Watchdog & monitor

    /// Fails over when an item never starts playing within the profile's start-up window.
    private func startWatchdog(generation: Int) {
        watchdogTask?.cancel()
        guard candidates.indices.contains(candidateIndex) else { return }
        let timeout = PlaybackPolicy.startupLimit(for: candidates[candidateIndex].source, startupTimeout: bufferProfile.startupTimeout)
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, !Task.isCancelled, self.generation == generation,
                  !self.itemHasPlayed, !self.isUserPaused else { return }
            PlaybackMetrics.logger.info("No playback within \(timeout) s")
            self.startupFailed(self.startFailureReason("The stream didn't start in time."))
        }
    }

    /// While another way of playing the channel is waiting, this one gets a little longer than the start-up
    /// watchdog to show a picture. The watchdog stands down as soon as the player says `.playing`, which a stream
    /// that keeps stalling does again and again, and the next way would otherwise never be reached.
    private func startCandidateDeadline(generation: Int) {
        candidateDeadlineTask?.cancel()
        guard !firstFrameRendered, candidateIndex + 1 < candidates.count else { return }
        let seconds = PlaybackPolicy.candidateDeadline(for: candidates[candidateIndex].source, startupTimeout: bufferProfile.startupTimeout)
        candidateDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.generation == generation, !self.firstFrameRendered,
                  !self.isUserPaused, self.player.timeControlStatus != .paused else { return }
            PlaybackMetrics.logger.info("No picture within \(seconds) s; trying the next way of playing it")
            self.startupFailed(self.startFailureReason("The stream didn't start in time."))
        }
    }

    /// A last resort for a channel that never shows a picture, however the other timers are reset: the watchdog
    /// stands down when the player reports `.playing`, and a reconnect starts its count again, so a stream that
    /// keeps flapping between playing and waiting would otherwise show the loading screen for ever. Only the first
    /// frame, a failure or a new load stops this one.
    private func startFirstFrameDeadline() {
        firstFrameDeadlineTask?.cancel()
        guard !firstFrameRendered, currentItem != nil else { return }
        let seconds = PlaybackPolicy.firstFrameDeadline(startupTimeout: bufferProfile.startupTimeout, sources: candidates.map(\.source))
        firstFrameDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.firstFrameRendered, self.currentItem != nil,
                  !self.isUserPaused, self.player.timeControlStatus != .paused else { return }
            PlaybackMetrics.logger.info("No picture within \(seconds) s")
            self.fail(self.startFailureReason("The stream still hasn't started."))
        }
    }

    /// Pausing cancels the start-up timers; a resume before the first frame needs them back, or a stream that never
    /// starts would load for ever.
    private func rearmStartTimersIfNeeded() {
        guard currentItem != nil, !firstFrameRendered else { return }
        if !itemHasPlayed { startWatchdog(generation: generation) }
        startFirstFrameDeadline()
        startCandidateDeadline(generation: generation)
    }

    /// Which way of playing a provider's channels worked, so a provider whose HLS never started is tried as a
    /// transport stream first from then on, and HLS working again clears that.
    private func rememberWorkingFormat() {
        guard candidates.contains(where: { $0.source == .direct }),
              candidates.contains(where: { $0.source == .convertedTransportStream }),
              candidates.indices.contains(candidateIndex), let url = channel?.streamURL else { return }
        formatMemory.record(candidates[candidateIndex].source, for: url)
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
                    self.markFirstFrame()
                } else if isPlaying {
                    secondsPlayingWithoutPicture += 1
                } else {
                    secondsPlayingWithoutPicture = 0
                }

                // A picture-less stream is only broken if its manifest advertises video;
                // genuine audio-only channels (radio) are left alone and count as started.
                if secondsPlayingWithoutPicture >= 3, advertisesVideo == nil {
                    // A converted stream's playlist lists segments, not variants, so what the converter read from
                    // the stream's own program table says whether it carries video.
                    let result: Bool
                    if let proxy = self.proxy {
                        result = proxy.carriesVideo ?? false
                    } else {
                        result = await Self.manifestAdvertisesVideo(item)
                    }
                    guard !Task.isCancelled, self.generation == generation else { return }
                    advertisesVideo = result
                    if !result { self.markFirstFrame() }
                }
                if advertisesVideo == true, secondsPlayingWithoutPicture >= Self.videolessFailureSeconds {
                    PlaybackMetrics.logger.info("Playing \(secondsPlayingWithoutPicture) s with no picture on a video stream")
                    // Another way of playing the channel may do better; with none left this fails as it always has.
                    self.startupFailed("This source is playing without a picture.")
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

                self.updateLiveEdgeDistance(for: item)
            }
        }
    }

    private static func manifestAdvertisesVideo(_ item: AVPlayerItem) async -> Bool {
        guard let asset = item.asset as? AVURLAsset,
              let variants = try? await asset.load(.variants) else { return false }
        return variants.contains { $0.videoAttributes != nil }
    }

    private func updateLiveEdgeDistance(for item: AVPlayerItem) {
        guard let range = item.seekableTimeRanges.last?.timeRangeValue,
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
    }

    private func timeControlStatusChanged() {
        guard currentItem != nil else { return }
        switch player.timeControlStatus {
        case .playing:
            itemHasPlayed = true
            stallTask?.cancel()
            watchdogTask?.cancel()
            if reconnectAttempt > 0 {
                PlaybackMetrics.logger.info("Reconnected after \(self.reconnectAttempt) attempt(s)")
                reconnectAttempt = 0
                attemptNotes.removeAll()
            }
            state = .playing
            setBuffering(false)
        case .waitingToPlayAtSpecifiedRate:
            guard !isUserPaused else { return }
            if itemHasPlayed {
                state = .buffering
                startStallTimer()
            }
            setBuffering(true)
        case .paused:
            if isUserPaused { state = .paused }
            setBuffering(false)
        @unknown default:
            break
        }
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
        itemObservations = [
            item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.itemStatusChanged() }
            }
        ]
        let center = NotificationCenter.default
        itemTokens.add(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated { self?.itemFailedMidStream(message) }
        })
        itemTokens.add(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemStalled() }
        })
        itemTokens.add(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logLatestErrorLogEntry() }
        })
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
                onItemReady?(item)
                loadAvailableHeights(for: item)
            }
        case .failed:
            let reason = startFailureReason(item.error?.localizedDescription ?? "Couldn't play this stream.")
            if itemHasPlayed {
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
        reconnect(reason: message ?? "failed to play to end")
    }

    private func itemStalled() {
        metrics?.record(.firstStall)
        publishMetrics()
        guard itemHasPlayed, !isUserPaused else { return }
        state = .buffering
        setBuffering(true)
        startStallTimer()
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
                   self?.currentItem != nil, self?.isUserPaused == false {
                    self?.pause()
                }
            }
        })
        #endif
        #if canImport(UIKit)
        systemTokens.add(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundedAt = Date() }
        })
        systemTokens.add(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnedToForeground() }
        })
        #endif
    }

    #if os(iOS) || os(tvOS)
    private func handleInterruption(rawType: UInt?, rawOptions: UInt) {
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType), currentItem != nil else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = !isUserPaused && player.timeControlStatus != .paused
            player.pause()
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
                rearmStartTimersIfNeeded()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }
    #endif

    private func returnedToForeground() {
        defer { backgroundedAt = nil }
        guard currentItem != nil, !isUserPaused, player.rate == 0 else { return }
        if let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > Self.staleBufferInterval {
            seekToLiveEdge()
        }
        resumePlayback()
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
        firstFrameDeadlineTask?.cancel()
        candidateDeadlineTask?.cancel()
        diagnosisTask?.cancel()
    }

    private func publishMetrics() {
        #if DEBUG
        metricsSummary = metrics?.summary
        #endif
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
