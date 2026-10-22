import Foundation

/// One finished HLS media segment of the local stream.
nonisolated struct MediaSegment: Sendable {
    let sequence: Int
    let data: Data
    /// EXTINF duration in seconds.
    let duration: Double
    /// Seconds since the session's first picture; the basis of EXT-X-PROGRAM-DATE-TIME.
    let programmeStart: Double
    let startsWithKeyframe: Bool
    /// Preceded by EXT-X-DISCONTINUITY: the codecs changed, or content before it was dropped.
    var isDiscontinuity: Bool
    /// Output-timeline decode times (90 kHz, 33-bit) of the first picture and of the next segment's.
    var startTime: Int64? = nil
    var endTime: Int64? = nil
    /// Fragmented MP4 sessions: `data` is the video fragment, which plays after the initialization
    /// section with this number; `audio` holds each audio rendition's fragment for the same stretch.
    var initialization: Int? = nil
    var audio: [AudioFragment] = []

    var programmeEnd: Double { programmeStart + duration }
    var byteCount: Int { data.count + audio.reduce(0) { $0 + $1.data.count } }
}

/// One audio rendition's fragment of a media segment. Its audio arrived with the segment's
/// pictures, so it can start and end a little apart from them; it has its own timing.
nonisolated struct AudioFragment: Sendable {
    /// The audio stream's position in the program, which identifies its rendition.
    let rendition: Int
    let data: Data
    let initialization: Int
    let programmeStart: Double
    let duration: Double
}

/// Cuts the normalized transport stream into short HLS segments.
///
/// Segments start on pictures the decoder can begin from whenever the source's GOP allows,
/// and every segment opens with PAT and PMT so AVPlayer can join at any of them. Durations
/// come from the output timeline, which the splicer keeps continuous.
nonisolated struct HLSSegmenter {
    struct Configuration: Equatable, Sendable {
        /// Preferred length; the cut happens at the first keyframe after this much.
        var targetDuration: Double = 2.0
        /// Shorter first segments so the first picture appears sooner.
        var startupTargetDuration: Double = 1.0
        var startupSegmentCount = 2
        /// Cut here even without a keyframe (long-GOP sources). IPTV encoders commonly send a keyframe
        /// every 4 s, which must still cut at keyframes; a cut a frame past this still rounds to the
        /// target duration, as EXTINF must.
        var maximumDuration: Double = 4.3
        /// EXT-X-TARGETDURATION; no segment may round above it.
        var playlistTargetDuration = 4
    }

    let configuration: Configuration
    private var bytes: [UInt8] = []
    private var startTime: Int64?
    private var lastTime: Int64?
    private var lastDuration: Int64 = 3_600
    private var startsWithKeyframe = false
    private var isDiscontinuity = false
    private var nextSequence = 0
    private var programmeTime: Double = 0
    private var patContinuity: UInt8 = 0x0F
    private var pmtContinuity: UInt8 = 0x0F
    /// PSI continuity counters before the open segment's tables, restored if it's discarded.
    private var tablesContinuity: (pat: UInt8, pmt: UInt8) = (0x0F, 0x0F)
    private var lastSegmentSize = 0

    /// Where the latest video keyframe starts in the open segment.
    private struct KeyframeMark {
        let time: Int64
        let offset: Int
        let program: TSProgram
        let programVersion: UInt8
    }
    private var keyframeMark: KeyframeMark?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Seconds of output buffered in the segment that hasn't been cut yet.
    var openDuration: Double {
        guard let startTime, let lastTime else { return 0 }
        return MPEGTS.seconds(MPEGTS.signedDelta(lastTime, startTime) + lastDuration)
    }

    var producedSegmentCount: Int { nextSequence }

    mutating func append(_ units: [NormalizedUnit]) -> [MediaSegment] {
        var finished: [MediaSegment] = []
        for unit in units {
            if unit.isTiming, let time = unit.time {
                if startTime == nil {
                    beginTiming(at: time, unit: unit)
                } else if let start = startTime {
                    let elapsed = MPEGTS.seconds(MPEGTS.signedDelta(time, start))
                    let target = nextSequence < configuration.startupSegmentCount
                        ? configuration.startupTargetDuration : configuration.targetDuration
                    // Keyframes are measured by decode time, which shifts by a few frames between
                    // IDR and open-GOP pictures; the slack keeps a 2 s GOP cutting every 2 s.
                    let keyframeCut = unit.isKeyframe && elapsed >= target * 0.75
                    if unit.startsDiscontinuity || keyframeCut || elapsed >= configuration.maximumDuration {
                        if let segment = close(at: time) { finished.append(segment) }
                        beginTiming(at: time, unit: unit)
                    }
                }
                lastTime = time
                if unit.duration > 0 { lastDuration = unit.duration }
            }
            if bytes.isEmpty { writeProgramTables(unit.program, version: unit.programVersion) }
            if unit.isTiming, unit.isKeyframe, unit.kind == .video, let time = unit.time {
                keyframeMark = KeyframeMark(time: time, offset: bytes.count, program: unit.program, programVersion: unit.programVersion)
            }
            for packet in unit.packets { bytes.append(contentsOf: packet.bytes) }
        }
        return finished
    }

    /// Cuts the open segment where its content ends. Called when a connection drops, so what
    /// already arrived can be played while the reconnect happens.
    mutating func flush() -> MediaSegment? {
        guard let lastTime else { return nil }
        return close(at: MPEGTS.wrap(lastTime + lastDuration))
    }

    /// Cuts the open segment at the keyframe decoded at `time`: what came before it is returned as a
    /// finished segment, and the open segment then starts at that keyframe, so it can be discarded
    /// whole if a reconnect re-sends that GOP. `held` is false when that keyframe isn't in the open segment.
    mutating func holdTail(fromKeyframeAt time: Int64) -> (held: Bool, closed: MediaSegment?) {
        guard let mark = keyframeMark, mark.time == time, startTime != nil else { return (false, nil) }
        guard let start = startTime, MPEGTS.signedDelta(time, start) > 0 else { return (true, nil) }
        let tail = Array(bytes[mark.offset...])
        let tailEnd = (lastTime, lastDuration)
        bytes.removeSubrange(mark.offset...)
        let closed = close(at: time)
        writeProgramTables(mark.program, version: mark.programVersion)
        keyframeMark = KeyframeMark(time: time, offset: bytes.count, program: mark.program, programVersion: mark.programVersion)
        bytes += tail
        startTime = time
        startsWithKeyframe = true
        (lastTime, lastDuration) = tailEnd
        return (true, closed)
    }

    /// Drops the open segment: a reconnect re-sent everything in it.
    mutating func discardOpenSegment() {
        if !bytes.isEmpty { (patContinuity, pmtContinuity) = tablesContinuity }
        bytes = []
        startTime = nil
        lastTime = nil
        startsWithKeyframe = false
        isDiscontinuity = false
        keyframeMark = nil
    }

    private mutating func beginTiming(at time: Int64, unit: NormalizedUnit) {
        startTime = time
        startsWithKeyframe = unit.isKeyframe
        isDiscontinuity = isDiscontinuity || unit.startsDiscontinuity
    }

    private mutating func close(at endTime: Int64) -> MediaSegment? {
        guard let start = startTime, !bytes.isEmpty else { return nil }
        var duration = MPEGTS.seconds(MPEGTS.signedDelta(endTime, start))
        // A source gap inside the segment must not push EXTINF past the playlist's target duration.
        let ceiling = Double(configuration.playlistTargetDuration) + 0.4
        if duration > ceiling, let lastTime {
            duration = min(ceiling, MPEGTS.seconds(MPEGTS.signedDelta(lastTime, start) + lastDuration))
        }
        duration = max(duration, 0.001)
        let segment = MediaSegment(sequence: nextSequence, data: Data(bytes), duration: duration,
                                   programmeStart: programmeTime, startsWithKeyframe: startsWithKeyframe,
                                   isDiscontinuity: isDiscontinuity, startTime: start, endTime: endTime)
        nextSequence += 1
        programmeTime += duration
        lastSegmentSize = bytes.count
        bytes = []
        bytes.reserveCapacity(lastSegmentSize + lastSegmentSize / 4)
        startTime = nil
        lastTime = nil
        startsWithKeyframe = false
        isDiscontinuity = false
        keyframeMark = nil
        return segment
    }

    private mutating func writeProgramTables(_ program: TSProgram, version: UInt8) {
        tablesContinuity = (patContinuity, pmtContinuity)
        for packet in PSITables.packetize(section: PSITables.makePAT(for: program, version: version),
                                          pid: MPEGTS.patPID, continuityCounter: &patContinuity) {
            bytes.append(contentsOf: packet.bytes)
        }
        for packet in PSITables.packetize(section: PSITables.makePMT(for: program, version: version),
                                          pid: program.pmtPID, continuityCounter: &pmtContinuity) {
            bytes.append(contentsOf: packet.bytes)
        }
    }
}

/// The compressed programme reserve: segments the engine holds ahead of playback, plus the
/// published window AVPlayer can see (and rewind within).
nonisolated struct SegmentReserve {
    struct Configuration: Equatable, Sendable {
        /// Published segments kept behind the playhead for rewinding.
        var backBufferSeconds: Double = 30
        /// Ceiling on everything held, published or not.
        var maximumBytes = 64 * 1024 * 1024
    }

    let configuration: Configuration
    private(set) var segments: [MediaSegment] = []
    private(set) var publishedCount = 0
    /// Discontinuity tags that have scrolled out of the playlist (EXT-X-DISCONTINUITY-SEQUENCE).
    private(set) var evictedDiscontinuities = 0
    /// Seconds of unpublished programme discarded because the reserve hit its byte ceiling.
    private(set) var discardedSeconds: Double = 0
    private(set) var byteCount = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var published: ArraySlice<MediaSegment> { segments[0..<publishedCount] }
    var unpublished: ArraySlice<MediaSegment> { segments[publishedCount...] }

    /// Programme seconds held but not yet visible to the decoder.
    var reserveSeconds: Double { unpublished.reduce(0) { $0 + $1.duration } }
    var publishedEnd: Double? { published.last?.programmeEnd }
    var ingestEnd: Double? { segments.last?.programmeEnd }

    mutating func append(_ segment: MediaSegment) {
        segments.append(segment)
        byteCount += segment.byteCount
        enforceByteCeiling()
    }

    /// Publishes the next segment, if any.
    @discardableResult
    mutating func publishNext() -> MediaSegment? {
        guard publishedCount < segments.count else { return nil }
        publishedCount += 1
        return segments[publishedCount - 1]
    }

    /// Publishes every segment that starts before `programmeTime`. Returns how many.
    @discardableResult
    mutating func publish(before programmeTime: Double) -> Int {
        var count = 0
        while publishedCount < segments.count, segments[publishedCount].programmeStart < programmeTime {
            publishedCount += 1
            count += 1
        }
        return count
    }

    /// Publishes everything: jump to the newest programme the engine holds.
    mutating func publishAll() { publishedCount = segments.count }

    /// Drops published segments that fell more than the back buffer behind `playhead`.
    mutating func evict(playhead: Double?) {
        guard let playhead else { return }
        let cutoff = playhead - configuration.backBufferSeconds
        // Always keep the segment under the playhead and everything after it.
        while publishedCount > 1, segments[0].programmeEnd < cutoff, segments[1].programmeStart <= playhead {
            removeFirst()
        }
    }

    /// The published segment starting with a keyframe at or before `programmeTime`, for rejoining playback.
    func joinPoint(atOrBefore programmeTime: Double) -> MediaSegment? {
        published.last { $0.startsWithKeyframe && $0.programmeStart <= programmeTime } ?? published.first
    }

    func segment(sequence: Int) -> MediaSegment? {
        guard let first = segments.first, sequence >= first.sequence, sequence - first.sequence < publishedCount else { return nil }
        return segments[sequence - first.sequence]
    }

    private mutating func removeFirst() {
        let removed = segments.removeFirst()
        byteCount -= removed.byteCount
        if removed.isDiscontinuity { evictedDiscontinuities += 1 }
        publishedCount -= 1
    }

    private mutating func enforceByteCeiling() {
        // Rewind history goes first, then the oldest unpublished programme (the viewer is paused
        // or far behind). Skipping unpublished content needs a discontinuity where it resumes.
        while byteCount > configuration.maximumBytes, publishedCount > 1 {
            removeFirst()
        }
        while byteCount > configuration.maximumBytes, segments.count - publishedCount > 1 {
            let removed = segments.remove(at: publishedCount)
            byteCount -= removed.byteCount
            discardedSeconds += removed.duration
            segments[publishedCount].isDiscontinuity = true
        }
    }
}

/// Renders the local live media playlist.
nonisolated enum HLSPlaylistWriter {
    static func mediaPlaylist(segments: ArraySlice<MediaSegment>, targetDuration: Int, discontinuitySequence: Int,
                              epoch: Date, startOffset: Double? = nil) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.sequence ?? 0)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)"
        ]
        if let startOffset {
            lines.append("#EXT-X-START:TIME-OFFSET=\(String(format: "%.3f", max(0, startOffset))),PRECISE=NO")
        }
        for segment in segments {
            if segment.isDiscontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            lines.append("#EXT-X-PROGRAM-DATE-TIME:\(timestamp(epoch.addingTimeInterval(segment.programmeStart)))")
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            lines.append("s\(segment.sequence).ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One segment of a fragmented-MP4 media playlist.
    struct FragmentEntry {
        var uri: String
        /// The initialization section it plays after.
        var map: String
        var duration: Double
        var programmeStart: Double
        var isDiscontinuity: Bool
        /// Decodable without the segments before it: video that starts with a keyframe (a long GOP
        /// cut short doesn't), and audio.
        var isIndependent = true
    }

    /// A rendition's media playlist for fragmented MP4: EXT-X-MAP before the first segment and
    /// wherever the initialization section changes.
    static func fragmentedMediaPlaylist(entries: [FragmentEntry], mediaSequence: Int, targetDuration: Int,
                                        discontinuitySequence: Int, epoch: Date, startOffset: Double? = nil) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)"
        ]
        if entries.allSatisfy(\.isIndependent) { lines.append("#EXT-X-INDEPENDENT-SEGMENTS") }
        if let startOffset {
            lines.append("#EXT-X-START:TIME-OFFSET=\(String(format: "%.3f", max(0, startOffset))),PRECISE=NO")
        }
        var map: String?
        for entry in entries {
            if entry.isDiscontinuity { lines.append("#EXT-X-DISCONTINUITY") }
            // A player may reset its demuxer at a discontinuity: name the initialization section again.
            if entry.map != map || entry.isDiscontinuity {
                lines.append("#EXT-X-MAP:URI=\"\(entry.map)\"")
                map = entry.map
            }
            lines.append("#EXT-X-PROGRAM-DATE-TIME:\(timestamp(epoch.addingTimeInterval(entry.programmeStart)))")
            lines.append("#EXTINF:\(String(format: "%.3f", entry.duration)),")
            lines.append(entry.uri)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    struct AudioRenditionTag {
        var uri: String
        var name: String
        /// RFC 5646 language tag.
        var language: String
        var channels: Int
        var isDefault: Bool
    }

    /// The multivariant playlist for a fragmented-MP4 session: one video variant, with its audio as
    /// separate renditions. CODECS, RESOLUTION, FRAME-RATE and VIDEO-RANGE let AVPlayer decide it
    /// can play the variant, and set up HDR before the first picture. EXT-X-INDEPENDENT-SEGMENTS
    /// is left to the media playlists: here it would cover video segments a long GOP was cut in.
    static func multivariantPlaylist(videoURI: String, bandwidth: Int, averageBandwidth: Int, codecs: [String],
                                     width: Int, height: Int, frameRate: Double?, videoRange: String,
                                     audio: [AudioRenditionTag]) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7"]
        for rendition in audio {
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(rendition.name)\",LANGUAGE=\"\(rendition.language)\","
                         + "DEFAULT=\(rendition.isDefault ? "YES" : "NO"),AUTOSELECT=YES,CHANNELS=\"\(rendition.channels)\","
                         + "URI=\"\(rendition.uri)\"")
        }
        var attributes = ["BANDWIDTH=\(bandwidth)", "AVERAGE-BANDWIDTH=\(averageBandwidth)",
                          "CODECS=\"\(codecs.joined(separator: ","))\"", "RESOLUTION=\(width)x\(height)"]
        if let frameRate { attributes.append(String(format: "FRAME-RATE=%.3f", frameRate)) }
        attributes.append("VIDEO-RANGE=\(videoRange)")
        if !audio.isEmpty { attributes.append("AUDIO=\"audio\"") }
        lines.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        lines.append(videoURI)
        return lines.joined(separator: "\n") + "\n"
    }

    /// ISO 8601 with milliseconds in UTC, e.g. 2026-10-20T16:46:14.138Z.
    static func timestamp(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        var seconds = Int(milliseconds / 1000)
        let millis = Int(milliseconds % 1000)
        let days = seconds / 86_400
        seconds %= 86_400
        let (year, month, day) = civilDate(daysSinceEpoch: days)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                      year, month, day, seconds / 3600, (seconds / 60) % 60, seconds % 60, millis)
    }

    /// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's algorithm).
    private static func civilDate(daysSinceEpoch: Int) -> (Int, Int, Int) {
        let z = daysSinceEpoch + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
