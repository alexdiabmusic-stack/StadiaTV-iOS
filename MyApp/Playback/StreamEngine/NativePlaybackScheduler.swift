import Foundation

/// The native renderer's decisions, kept apart from AVFoundation so they can be tested anywhere:
/// what to queue for the video and audio renderers, and when their shared clock runs.
///
/// The first picture shows as soon as the first keyframe is queued: the clock is set to it, still.
/// It starts running once a second of programme is in hand, stops (holding the picture) when it
/// catches up with what has arrived, and runs again when a second has arrived. The engine decides
/// how much to hand over, so these thresholds are deliberately short. A restart drops everything
/// queued and carries on at a given moment, decoding from the keyframe before it.
nonisolated struct NativePlaybackScheduler {
    nonisolated enum Command: Equatable, Sendable {
        /// Drop everything the renderers hold.
        case flush
        /// Put the clock at `time` (seconds on the output timeline), running at `rate`.
        case setClock(time: Double, rate: Double)
        case setRate(Double)
    }

    nonisolated enum Phase: Equatable, Sendable {
        /// Nothing shown yet (or restarting).
        case starting
        /// A picture is showing, the clock is still.
        case primed
        case playing
        /// Ran out of programme: the picture holds until more arrives.
        case stalled
    }

    nonisolated struct VideoEntry: Sendable {
        var sample: NativeSample
        var formatNumber: Int
    }

    nonisolated struct AudioEntry: Sendable {
        var sample: NativeSample
        /// Identifies the format: rendition and format number.
        var formatKey: AudioFormatKey
    }

    nonisolated struct AudioFormatKey: Hashable, Sendable {
        var rendition: Int
        var formatNumber: Int
    }

    nonisolated struct AudioFormat: Sendable {
        var format: AudioTrackFormat
        var magicCookie: [UInt8]?
    }

    /// Programme in hand before the clock runs, at the start and after running dry.
    static let startLead = 1.0
    static let resumeLead = 1.0
    /// The clock counts as having caught up within this of the end of what arrived.
    private static let stallMargin = 0.05
    private static let audioLagLimit = 3.0

    private(set) var phase: Phase = .starting
    private(set) var videoFormats: [Int: NativeVideoFormat] = [:]
    private(set) var audioFormats: [AudioFormatKey: AudioFormat] = [:]
    /// The audio track played: the preferred language's, else the first.
    private(set) var selectedRendition: Int?
    private(set) var hasVideo = false
    private(set) var hasAudio = false
    /// The playback rate the engine asks for (pace control).
    private(set) var targetRate = 1.0
    private(set) var isPaused = false

    private let preferredLanguage: String?
    private var videoQueue: [VideoEntry] = []
    private var videoHead = 0
    private var audioQueue: [AudioEntry] = []
    private var audioHead = 0
    /// Ends of the programme received (presentation times, seconds).
    private var videoEnd: Double?
    private var audioEnd: Double?
    /// Segment starts on the output timeline and in programme time, for reporting the playhead.
    private var timeline: [(timeline: Double, programme: Double)] = []
    /// A restart's programme time, until the segment it lands in arrives.
    private var restartProgrammeTime: Double?
    /// Where the clock starts (or restarts), on the output timeline; audio before it is never heard.
    private var startTime: Double?

    init(preferredLanguage: String? = nil) {
        self.preferredLanguage = preferredLanguage
    }

    // MARK: - Input

    mutating func receive(_ items: [NativeFeed.Item]) -> [Command] {
        var commands: [Command] = []
        for item in items {
            switch item {
            case .restart(let programmeTime):
                videoQueue.removeAll()
                videoHead = 0
                audioQueue.removeAll()
                audioHead = 0
                videoEnd = nil
                audioEnd = nil
                restartProgrammeTime = programmeTime
                startTime = nil
                phase = .starting
                commands.append(.flush)
            case .segment(let segment):
                append(segment)
            }
        }
        return commands
    }

    private mutating func append(_ segment: NativeFeed.Segment) {
        let samples = segment.samples
        timeline.append((samples.timelineStart, segment.programmeStart))
        if timeline.count > 256 { timeline.removeFirst(timeline.count - 256) }
        if let programmeTime = restartProgrammeTime {
            restartProgrammeTime = nil
            startTime = samples.timelineStart + max(0, programmeTime - segment.programmeStart)
        }
        if let video = samples.video {
            hasVideo = true
            videoFormats[video.formatNumber] = video.format
            if videoFormats.count > 8, let oldest = videoFormats.keys.min() { videoFormats.removeValue(forKey: oldest) }
            for sample in video.samples {
                // The first picture after a start or restart must be one the decoder can begin from.
                if videoHead == videoQueue.count, phase == .starting, videoEnd == nil, !sample.isSync { continue }
                if startTime == nil { startTime = Self.seconds(sample.presentationTime, NativeVideoTrack.timescale) }
                videoQueue.append(VideoEntry(sample: sample, formatNumber: video.formatNumber))
                let end = Self.seconds(sample.presentationTime + sample.duration, NativeVideoTrack.timescale)
                videoEnd = max(videoEnd ?? end, end)
            }
        }
        if !samples.audio.isEmpty {
            hasAudio = true
            if selectedRendition == nil || !samples.audio.contains(where: { $0.rendition == selectedRendition }) {
                let preferred = samples.audio.first { track in preferredLanguage.map { Self.language(track.language, matches: $0) } ?? false }
                selectedRendition = (preferred ?? samples.audio[0]).rendition
            }
            if let track = samples.audio.first(where: { $0.rendition == selectedRendition }) {
                let key = AudioFormatKey(rendition: track.rendition, formatNumber: track.formatNumber)
                audioFormats[key] = AudioFormat(format: track.format, magicCookie: track.magicCookie)
                let timescale = Int32(track.format.sampleRate)
                for sample in track.samples {
                    let end = Self.seconds(sample.decodeTime + sample.duration, timescale)
                    if let startTime, end <= startTime { continue }
                    audioQueue.append(AudioEntry(sample: sample, formatKey: key))
                    audioEnd = max(audioEnd ?? end, end)
                }
            }
        }
        compact()
    }

    private mutating func compact() {
        if videoHead > 512 {
            videoQueue.removeFirst(videoHead)
            videoHead = 0
        }
        if audioHead > 512 {
            audioQueue.removeFirst(audioHead)
            audioHead = 0
        }
    }

    // MARK: - Queueing

    /// The next video sample for the renderer, and the clock command its arrival calls for.
    mutating func nextVideo() -> (entry: VideoEntry, commands: [Command])? {
        guard videoHead < videoQueue.count else { return nil }
        let entry = videoQueue[videoHead]
        videoHead += 1
        var commands: [Command] = []
        if phase == .starting {
            // Show it at once, still: the picture appears before the clock has anything to run on.
            let time = startTime ?? Self.seconds(entry.sample.presentationTime, NativeVideoTrack.timescale)
            phase = .primed
            commands.append(.setClock(time: time, rate: 0))
        }
        return (entry, commands)
    }

    mutating func nextAudio() -> AudioEntry? {
        guard audioHead < audioQueue.count else { return nil }
        defer { audioHead += 1 }
        return audioQueue[audioHead]
    }

    var hasPendingVideo: Bool { videoHead < videoQueue.count }
    var hasPendingAudio: Bool { audioHead < audioQueue.count }

    // MARK: - Clock

    /// Where programme received so far ends: what both tracks have, when there are both. Audio that
    /// stops arriving doesn't hold the picture: a few seconds behind the video, it's left out.
    var availableEnd: Double? {
        switch (hasVideo ? videoEnd : nil, hasAudio ? audioEnd : nil) {
        case (let video?, let audio?): return video - audio > Self.audioLagLimit ? video : min(video, audio)
        case (let video?, nil): return hasAudio ? nil : video
        case (nil, let audio?): return hasVideo ? nil : audio
        case (nil, nil): return nil
        }
    }

    /// Called regularly with the clock's time: starts, stops and restarts it.
    mutating func update(clockTime: Double) -> [Command] {
        var commands: [Command] = []
        if phase == .starting, !hasVideo, hasAudio, let start = startTime ?? audioStart {
            // Radio: no picture to show first.
            phase = .primed
            commands.append(.setClock(time: start, rate: 0))
            return commands
        }
        guard let end = availableEnd else { return commands }
        let ahead = end - clockTime
        switch phase {
        case .starting:
            break
        case .primed:
            if ahead >= Self.startLead {
                phase = .playing
                if !isPaused { commands.append(.setRate(targetRate)) }
            }
        case .playing:
            if ahead <= Self.stallMargin, !isPaused {
                phase = .stalled
                commands.append(.setRate(0))
            }
        case .stalled:
            if ahead >= Self.resumeLead {
                phase = .playing
                if !isPaused { commands.append(.setRate(targetRate)) }
            }
        }
        return commands
    }

    private var audioStart: Double? {
        guard audioHead < audioQueue.count, let format = audioFormats[audioQueue[audioHead].formatKey] else { return nil }
        return Self.seconds(audioQueue[audioHead].sample.decodeTime, Int32(format.format.sampleRate))
    }

    mutating func setPaused(_ paused: Bool) -> [Command] {
        guard paused != isPaused else { return [] }
        isPaused = paused
        guard phase == .playing else { return [] }
        return [.setRate(paused ? 0 : targetRate)]
    }

    mutating func setTargetRate(_ rate: Double) -> [Command] {
        guard rate != targetRate else { return [] }
        targetRate = rate
        return phase == .playing && !isPaused ? [.setRate(rate)] : []
    }

    /// The viewer is waiting on programme, not on a pause or the start.
    var isWaiting: Bool { phase == .stalled && !isPaused }
    var isPlaying: Bool { phase == .playing && !isPaused }
    var hasShownPicture: Bool { phase != .starting }

    /// Programme time of a moment on the output timeline.
    func programmeTime(at clockTime: Double) -> Double? {
        guard let entry = timeline.last(where: { $0.timeline <= clockTime + 0.000_1 }) ?? timeline.first else { return nil }
        return entry.programme + (clockTime - entry.timeline)
    }

    /// Whether a track's language (ISO 639-2, as broadcast) is the one asked for: a tag such as
    /// "en" or "en-GB", or a code like the track's own.
    static func language(_ trackLanguage: String, matches preferred: String) -> Bool {
        func primary(_ code: String) -> String {
            let primary = code.lowercased().split(separator: "-").first.map(String.init) ?? ""
            return primary.count == 3 ? StreamEngineSession.languageTag(primary) : primary
        }
        let wanted = primary(preferred)
        return !wanted.isEmpty && wanted != "und" && primary(trackLanguage) == wanted
    }

    static func seconds(_ value: Int64, _ timescale: Int32) -> Double {
        Double(value) / Double(timescale)
    }
}
