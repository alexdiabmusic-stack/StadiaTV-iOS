import Foundation

/// Cuts a live MPEG transport stream into HLS segments without changing what is inside them.
///
/// A provider that offers only raw MPEG-TS, or whose own HLS never gets going, can still be played by Apple's player
/// once the stream is served as HLS, because HLS segments are themselves transport stream. Each segment is cut at a
/// keyframe, starts with the stream's PAT and PMT, and holds whole audio frames, which is what the player needs to
/// begin decoding from any of them.
///
/// Not thread-safe: feed it from one queue.
nonisolated final class HLSSegmenter {

    nonisolated struct Segment: Equatable {
        let sequence: Int
        let data: Data
        let duration: Double
        /// The stream restarted before this segment, so its timestamps may not follow on from the one before.
        let discontinuity: Bool
    }

    nonisolated struct Settings {
        /// The shortest a segment is made, so a stream with a keyframe every half second isn't cut into slivers.
        var minimumSegmentSeconds = 1.5
        /// A segment this long is cut at the next frame whether or not it is a keyframe.
        var maximumSegmentSeconds = 10.0
        /// Audio-only streams have no keyframes and are cut on time alone.
        var audioSegmentSeconds = 2.0

        init() {}
    }

    /// Why no segments are coming, when the stream can't be converted; nil while all is well.
    private(set) var problem: String?
    /// What the stream carries, e.g. "H.264 video, AAC audio"; known once its program table has arrived.
    var summary: String? { program?.summary }

    private let settings: Settings

    // Input
    private var input: [UInt8] = []
    private var synced = false
    private var bytesSeen = 0
    private var packetsSeen = 0

    // Program tables
    private var patAssembler = TransportStream.SectionAssembler()
    private var pmtAssembler = TransportStream.SectionAssembler()
    private var pmtPID: Int?
    private var programNumber: Int?
    private var patOutput: [UInt8]?
    private var pmtSection: [UInt8]?
    private var program: TransportStream.Program?
    private var carried: Set<Int> = []
    private var elementaryPIDs: Set<Int> = []
    private var cutPID: Int?
    private var videoType: UInt8 = 0
    private var patCounter = 0
    private var pmtCounter = 0

    // The segment being built
    private var current: [UInt8] = []
    private var started = false
    private var segmentStart: UInt64?
    private var segmentStartWall = Date()
    /// How far into the segment, by the stream's clock, the latest frame seen so far is, and how many frames there have been.
    private var segmentSpan = 0.0
    private var segmentFrames = 0
    private var segmentIsDiscontinuous = false
    private var discontinuityPending = false
    private var pending: Unit?
    private var closing: Closing?
    /// PIDs whose frames began before the last cut: their remaining packets belong to the segment before it.
    private var tails: Set<Int> = []
    private var nextSequence = 0

    /// A video (or, for radio, audio) access unit whose first packets are being read to see if it is a keyframe.
    private struct Unit {
        var offset: Int
        var timestamp: UInt64?
        var wall: Date
        var data: [UInt8]
        var packets: Int
    }

    /// A segment that is over but still waiting for the last audio frames that began inside it.
    private struct Closing {
        var sequence: Int
        var bytes: [UInt8]
        var duration: Double
        var discontinuity: Bool
        var packets = 0
    }

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    // MARK: - Feeding

    /// Adds bytes from the stream; returns the segments they completed.
    func feed(_ data: Data) -> [Segment] {
        guard problem == nil else { return [] }
        input.append(contentsOf: data)
        bytesSeen += data.count
        var completed: [Segment] = []
        var offset = 0

        while problem == nil {
            if !synced {
                guard let start = TransportStream.firstSync(in: input, from: offset) else {
                    // Not enough yet to find three packets in step: keep the last two packets' worth.
                    offset = max(offset, input.count - 2 * TransportStream.packetSize)
                    break
                }
                offset = start
                synced = true
            }
            guard offset + TransportStream.packetSize <= input.count else { break }
            guard input[offset] == TransportStream.syncByte else {
                synced = false
                offset += 1
                continue
            }
            process(packetAt: offset, completed: &completed)
            packetsSeen += 1
            offset += TransportStream.packetSize
        }
        input.removeFirst(min(offset, input.count))

        if problem == nil, program == nil {
            if packetsSeen == 0, bytesSeen > 512 * 1024 {
                problem = "The provider's stream isn't an MPEG transport stream."
            } else if bytesSeen > 12 * 1024 * 1024 {
                problem = "The provider's stream has no program table, so it can't be read."
            }
        }
        return completed
    }

    /// The upstream connection was lost and reopened: what was being cut is dropped and the next segment is marked
    /// as following a break.
    func markDiscontinuity() {
        input.removeAll()
        synced = false
        patAssembler = TransportStream.SectionAssembler()
        pmtAssembler = TransportStream.SectionAssembler()
        current.removeAll()
        started = false
        pending = nil
        closing = nil
        tails.removeAll()
        discontinuityPending = true
    }

    // MARK: - Packets

    private func process(packetAt offset: Int, completed: inout [Segment]) {
        guard let packet = TransportStream.Packet(input, at: offset), !packet.hasError else { return }
        let pid = packet.pid

        if pid == TransportStream.patPID {
            handlePAT(packet)
            return
        }
        if pid == pmtPID {
            handlePMT(packet)
            return
        }
        guard program != nil, carried.contains(pid), let cutPID else { return }
        let bytes = input[offset..<(offset + TransportStream.packetSize)]

        // The rest of a frame that began before the last cut belongs to the segment that cut ended.
        if tails.contains(pid) {
            if packet.payloadUnitStart {
                tails.remove(pid)
            } else {
                if closing != nil { closing?.bytes.append(contentsOf: bytes) }
                finishClosingIfDone(&completed)
                return
            }
        }
        if closing != nil {
            closing?.packets += 1
            if (closing?.packets ?? 0) > 600 { tails.removeAll() }
            finishClosingIfDone(&completed)
        }

        current.append(contentsOf: bytes)
        guard pid == cutPID else {
            trimBeforeStart()
            return
        }
        let payload = input[packet.payload]
        if packet.payloadUnitStart {
            // The frame before this one is settled first: that may cut `current`, so where this packet sits is
            // worked out afterwards (it is the last one in it).
            classifyPending(final: true, &completed)
            let header = TransportStream.parsePESHeader(payload)
            let esStart = header.map { payload.startIndex + $0.dataOffset } ?? payload.endIndex
            let data = esStart < payload.endIndex ? Array(payload[esStart..<min(payload.endIndex, esStart + 512)]) : []
            let unit = Unit(offset: current.count - TransportStream.packetSize, timestamp: header?.pts ?? header?.dts,
                            wall: Date(), data: data, packets: 1)
            noteFrame(unit)
            pending = unit
            if started, elapsed(to: unit) >= settings.maximumSegmentSeconds {
                pending = nil
                cut(at: unit, &completed)
            } else {
                classifyPending(final: false, &completed)
            }
        } else if var unit = pending, !payload.isEmpty {
            unit.data.append(contentsOf: payload.prefix(max(0, 512 - unit.data.count)))
            unit.packets += 1
            pending = unit
            classifyPending(final: unit.packets >= 4 || unit.data.count >= 512, &completed)
        }
        trimBeforeStart()
    }

    // MARK: - Program tables

    private func handlePAT(_ packet: TransportStream.Packet) {
        guard let section = patAssembler.feed(input[packet.payload], payloadUnitStart: packet.payloadUnitStart),
              let programs = TransportStream.parsePAT(section), let first = programs.first else { return }
        // A stream carrying several programs is cut down to the one chosen; its PAT is rewritten to match.
        if programNumber == nil || !programs.contains(where: { $0.number == programNumber }) {
            programNumber = first.number
            pmtPID = first.pmtPID
        }
        guard let chosen = programs.first(where: { $0.number == programNumber }) else { return }
        pmtPID = chosen.pmtPID
        patOutput = programs.count == 1 ? section : TransportStream.makePAT(program: chosen.number, pmtPID: chosen.pmtPID)
    }

    private func handlePMT(_ packet: TransportStream.Packet) {
        guard let pmtPID,
              let section = pmtAssembler.feed(input[packet.payload], payloadUnitStart: packet.payloadUnitStart),
              let parsed = TransportStream.parsePMT(section, pmtPID: pmtPID), parsed.number == programNumber else { return }
        pmtSection = section
        guard parsed != program else { return }
        program = parsed
        carried = parsed.carriedPIDs
        elementaryPIDs = Set(parsed.streams.map(\.pid))
        if let video = parsed.video {
            videoType = video.type
            cutPID = video.pid
            if !video.isPlayableVideo {
                problem = "This channel's video is \(video.name), which Apple's player can't decode."
            }
        } else if let audio = parsed.streams.first(where: { $0.kind == .audio }) {
            cutPID = audio.pid
        } else {
            problem = "This stream has no audio or video."
        }
    }

    // MARK: - Cutting

    private func classifyPending(final: Bool, _ completed: inout [Segment]) {
        guard let unit = pending else { return }
        let verdict = videoPIDIsCut
            ? TransportStream.classifyKeyframe(streamType: videoType, data: unit.data, final: final)
            : .yes
        switch verdict {
        case .undecided:
            return
        case .no:
            pending = nil
        case .yes:
            pending = nil
            keyframe(unit, &completed)
        }
    }

    private var videoPIDIsCut: Bool { program?.video != nil }

    private func keyframe(_ unit: Unit, _ completed: inout [Segment]) {
        if !started {
            begin(at: unit)
            return
        }
        // A stream restarted or spliced at its source starts a new clock, usually with a keyframe: the new segment
        // begins there whatever its length so far, and is marked, as the player is told to expect the break.
        if clockJumped(to: unit) {
            cut(at: unit, &completed, discontinuous: true)
            return
        }
        let needed = videoPIDIsCut ? settings.minimumSegmentSeconds : settings.audioSegmentSeconds
        guard elapsed(to: unit) >= needed else { return }
        cut(at: unit, &completed)
    }

    /// Whether the stream's own clock has jumped since the segment began: back (frames shown just before a keyframe
    /// may be a little earlier than it), or further ahead than a segment can be, since one is cut at the first frame
    /// after the maximum length. A jump left in the playlist unmarked would make a segment's length wild, and the
    /// target duration, which only goes up, would stay that wrong for the rest of the stream.
    private func clockJumped(to unit: Unit) -> Bool {
        guard let start = segmentStart, let end = unit.timestamp else { return false }
        let seconds = TransportStream.seconds(from: start, to: end)
        return seconds < -2 || seconds > plausibleSpan
    }

    /// The longest the stream's clock can run between the start of a segment and a frame that follows it.
    private var plausibleSpan: Double { settings.maximumSegmentSeconds * 2 }

    /// Counts a frame of the segment being built, and how far along it is by the stream's clock (frames are not always
    /// in time order, so the latest is the greatest seen). A frame from a clock that has jumped is not part of it.
    private func noteFrame(_ unit: Unit) {
        guard started, let start = segmentStart, let timestamp = unit.timestamp, !clockJumped(to: unit) else { return }
        segmentFrames += 1
        segmentSpan = max(segmentSpan, TransportStream.seconds(from: start, to: timestamp))
    }

    /// The length of the segment being built by what is in it, for when the stream's clock has jumped and the next
    /// frame's time can't be compared with the segment's start: the span of its frames, plus the last one's length.
    private var measuredDuration: Double {
        guard segmentFrames > 1 else { return 0.04 }
        return max(segmentSpan * Double(segmentFrames) / Double(segmentFrames - 1), 0.04)
    }

    /// Seconds from the start of the current segment to `unit`, by the stream's own clock when it has one.
    private func elapsed(to unit: Unit) -> Double {
        if let start = segmentStart, let end = unit.timestamp {
            let seconds = TransportStream.seconds(from: start, to: end)
            if seconds >= 0, seconds <= plausibleSpan { return seconds }
        }
        return unit.wall.timeIntervalSince(segmentStartWall)
    }

    /// Splits `current` at `offset`. Packets after it that finish a frame begun earlier go with what comes before; the
    /// PIDs still owing such a frame are returned.
    private func split(at offset: Int) -> (before: [UInt8], after: [UInt8], owing: Set<Int>) {
        var before = Array(current[0..<offset])
        var after: [UInt8] = []
        after.reserveCapacity(current.count - offset)
        var owing = elementaryPIDs
        if let cutPID { owing.remove(cutPID) }
        var i = offset
        while i + TransportStream.packetSize <= current.count {
            let packet = TransportStream.Packet(current, at: i)
            let slice = current[i..<(i + TransportStream.packetSize)]
            if let packet, packet.pid != cutPID, owing.contains(packet.pid) {
                if packet.payloadUnitStart {
                    owing.remove(packet.pid)
                    after.append(contentsOf: slice)
                } else {
                    before.append(contentsOf: slice)
                }
            } else {
                after.append(contentsOf: slice)
            }
            i += TransportStream.packetSize
        }
        return (before, after, owing)
    }

    /// The first keyframe: nothing before it is wanted.
    private func begin(at unit: Unit) {
        let parts = split(at: unit.offset)
        current = parts.after
        tails = parts.owing
        closing = nil
        started = true
        segmentStart = unit.timestamp
        segmentStartWall = unit.wall
        segmentSpan = 0
        segmentFrames = 1
        segmentIsDiscontinuous = discontinuityPending
        discontinuityPending = false
    }

    private func cut(at unit: Unit, _ completed: inout [Segment], discontinuous: Bool = false) {
        finishClosing(&completed)
        let duration = discontinuous ? measuredDuration : max(elapsed(to: unit), 0.04)
        let parts = split(at: unit.offset)
        let finished = Closing(sequence: nextSequence, bytes: parts.before, duration: duration, discontinuity: segmentIsDiscontinuous)
        nextSequence += 1
        current = parts.after
        segmentStart = unit.timestamp
        segmentStartWall = unit.wall
        segmentSpan = 0
        segmentFrames = 1
        segmentIsDiscontinuous = discontinuous
        tails = parts.owing
        closing = finished
        finishClosingIfDone(&completed)
    }

    private func finishClosingIfDone(_ completed: inout [Segment]) {
        if closing != nil, tails.isEmpty { finishClosing(&completed) }
    }

    private func finishClosing(_ completed: inout [Segment]) {
        guard let finished = closing else { return }
        closing = nil
        tails.removeAll()
        completed.append(Segment(sequence: finished.sequence,
                                 data: Data(programTablePackets() + finished.bytes),
                                 duration: finished.duration,
                                 discontinuity: finished.discontinuity))
    }

    /// Before the first keyframe nothing is kept for long: a stream that never has one mustn't fill memory.
    private func trimBeforeStart() {
        guard !started, current.count > 4 * 1024 * 1024 else { return }
        let keepFrom = pending?.offset ?? current.count
        current = Array(current[keepFrom...])
        if pending != nil { pending?.offset = 0 }
    }

    /// The PAT and PMT that start every segment, with counters that run on from one segment to the next.
    private func programTablePackets() -> [UInt8] {
        guard let patOutput, let pmtSection, let pmtPID else { return [] }
        let pat = TransportStream.makePackets(section: patOutput, pid: TransportStream.patPID, counter: patCounter)
        patCounter = pat.nextCounter
        let pmt = TransportStream.makePackets(section: pmtSection, pid: pmtPID, counter: pmtCounter)
        pmtCounter = pmt.nextCounter
        return pat.packets + pmt.packets
    }
}
