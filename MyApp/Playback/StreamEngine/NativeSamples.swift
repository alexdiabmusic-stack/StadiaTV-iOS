import Foundation

/// The engine's output for the app's own renderer: decodable samples instead of HLS segments.
///
/// AVPlayer only starts a live stream once its playlist holds several seconds, and it can only be
/// fed through a playlist. The native renderer takes samples as they are cut, so the first picture
/// can show as soon as the first keyframe's segment is complete. Video samples are in MP4 form
/// (length-prefixed NAL units, parameter sets in the format instead); audio samples are raw codec
/// frames. Every timestamp is on the splicer's continuous output timeline.
nonisolated struct NativeSamples: Sendable {
    /// Output-timeline time of the segment's start, in seconds; the segment's `programmeStart` is
    /// the same moment in programme time.
    var timelineStart: Double
    var video: NativeVideoTrack?
    var audio: [NativeAudioTrack]

    var byteCount: Int {
        (video?.samples.reduce(0) { $0 + $1.data.count } ?? 0) + audio.reduce(0) { total, track in
            total + track.samples.reduce(0) { $0 + $1.data.count }
        }
    }
}

/// One access unit.
nonisolated struct NativeSample: Sendable {
    var data: Data
    /// Decode time and duration in the track's timescale.
    var decodeTime: Int64
    var duration: Int64
    /// Presentation time minus decode time (video).
    var compositionOffset: Int64 = 0
    /// A keyframe the decoder can start from.
    var isSync: Bool

    var presentationTime: Int64 { decodeTime + compositionOffset }
}

nonisolated struct NativeVideoTrack: Sendable {
    /// Changes whenever the picture format does: the renderer then needs a new format description.
    var formatNumber: Int
    var format: NativeVideoFormat
    /// 90 kHz.
    var samples: [NativeSample]

    static let timescale: Int32 = 90_000
}

nonisolated struct NativeVideoFormat: Equatable, Sendable {
    var codec: VideoTrackFormat.Codec
    /// VPS (HEVC), SPS and PPS NAL units in that order, without start codes.
    var parameterSets: [[UInt8]]
    var width: Int
    var height: Int
    var colour: ColourDescription?
    var codecString: String
}

nonisolated struct NativeAudioTrack: Sendable {
    /// The audio stream's position in the program.
    var rendition: Int
    /// ISO 639-2 code from the PMT, or "und".
    var language: String
    var formatNumber: Int
    var format: AudioTrackFormat
    /// What the decoder needs besides the frames: the MPEG-4 ES descriptor for AAC; AC-3 and
    /// E-AC-3 frames describe themselves.
    var magicCookie: [UInt8]?
    /// Timescale: the format's sample rate.
    var samples: [NativeSample]
}

/// Published segments on their way from the session to the renderer, in order.
///
/// The session pushes on its queue; the renderer drains on its own. A restart asks the renderer to
/// drop what it has queued and carry on from the segments that follow it (after a decoder reset,
/// or a jump to the newest programme).
nonisolated final class NativeFeed: @unchecked Sendable {
    nonisolated enum Item: Sendable {
        /// Flush, then play on from `programmeTime`; the next segment starts at a keyframe at or before it.
        case restart(programmeTime: Double)
        case segment(Segment)
    }

    nonisolated struct Segment: Sendable {
        let sequence: Int
        let programmeStart: Double
        let duration: Double
        let isDiscontinuity: Bool
        let startsWithKeyframe: Bool
        let samples: NativeSamples
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var closed = false
    private var listener: (@Sendable () -> Void)?

    /// Called (on the session's queue) whenever something new is waiting.
    func setListener(_ listener: (@Sendable () -> Void)?) {
        lock.lock()
        self.listener = listener
        let pending = !items.isEmpty
        lock.unlock()
        if pending { listener?() }
    }

    func push(_ newItems: [Item]) {
        guard !newItems.isEmpty else { return }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        // A restart makes everything still waiting obsolete.
        if let restart = newItems.lastIndex(where: { if case .restart = $0 { return true } else { return false } }) {
            items = Array(newItems[restart...])
        } else {
            items += newItems
        }
        let listener = self.listener
        lock.unlock()
        listener?()
    }

    func drain() -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        let drained = items
        items.removeAll()
        return drained
    }

    func close() {
        lock.lock()
        closed = true
        items.removeAll()
        listener = nil
        lock.unlock()
    }
}
