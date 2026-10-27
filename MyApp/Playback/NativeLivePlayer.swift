import Foundation
import AVFoundation
import CoreMedia

/// Plays a stream engine session's native output without AVPlayer: the engine's samples go straight
/// to a video renderer (the display layer's) and an audio renderer, kept in step by one
/// synchronizer whose clock the `NativePlaybackScheduler` runs.
///
/// AVPlayer needs several seconds of programme in a playlist before it starts a live stream; this
/// shows the first keyframe as soon as the engine has cut it, and starts the clock once a second of
/// programme is in hand. Everything runs on the renderers' serial queue; events go to `onEvent`.
nonisolated final class NativeLivePlayer: @unchecked Sendable {
    nonisolated enum Event: Sendable {
        /// The first picture is on screen.
        case pictureShown
        /// Radio: the sound has started.
        case audioStarted
        /// Waiting on programme (true), or playing again (false).
        case waiting(Bool)
        /// The picture's display size, codec and frame rate, once its format is known.
        case videoFormat(width: Double, height: Double, codec: String, frameRate: Double?)
        /// The renderers can't go on: flush and re-feed from a keyframe, or give up on the stream.
        case rendererFailed(String)
        /// The renderers need everything again from a keyframe (after the app was in the background,
        /// or the audio output changed).
        case restartNeeded
    }

    private let displayLayer: AVSampleBufferDisplayLayer
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let feed: NativeFeed
    private let queue: DispatchQueue
    /// Where the picture is, for the engine: programme time, waiting, playing, rate.
    private let reportPlayback: @Sendable (Double?, Bool, Bool, Double) -> Void
    private let emit: @Sendable (Event) -> Void

    // Queue-confined.
    private var scheduler: NativePlaybackScheduler
    private var timer: DispatchSourceTimer?
    private var videoDescriptions: [Int: CMFormatDescription] = [:]
    private var audioDescriptions: [NativePlaybackScheduler.AudioFormatKey: CMFormatDescription] = [:]
    private var announcedSize: (width: Double, height: Double)?
    private var announcedAudioStart = false
    private var announcedPicture = false
    /// When the video renderer was first seen rendering, should the layer never say it's ready.
    private var renderingSince: Double?
    private var wasWaiting = false
    private var reportedFailure = false
    private var restartPending = false
    private var lastReport: Double = -1
    private var stopped = false
    private var flushObserver: NSObjectProtocol?

    init(feed: NativeFeed, renderers: NativeRenderers, preferredAudioLanguage: String?,
         reportPlayback: @escaping @Sendable (Double?, Bool, Bool, Double) -> Void,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.feed = feed
        displayLayer = renderers.displayLayer
        videoRenderer = renderers.videoRenderer
        audioRenderer = renderers.audioRenderer
        synchronizer = renderers.synchronizer
        queue = renderers.queue
        self.scheduler = NativePlaybackScheduler(preferredLanguage: preferredAudioLanguage)
        self.reportPlayback = reportPlayback
        self.emit = onEvent
    }

    // MARK: - Control (any thread)

    func start() {
        queue.async { [self] in
            guard !stopped, timer == nil else { return }
            // A new audio output (headphones, AirPlay, a call ending) makes the renderer drop what it
            // holds: everything is handed over again from the keyframe before the picture.
            flushObserver = NotificationCenter.default.addObserver(
                forName: AVSampleBufferAudioRenderer.wasFlushedAutomaticallyNotification, object: audioRenderer, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                queue.async { self.requestRestart() }
            }
            feed.setListener { [weak self] in
                guard let self else { return }
                queue.async { self.drainFeed() }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        feed.setListener(nil)
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            timer?.cancel()
            timer = nil
            if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
            flushObserver = nil
            synchronizer.rate = 0
            // The renderers outlive this player: the next channel mustn't open on this one's picture.
            videoRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            audioRenderer.flush()
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in perform(scheduler.setPaused(paused)) }
    }

    /// The engine's pace (pitch-corrected).
    func setRate(_ rate: Double) {
        queue.async { [self] in perform(scheduler.setTargetRate(rate)) }
    }

    func setMuted(_ muted: Bool) {
        queue.async { [self] in audioRenderer.isMuted = muted }
    }

    // MARK: - Feeding

    private func drainFeed() {
        guard !stopped else { return }
        let items = feed.drain()
        if items.contains(where: { if case .restart = $0 { return true } else { return false } }) {
            restartPending = false
            reportedFailure = false
        }
        perform(scheduler.receive(items))
        enqueue()
    }

    /// Hands the renderers whatever they will take.
    private func enqueue() {
        while videoRenderer.isReadyForMoreMediaData, let next = scheduler.nextVideo() {
            // The first picture: the clock is set to it (still) before it's queued.
            perform(next.commands)
            guard let buffer = videoBuffer(next.entry) else { continue }
            videoRenderer.enqueue(buffer)
        }
        while audioRenderer.isReadyForMoreMediaData, let next = scheduler.nextAudio() {
            guard let buffer = audioBuffer(next) else { continue }
            audioRenderer.enqueue(buffer)
        }
    }

    private func tick() {
        guard !stopped else { return }
        checkRenderers()
        enqueue()
        let clock = synchronizer.currentTime().seconds
        perform(scheduler.update(clockTime: clock))

        let now = ProcessInfo.processInfo.systemUptime
        if !announcedPicture, scheduler.hasVideo, scheduler.hasShownPicture {
            if videoRenderer.status == .rendering { renderingSince = renderingSince ?? now }
            if displayLayer.isReadyForDisplay || now - (renderingSince ?? now) >= 0.5 {
                announcedPicture = true
                emit(.pictureShown)
            }
        }
        if !announcedAudioStart, !scheduler.hasVideo, scheduler.isPlaying {
            announcedAudioStart = true
            emit(.audioStarted)
        }
        if scheduler.isWaiting != wasWaiting {
            wasWaiting = scheduler.isWaiting
            emit(.waiting(wasWaiting))
        }
        if now - lastReport >= 0.25 {
            lastReport = now
            let programmeTime = scheduler.hasShownPicture ? scheduler.programmeTime(at: clock) : nil
            reportPlayback(programmeTime, scheduler.isWaiting, scheduler.isPlaying, Double(synchronizer.rate))
        }
    }

    private func checkRenderers() {
        if !reportedFailure, videoRenderer.status == .failed || audioRenderer.status == .failed {
            reportedFailure = true
            let error = (videoRenderer.error ?? audioRenderer.error) as NSError?
            emit(.rendererFailed(error.map { "\($0.domain) \($0.code)" } ?? "renderer failed"))
            return
        }
        // Back from the background, the video decoder starts over from a keyframe.
        if videoRenderer.requiresFlushToResumeDecoding { requestRestart() }
    }

    private func requestRestart() {
        guard !restartPending, !stopped else { return }
        restartPending = true
        emit(.restartNeeded)
    }

    private func perform(_ commands: [NativePlaybackScheduler.Command]) {
        for command in commands {
            switch command {
            case .flush:
                videoRenderer.flush()
                audioRenderer.flush()
            case .setClock(let time, let rate):
                synchronizer.setRate(Float(rate), time: CMTime(seconds: time, preferredTimescale: NativeVideoTrack.timescale))
            case .setRate(let rate):
                synchronizer.rate = Float(rate)
            }
        }
    }

    // MARK: - Sample buffers

    private func videoBuffer(_ entry: NativePlaybackScheduler.VideoEntry) -> CMSampleBuffer? {
        let sample = entry.sample
        guard let description = videoDescription(entry.formatNumber, frameDuration: sample.duration) else { return nil }
        let timescale = NativeVideoTrack.timescale
        return Self.sampleBuffer(sample.data, format: description,
                                 timing: CMSampleTimingInfo(duration: CMTime(value: sample.duration, timescale: timescale),
                                                            presentationTimeStamp: CMTime(value: sample.presentationTime, timescale: timescale),
                                                            decodeTimeStamp: CMTime(value: sample.decodeTime, timescale: timescale)),
                                 notSync: !sample.isSync)
    }

    private func audioBuffer(_ entry: NativePlaybackScheduler.AudioEntry) -> CMSampleBuffer? {
        guard let description = audioDescription(entry.formatKey),
              let format = scheduler.audioFormats[entry.formatKey]?.format else { return nil }
        let timescale = Int32(format.sampleRate)
        let sample = entry.sample
        return Self.sampleBuffer(sample.data, format: description,
                                 timing: CMSampleTimingInfo(duration: CMTime(value: sample.duration, timescale: timescale),
                                                            presentationTimeStamp: CMTime(value: sample.decodeTime, timescale: timescale),
                                                            decodeTimeStamp: .invalid),
                                 notSync: false)
    }

    private func videoDescription(_ number: Int, frameDuration: Int64) -> CMFormatDescription? {
        if let cached = videoDescriptions[number] { return cached }
        guard let format = scheduler.videoFormats[number] else { return nil }
        guard let description = Self.videoFormatDescription(format) else {
            if !reportedFailure {
                reportedFailure = true
                emit(.rendererFailed("unsupported \(format.codecString) parameter sets"))
            }
            return nil
        }
        videoDescriptions[number] = description
        if videoDescriptions.count > 8, let oldest = videoDescriptions.keys.min() { videoDescriptions.removeValue(forKey: oldest) }
        let size = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true, useCleanAperture: true)
        if size.width > 0, size.height > 0, announcedSize.map({ $0.width != Double(size.width) || $0.height != Double(size.height) }) ?? true {
            announcedSize = (Double(size.width), Double(size.height))
            let frameRate = frameDuration > 0 ? Double(NativeVideoTrack.timescale) / Double(frameDuration) : nil
            emit(.videoFormat(width: Double(size.width), height: Double(size.height),
                              codec: format.codec == .hevc ? "HEVC" : "H.264", frameRate: frameRate))
        }
        return description
    }

    private func audioDescription(_ key: NativePlaybackScheduler.AudioFormatKey) -> CMFormatDescription? {
        if let cached = audioDescriptions[key] { return cached }
        guard let format = scheduler.audioFormats[key], let description = Self.audioFormatDescription(format) else { return nil }
        audioDescriptions[key] = description
        return description
    }

    /// One access unit as a ready sample buffer; `notSync` marks pictures the decoder can't start from.
    private static func sampleBuffer(_ data: Data, format: CMFormatDescription, timing: CMSampleTimingInfo,
                                     notSync: Bool) -> CMSampleBuffer? {
        let length = data.count
        guard length > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = data.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = timing
        var size = length
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr,
              let buffer else { return nil }
        if notSync, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }

    /// The decoder's description of a picture format, from its parameter sets. HLG sent as BT.2020 SDR
    /// with an alternative-transfer SEI is described as HLG, as the engine reads it.
    private static func videoFormatDescription(_ format: NativeVideoFormat) -> CMFormatDescription? {
        guard !format.parameterSets.isEmpty else { return nil }
        let buffers = format.parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, set.count))
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = format.parameterSets.map(\.count)
        var description: CMFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointerList in
            sizes.withUnsafeBufferPointer { sizeList -> OSStatus in
                guard let pointerBase = pointerList.baseAddress, let sizeBase = sizeList.baseAddress else { return -1 }
                switch format.codec {
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: pointerList.count, parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
                case .hevc:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: pointerList.count, parameterSetPointers: pointerBase,
                        parameterSetSizes: sizeBase, nalUnitHeaderLength: 4, extensions: colourExtensions(format.colour),
                        formatDescriptionOut: &description)
                }
            }
        }
        return status == noErr ? description : nil
    }

    private static func colourExtensions(_ colour: ColourDescription?) -> CFDictionary? {
        guard let colour else { return nil }
        var extensions: [CFString: CFString] = [:]
        switch colour.primaries {
        case 1: extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
        case 9: extensions[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
        default: break
        }
        switch colour.transfer {
        case 1: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_709_2
        case 16: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        case 18: extensions[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        default: break
        }
        switch colour.matrix {
        case 1: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        case 9: extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
        default: break
        }
        return extensions.isEmpty ? nil : extensions as CFDictionary
    }

    /// AAC with its ES descriptor as the decoder's cookie; AC-3 and E-AC-3 frames describe themselves.
    private static func audioFormatDescription(_ audio: NativePlaybackScheduler.AudioFormat) -> CMFormatDescription? {
        let format = audio.format
        var description = AudioStreamBasicDescription()
        description.mSampleRate = Float64(format.sampleRate)
        description.mChannelsPerFrame = UInt32(format.channelCount)
        description.mFramesPerPacket = UInt32(format.samplesPerFrame)
        switch format.codec {
        case .aac: description.mFormatID = format.samplesPerFrame == 2_048 ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC
        case .ac3: description.mFormatID = kAudioFormatAC3
        case .eac3: description.mFormatID = kAudioFormatEnhancedAC3
        }
        let cookie = audio.magicCookie ?? []
        var formatDescription: CMFormatDescription?
        let status = cookie.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: cookie.isEmpty ? nil : bytes.baseAddress,
                                           extensions: nil, formatDescriptionOut: &formatDescription)
        }
        return status == noErr ? formatDescription : nil
    }
}

/// The renderers a controller's native players use, one after another: the picture's layer and its
/// video renderer, an audio renderer, and the synchronizer whose clock keeps them together. Keeping
/// them across channels keeps one layer on screen (and in picture in picture), and their one queue
/// puts each player's last use of them before the next player's first.
nonisolated final class NativeRenderers: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    let videoRenderer: AVSampleBufferVideoRenderer
    let audioRenderer = AVSampleBufferAudioRenderer()
    let synchronizer = AVSampleBufferRenderSynchronizer()
    let queue = DispatchQueue(label: "BannerTV.NativeRenderers", qos: .userInteractive)

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        videoRenderer = displayLayer.sampleBufferRenderer
        audioRenderer.audioTimePitchAlgorithm = .timeDomain
        // The scheduler decides when there's enough to run on.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
    }
}
