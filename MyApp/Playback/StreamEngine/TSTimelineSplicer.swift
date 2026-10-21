import Foundation

/// A complete PES packet ready for the segmenter: PIDs remapped onto the output program,
/// timestamps on the output timeline and continuity counters continuous across splices.
nonisolated struct NormalizedUnit {
    enum Kind: Equatable { case video, audio, metadata }

    var kind: Kind
    var packets: [TSPacket]
    /// Output-timeline timestamps (90 kHz, 33-bit). DTS equals PTS when the PES carries none.
    var pts: Int64?
    var dts: Int64?
    var isKeyframe: Bool
    /// True for the stream that drives segment timing: video, or the first audio stream of a radio feed.
    var isTiming: Bool
    /// First unit after a change the decoder can't continue across (codec or stream layout).
    var startsDiscontinuity: Bool
    /// Expected presentation duration of this unit, in 90 kHz ticks.
    var duration: Int64
    /// The output program this unit belongs to, for the PAT/PMT that open each segment.
    var program: TSProgram
    var programVersion: UInt8

    var time: Int64? { dts ?? pts }
}

/// Joins the transport streams of successive connections into one continuous timeline.
///
/// This is the engine's splice layer. A reconnect starts at an arbitrary picture, usually
/// re-sends seconds the reserve already holds, may come from a transcoder that restarted its
/// clock at zero, and carries its own continuity counters. The splicer therefore:
/// 1. waits for PAT, PMT and a picture the decoder can start from before letting a new
///    connection through, dropping leading pictures and audio that would play before it;
/// 2. skips everything the previous connection already delivered when both share a clock;
/// 3. re-times the new connection so its first picture follows the last one delivered,
///    which closes outage gaps and hides timebase resets (PTS, DTS and PCR move together,
///    so audio and video stay in sync);
/// 4. remaps PIDs onto the output program and keeps every continuity counter continuous;
/// 5. flags a discontinuity only when the codecs themselves changed.
///
/// Only whole PES packets are emitted, so the torn frame a dying socket leaves behind is
/// discarded instead of being glued to the next connection.
nonisolated final class TSTimelineSplicer {
    struct Configuration {
        /// Where the output timeline starts, far from the 33-bit wrap.
        var initialTime: Int64 = 10 * MPEGTS.clockRate
        /// How far back a reconnect may restart and still be treated as the same clock (overlap).
        var overlapLimit: Int64 = 60 * MPEGTS.clockRate
        /// Slack on top of the outage length before a forward jump counts as a new clock.
        var forwardSlack: Int64 = 10 * MPEGTS.clockRate
        /// Longest stretch of already-delivered content to skip before splicing anyway.
        var maximumDeduplication: Int64 = 45 * MPEGTS.clockRate
        /// In-stream DTS steps outside this window are timeline jumps. Forward gaps are missing
        /// programme; closing them avoids holding a frozen picture for the gap's length.
        var jumpBackward: Int64 = MPEGTS.clockRate
        var jumpForward: Int64 = 2 * MPEGTS.clockRate
        /// Audio further than this from the video clock is garbage.
        var audioSanityWindow: Int64 = 10 * MPEGTS.clockRate
        var maximumUnitPackets = 24_000
    }

    struct SpliceReport: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case start, seamless, overlapRemoved, gapClosed, timebaseReset, timelineJump, reconfigured
        }
        var kind: Kind
        /// Seconds of already-delivered content the new connection re-sent and that was skipped.
        var skippedSeconds: Double
        /// Seconds of programme that went missing between the old and new connection.
        var missingSeconds: Double
    }

    enum Event: Equatable, Sendable {
        case program(TSProgram)
        case splice(SpliceReport)
        case unsupportedProgram(String)
    }

    struct Statistics: Equatable, Sendable {
        var splices = 0
        var overlapsRemoved = 0
        var gapsClosed = 0
        var timebaseResets = 0
        var timelineJumps = 0
        var reconfigurations = 0
        var droppedUnits = 0
        var corruptUnits = 0
        var scrambledPackets = 0
        var erroredPackets = 0
    }

    private enum GateReason: Equatable { case firstConnection, reconnect, sourceDiscontinuity, timelineJump, reconfiguration }

    private enum Mode: Equatable {
        case awaitingProgram
        case awaitingKeyframe
        case deduplicating(until: Int64, since: Double, firstDropped: Int64?)
        case flowing
    }

    private struct ContinuityState {
        var last: UInt8?
        var offset: UInt8 = 0
        var needsAnchor = true
    }

    /// The picture a splice is being decided on, in its connection's clock.
    private struct SplicePicture {
        let pts: Int64
        let dts: Int64
        let fingerprint: UInt64?
        let isInstantRefresh: Bool
    }

    /// A delivered keyframe, in its own connection's clock.
    private struct KeyframeRecord: Equatable {
        let dts: Int64
        let fingerprint: UInt64
    }

    let configuration: Configuration
    private(set) var outputProgram: TSProgram?
    /// Bumped whenever the output PMT changes.
    private(set) var programVersion: UInt8 = 0
    private(set) var statistics = Statistics()
    private var events: [Event] = []

    // Per connection.
    /// The program the previous connection carried. A reconnect that starts just after a PAT/PMT
    /// uses it for PES on the same PIDs until its own tables arrive, rather than letting the next
    /// GOP go by; tables that say otherwise replace it as usual.
    private var previousSourceProgram: TSProgram?
    private var patAssembler = PSISectionAssembler()
    private var pmtAssembler = PSISectionAssembler()
    private var sourcePMTPID: UInt16?
    private var sourceProgram: TSProgram?
    private var pending: [UInt16: [TSPacket]] = [:]
    private var pidMap: [UInt16: UInt16] = [:]
    private var mode: Mode = .awaitingProgram
    private var gateReason: GateReason = .firstConnection
    private var lastSeenRawTiming: Int64?
    private var lastEmittedRawTimingInConnection: Int64?
    private var gatePTS: Int64?
    private var dropLeadingPicturesBefore: Int64?
    private var timingDeltas: [Int64] = []
    /// Audio/metadata that arrived while a reconnect waited for its splice picture; released
    /// once the splice offset is known so it can fill the audio hole at the join.
    private var heldFollowers: [(unit: PESUnit, header: PESUnit.Header, stream: TSProgram.Stream)] = []

    // Across connections.
    private var offset: Int64 = 0
    private var hasOutput = false
    private var lastOutTiming: Int64?
    private var maxOutVideoPTS: Int64?
    private var lastOutAudioPTS: [UInt16: Int64] = [:]
    /// Recent PTS steps between audio PES on each output PID: a PES often carries several frames.
    private var audioSteps: [UInt16: [Int64]] = [:]
    /// Where the last delivered audio PES on each output PID stops playing.
    private var lastOutAudioEnd: [UInt16: Int64] = [:]
    /// Splice count when each audio PID last emitted; a step is only measured within one stretch.
    private var audioEpoch: [UInt16: Int] = [:]
    private var spliceEpoch = 0
    /// Audio PIDs whose next unit follows a splice and must clear the previous PES's whole span.
    private var audioSpliceGuard: Set<UInt16> = []
    private var lastEmittedRawTiming: Int64?
    private var lastEmittedWallTime: Double?
    private var continuity: [UInt16: ContinuityState] = [:]
    private var pendingDiscontinuity = false
    /// Keyframes delivered recently. A reconnect only counts as re-sending old content when
    /// its first keyframe is one of these: a restarted transcoder can land its new clock just
    /// behind the old one, and must not have its fresh programme thrown away as a duplicate.
    private var deliveredKeyframes: [KeyframeRecord] = []
    private let deliveredKeyframeLimit = 512

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Recent frame interval of the timing stream (25 fps until measured).
    var frameDuration: Int64 {
        guard !timingDeltas.isEmpty else { return 3_600 }
        return timingDeltas.sorted()[timingDeltas.count / 2]
    }

    /// The end of the last unit delivered, on the output timeline.
    var outputEnd: Int64? { lastOutTiming.map { MPEGTS.wrap($0 + frameDuration) } }

    func drainEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    // MARK: - Connection lifecycle

    /// The next packets come from a new connection.
    func beginConnection() {
        if let sourceProgram { previousSourceProgram = sourceProgram }
        resetConnectionState()
        gateReason = hasOutput ? .reconnect : .firstConnection
    }

    /// Discards PES packets the connection didn't finish.
    func endConnection() {
        for (pid, packets) in pending where !packets.isEmpty { markDropped(sourcePID: pid) }
        pending.removeAll()
    }

    /// The source declared a timeline break (an HLS discontinuity): splice at the next
    /// picture without trying to match content against what was already delivered.
    func beginSourceDiscontinuity() {
        endConnection()
        if sourceProgram != nil, mode != .awaitingProgram {
            mode = .awaitingKeyframe
        }
        if hasOutput { gateReason = .sourceDiscontinuity }
    }

    private func resetConnectionState() {
        patAssembler = PSISectionAssembler()
        pmtAssembler = PSISectionAssembler()
        sourcePMTPID = nil
        sourceProgram = nil
        pending.removeAll()
        pidMap.removeAll()
        mode = .awaitingProgram
        lastSeenRawTiming = nil
        lastEmittedRawTimingInConnection = nil
        gatePTS = nil
        dropLeadingPicturesBefore = nil
        timingDeltas.removeAll()
        heldFollowers.removeAll()
    }

    // MARK: - Packet processing

    func process(_ packets: [TSPacket], wallTime: Double) -> [NormalizedUnit] {
        var output: [NormalizedUnit] = []
        for packet in packets {
            if packet.transportError {
                statistics.erroredPackets += 1
                continue
            }
            let pid = packet.pid
            if pid == MPEGTS.nullPID { continue }
            if pid == MPEGTS.patPID {
                handlePAT(packet)
                continue
            }
            if let pmtPID = sourcePMTPID, pid == pmtPID {
                handlePMT(packet)
                continue
            }
            if sourceProgram == nil, packet.payloadUnitStart, let previous = previousSourceProgram,
               previous.stream(pid: pid).map({ $0.kind != .other }) == true {
                adopt(previous)
            }
            guard let program = sourceProgram else { continue }
            if let stream = program.stream(pid: pid), stream.kind != .other {
                if packet.isScrambled {
                    statistics.scrambledPackets += 1
                    continue
                }
                if packet.payloadUnitStart {
                    if let previous = pending[pid], !previous.isEmpty {
                        complete(PESUnit(sourcePID: pid, packets: previous), stream: stream, program: program,
                                 wallTime: wallTime, into: &output)
                    }
                    pending[pid] = [packet]
                } else if pending[pid] != nil {
                    pending[pid]?.append(packet)
                    if (pending[pid]?.count ?? 0) > configuration.maximumUnitPackets {
                        pending[pid] = nil
                        markDropped(sourcePID: pid)
                    }
                }
            } else if pid == program.pcrPID, mode == .flowing, let outputPID = pidMap[pid], let outputProgram {
                // PCR carried on its own PID.
                var packet = packet
                normalizePCR(&packet)
                var single = [packet]
                remap(&single, to: outputPID)
                output.append(NormalizedUnit(kind: .metadata, packets: single, pts: nil, dts: nil, isKeyframe: false,
                                             isTiming: false, startsDiscontinuity: false, duration: 0,
                                             program: outputProgram, programVersion: programVersion))
            }
        }
        return output
    }

    // MARK: - PSI

    private func handlePAT(_ packet: TSPacket) {
        for section in patAssembler.push(packet) {
            guard let entries = PSITables.parsePAT(section), let first = entries.first else { continue }
            if let current = sourcePMTPID, entries.contains(where: { $0.pmtPID == current }) { continue }
            sourcePMTPID = first.pmtPID
            pmtAssembler = PSISectionAssembler()
        }
    }

    private func handlePMT(_ packet: TSPacket) {
        guard let pmtPID = sourcePMTPID else { return }
        for section in pmtAssembler.push(packet) {
            guard let program = PSITables.parsePMT(section, pmtPID: pmtPID), program != sourceProgram else { continue }
            adopt(program)
        }
    }

    /// Maps a newly announced source program onto the output program.
    private func adopt(_ program: TSProgram) {
        guard program.video != nil || !program.audio.isEmpty else {
            events.append(.unsupportedProgram("No audio or video stream"))
            return
        }
        sourceProgram = program
        pending = pending.filter { program.stream(pid: $0.key) != nil }

        if let output = outputProgram, program.isSpliceCompatible(with: output), let map = pidMapping(from: program, onto: output) {
            pidMap = map
        } else {
            let isFirst = outputProgram == nil
            outputProgram = program
            programVersion = (programVersion + 1) & 0x1F
            pidMap = Dictionary(uniqueKeysWithValues: Self.outputPIDs(of: program).map { ($0, $0) })
            continuity.removeAll()
            events.append(.program(program))
            if !isFirst {
                pendingDiscontinuity = true
                statistics.reconfigurations += 1
                // The decoder needs a fresh picture in the new configuration, and content
                // can't be matched against a different stream layout.
                gateReason = .reconfiguration
                mode = .awaitingKeyframe
            }
        }
        if mode == .awaitingProgram { mode = .awaitingKeyframe }
    }

    private static func outputPIDs(of program: TSProgram) -> [UInt16] {
        var pids = program.carriedStreams.map(\.pid)
        if !pids.contains(program.pcrPID) { pids.append(program.pcrPID) }
        return pids
    }

    /// Same layout under different PIDs: map stream by stream (and the PCR PID alongside).
    private func pidMapping(from program: TSProgram, onto output: TSProgram) -> [UInt16: UInt16]? {
        var map: [UInt16: UInt16] = [:]
        for (source, target) in zip(program.carriedStreams, output.carriedStreams) { map[source.pid] = target.pid }
        let sourcePCRCarried = program.carriedStreams.contains { $0.pid == program.pcrPID }
        let outputPCRCarried = output.carriedStreams.contains { $0.pid == output.pcrPID }
        if sourcePCRCarried != outputPCRCarried { return nil }
        if sourcePCRCarried {
            guard map[program.pcrPID] == output.pcrPID else { return nil }
        } else {
            map[program.pcrPID] = output.pcrPID
        }
        return map
    }

    // MARK: - PES handling

    private func timingStream(of program: TSProgram) -> TSProgram.Stream? {
        program.video ?? program.audio.first
    }

    private func complete(_ unit: PESUnit, stream: TSProgram.Stream, program: TSProgram,
                          wallTime: Double, into output: inout [NormalizedUnit]) {
        var unit = unit
        guard let header = unit.parseHeader() else {
            statistics.corruptUnits += 1
            markDropped(sourcePID: unit.sourcePID)
            return
        }
        let isTiming = timingStream(of: program)?.pid == stream.pid
        if isTiming {
            handleTiming(&unit, header: header, stream: stream, wallTime: wallTime, into: &output)
        } else {
            handleFollower(&unit, header: header, stream: stream, into: &output)
        }
    }

    private func handleTiming(_ unit: inout PESUnit, header: PESUnit.Header, stream: TSProgram.Stream,
                              wallTime: Double, into output: inout [NormalizedUnit]) {
        guard let rawPTS = header.pts ?? header.dts else {
            // A timing PES without timestamps can't be placed on the timeline.
            if mode == .flowing { emit(&unit, header: header, stream: stream, kind: kindOf(stream), rawPTS: nil, rawDTS: nil,
                                       isKeyframe: false, isTiming: true, wallTime: wallTime, into: &output) }
            else { markDropped(sourcePID: unit.sourcePID) }
            return
        }
        let rawDTS = header.dts ?? rawPTS
        let isKeyframe: Bool
        let isInstantRefresh: Bool
        switch stream.kind {
        case .video(let codec):
            let inspection = AccessUnitInspector.inspect(unit, dataOffset: header.dataOffset, codec: codec)
            isKeyframe = inspection.isKeyframe
            isInstantRefresh = inspection.isInstantRefresh
        default:
            isKeyframe = true
            isInstantRefresh = true
        }
        let fingerprint = isKeyframe ? unit.fingerprint(dataOffset: header.dataOffset) : nil
        let picture = SplicePicture(pts: rawPTS, dts: rawDTS, fingerprint: fingerprint, isInstantRefresh: isInstantRefresh)
        if let last = lastSeenRawTiming {
            let delta = MPEGTS.signedDelta(rawDTS, last)
            if delta > 0, delta < MPEGTS.clockRate / 4 {
                timingDeltas.append(delta)
                if timingDeltas.count > 31 { timingDeltas.removeFirst() }
            }
        }
        lastSeenRawTiming = rawDTS

        switch mode {
        case .awaitingProgram:
            markDropped(sourcePID: unit.sourcePID)
            return
        case .awaitingKeyframe:
            guard isKeyframe, openGate(picture, wallTime: wallTime) else {
                markDropped(sourcePID: unit.sourcePID)
                return
            }
            releaseHeldFollowers(into: &output)
        case .deduplicating(let until, let since, let firstDropped):
            let delta = MPEGTS.signedDelta(rawDTS, until)
            if delta > 0, isKeyframe {
                let skipped = firstDropped.map { MPEGTS.seconds(MPEGTS.signedDelta(until, $0)) } ?? 0
                openAfterDeduplication(picture, skipped: max(0, skipped))
                releaseHeldFollowers(into: &output)
            } else {
                markDropped(sourcePID: unit.sourcePID)
                let dropped = firstDropped ?? rawDTS
                let droppedSpan = MPEGTS.signedDelta(rawDTS, dropped)
                if droppedSpan > configuration.maximumDeduplication || wallTime - since > 20 {
                    // Not the same content after all: splice at the next picture regardless.
                    gateReason = .timelineJump
                    mode = .awaitingKeyframe
                } else {
                    mode = .deduplicating(until: until, since: since, firstDropped: dropped)
                }
                return
            }
        case .flowing:
            if let last = lastEmittedRawTimingInConnection {
                let delta = MPEGTS.signedDelta(rawDTS, last)
                if delta < -configuration.jumpBackward || delta > configuration.jumpForward {
                    statistics.timelineJumps += 1
                    gateReason = .timelineJump
                    mode = .awaitingKeyframe
                    guard isKeyframe, openGate(picture, wallTime: wallTime) else {
                        markDropped(sourcePID: unit.sourcePID)
                        return
                    }
                }
            }
        }

        // Open-GOP leading pictures reference frames from before the splice; drop them.
        if let gate = dropLeadingPicturesBefore {
            if !isKeyframe, MPEGTS.signedDelta(rawPTS, gate) < 0 {
                markDropped(sourcePID: unit.sourcePID)
                return
            }
            if !isKeyframe { dropLeadingPicturesBefore = nil }
        }
        if let fingerprint {
            deliveredKeyframes.append(KeyframeRecord(dts: rawDTS, fingerprint: fingerprint))
            if deliveredKeyframes.count > deliveredKeyframeLimit { deliveredKeyframes.removeFirst(deliveredKeyframes.count / 4) }
        }
        emit(&unit, header: header, stream: stream, kind: kindOf(stream), rawPTS: rawPTS, rawDTS: rawDTS,
             isKeyframe: isKeyframe, isTiming: true, wallTime: wallTime, into: &output)
    }

    private func releaseHeldFollowers(into output: inout [NormalizedUnit]) {
        let held = heldFollowers
        heldFollowers.removeAll()
        for var entry in held {
            handleFollower(&entry.unit, header: entry.header, stream: entry.stream, into: &output)
        }
    }

    private func handleFollower(_ unit: inout PESUnit, header: PESUnit.Header, stream: TSProgram.Stream,
                                into output: inout [NormalizedUnit]) {
        guard mode == .flowing else {
            if hasOutput, mode != .awaitingProgram, kindOf(stream) == .audio {
                heldFollowers.append((unit, header, stream))
                if heldFollowers.count > 256 {
                    heldFollowers.removeFirst(64)
                    statistics.droppedUnits += 64
                }
            } else {
                markDropped(sourcePID: unit.sourcePID)
            }
            return
        }
        let kind = kindOf(stream)
        guard let rawPTS = header.pts else {
            emit(&unit, header: header, stream: stream, kind: kind, rawPTS: nil, rawDTS: nil, isKeyframe: false,
                 isTiming: false, wallTime: nil, into: &output)
            return
        }
        if kind == .audio {
            let outPTS = MPEGTS.wrap(rawPTS + offset)
            let outputPID = pidMap[stream.pid] ?? stream.pid
            if let last = lastOutAudioPTS[outputPID] {
                // Never replay audio already delivered. Audio from just before the splice picture
                // is welcome: muxers interleave audio behind video, so the old connection's audio
                // stops short of its last picture and this fills the hole instead of leaving silence.
                // Right after a splice the new audio must also clear the whole of the previous PES.
                let end = audioSpliceGuard.contains(outputPID) ? lastOutAudioEnd[outputPID] : nil
                if MPEGTS.signedDelta(outPTS, last) <= 0 || end.map({ MPEGTS.signedDelta(outPTS, $0) < -480 }) == true {
                    markDropped(sourcePID: unit.sourcePID)
                    return
                }
            } else if let gate = gatePTS, MPEGTS.signedDelta(rawPTS, gate) < -frameDuration {
                // At the very start, audio and picture begin together.
                markDropped(sourcePID: unit.sourcePID)
                return
            }
            if let reference = lastOutTiming, abs(MPEGTS.signedDelta(outPTS, reference)) > configuration.audioSanityWindow {
                markDropped(sourcePID: unit.sourcePID)
                return
            }
        }
        emit(&unit, header: header, stream: stream, kind: kind, rawPTS: rawPTS, rawDTS: header.dts, isKeyframe: false,
             isTiming: false, wallTime: nil, into: &output)
    }

    private func kindOf(_ stream: TSProgram.Stream) -> NormalizedUnit.Kind {
        switch stream.kind {
        case .video: return .video
        case .audio: return .audio
        case .metadata, .other: return .metadata
        }
    }

    // MARK: - Splicing

    /// Decides where the new timeline joins the old one. Returns false while still deduplicating.
    private func openGate(_ picture: SplicePicture, wallTime: Double) -> Bool {
        guard hasOutput, let lastOut = lastOutTiming else {
            offset = MPEGTS.wrap(configuration.initialTime - picture.dts)
            finishGate(picture, report: SpliceReport(kind: .start, skippedSeconds: 0, missingSeconds: 0))
            return true
        }
        var kind: SpliceReport.Kind
        var missing: Double = 0
        switch gateReason {
        case .reconnect:
            if let previous = lastEmittedRawTiming {
                let delta = MPEGTS.signedDelta(picture.dts, previous)
                let outage = max(0, wallTime - (lastEmittedWallTime ?? wallTime))
                let forwardLimit = MPEGTS.ticks(outage) + configuration.forwardSlack
                let resent = picture.fingerprint.map { deliveredKeyframes.contains(KeyframeRecord(dts: picture.dts, fingerprint: $0)) } ?? false
                if delta <= 0, delta >= -configuration.overlapLimit, resent {
                    mode = .deduplicating(until: previous, since: wallTime, firstDropped: picture.dts)
                    return false
                }
                if delta > 0, delta <= forwardLimit {
                    let frame = frameDuration
                    kind = delta <= frame + frame / 2 ? .seamless : .gapClosed
                    missing = max(0, MPEGTS.seconds(delta - frame))
                } else {
                    kind = .timebaseReset
                }
            } else {
                kind = .timebaseReset
            }
        case .timelineJump:
            kind = .timelineJump
        case .reconfiguration:
            kind = .reconfigured
        case .sourceDiscontinuity:
            kind = .timebaseReset
        case .firstConnection:
            kind = .start
        }
        offset = continuityOffset(pts: picture.pts, dts: picture.dts, lastOut: lastOut)
        finishGate(picture, report: SpliceReport(kind: kind, skippedSeconds: 0, missingSeconds: missing))
        return true
    }

    private func openAfterDeduplication(_ picture: SplicePicture, skipped: Double) {
        guard let lastOut = lastOutTiming else { return }
        let delta = lastEmittedRawTiming.map { MPEGTS.signedDelta(picture.dts, $0) } ?? frameDuration
        let missing = max(0, MPEGTS.seconds(delta - frameDuration))
        offset = continuityOffset(pts: picture.pts, dts: picture.dts, lastOut: lastOut)
        finishGate(picture, report: SpliceReport(kind: .overlapRemoved, skippedSeconds: skipped, missingSeconds: missing))
    }

    /// The offset that puts this picture one frame after the last one delivered — late enough
    /// for both its decode time and its presentation time, so neither clock runs backwards.
    private func continuityOffset(pts: Int64, dts: Int64, lastOut: Int64) -> Int64 {
        let frame = frameDuration
        let fromDTS = MPEGTS.wrap(lastOut + frame - dts)
        guard let maxPTS = maxOutVideoPTS else { return fromDTS }
        let fromPTS = MPEGTS.wrap(maxPTS + frame - pts)
        return MPEGTS.signedDelta(fromPTS, fromDTS) > 0 ? fromPTS : fromDTS
    }

    private func finishGate(_ picture: SplicePicture, report: SpliceReport) {
        mode = .flowing
        gatePTS = picture.pts
        dropLeadingPicturesBefore = picture.pts
        // Joining at an open-GOP I or CRA picture leaves the decoder's frame numbering and
        // references pointing into the old connection: announce it so AVPlayer restarts the decoder.
        if report.kind != .start, !picture.isInstantRefresh { pendingDiscontinuity = true }
        lastEmittedRawTimingInConnection = nil
        for key in continuity.keys { continuity[key]?.needsAnchor = true }
        spliceEpoch += 1
        audioSpliceGuard = Set(lastOutAudioPTS.keys)
        statistics.splices += report.kind == .start ? 0 : 1
        switch report.kind {
        case .overlapRemoved: statistics.overlapsRemoved += 1
        case .gapClosed: statistics.gapsClosed += 1
        case .timebaseReset: statistics.timebaseResets += 1
        default: break
        }
        events.append(.splice(report))
    }

    // MARK: - Output

    private func emit(_ unit: inout PESUnit, header: PESUnit.Header, stream: TSProgram.Stream, kind: NormalizedUnit.Kind,
                      rawPTS: Int64?, rawDTS: Int64?, isKeyframe: Bool, isTiming: Bool, wallTime: Double?,
                      into output: inout [NormalizedUnit]) {
        let outPTS = rawPTS.map { MPEGTS.wrap($0 + offset) }
        let outDTS = header.dts.map { MPEGTS.wrap($0 + offset) }
        unit.rewriteTimestamps(header, pts: outPTS, dts: outDTS)
        for index in unit.packets.indices { normalizePCR(&unit.packets[index]) }
        let outputPID = pidMap[stream.pid] ?? stream.pid
        remap(&unit.packets, to: outputPID)

        let timelineDTS = outDTS ?? outPTS
        if isTiming {
            if let time = timelineDTS { lastOutTiming = time }
            if let rawDTS {
                lastEmittedRawTiming = rawDTS
                lastEmittedRawTimingInConnection = rawDTS
            }
            if let wallTime { lastEmittedWallTime = wallTime }
        }
        if kind == .video, let outPTS {
            if let current = maxOutVideoPTS {
                if MPEGTS.signedDelta(outPTS, current) > 0 { maxOutVideoPTS = outPTS }
            } else {
                maxOutVideoPTS = outPTS
            }
        }
        if kind == .audio, let outPTS {
            if let last = lastOutAudioPTS[outputPID], audioEpoch[outputPID] == spliceEpoch {
                let step = MPEGTS.signedDelta(outPTS, last)
                if step > 0, step < MPEGTS.clockRate {
                    audioSteps[outputPID, default: []].append(step)
                    if (audioSteps[outputPID]?.count ?? 0) > 8 { audioSteps[outputPID]?.removeFirst() }
                }
            }
            var duration: Int64?
            if case .audio(.aac) = stream.kind { duration = unit.adtsDuration(dataOffset: header.dataOffset) }
            lastOutAudioEnd[outputPID] = MPEGTS.wrap(outPTS + (duration ?? audioSteps[outputPID]?.max() ?? 1_920))
            lastOutAudioPTS[outputPID] = outPTS
            audioEpoch[outputPID] = spliceEpoch
            audioSpliceGuard.remove(outputPID)
        }
        hasOutput = true

        let discontinuity = isTiming && pendingDiscontinuity
        if discontinuity { pendingDiscontinuity = false }
        guard let outputProgram else { return }
        output.append(NormalizedUnit(kind: kind, packets: unit.packets, pts: outPTS, dts: outDTS ?? outPTS,
                                     isKeyframe: isKeyframe, isTiming: isTiming, startsDiscontinuity: discontinuity,
                                     duration: isTiming ? frameDuration : 0,
                                     program: outputProgram, programVersion: programVersion))
    }

    private func normalizePCR(_ packet: inout TSPacket) {
        guard let base = packet.pcrBase else { return }
        packet.setPCRBase(base + offset)
    }

    /// Moves packets onto `outputPID` and continues that PID's continuity counter. Within a
    /// connection the source's own counter steps (including real losses) are preserved.
    private func remap(_ packets: inout [TSPacket], to outputPID: UInt16) {
        var state = continuity[outputPID] ?? ContinuityState()
        for index in packets.indices {
            if packets[index].pid != outputPID { packets[index].pid = outputPID }
            let source = packets[index].continuityCounter
            if state.needsAnchor {
                if let last = state.last {
                    let target = packets[index].hasPayload ? (last &+ 1) & 0x0F : last
                    state.offset = (target &- source) & 0x0F
                } else {
                    state.offset = 0
                }
                state.needsAnchor = false
            }
            let counter = (source &+ state.offset) & 0x0F
            packets[index].continuityCounter = counter
            state.last = counter
        }
        continuity[outputPID] = state
    }

    private func markDropped(sourcePID: UInt16) {
        statistics.droppedUnits += 1
        let outputPID = pidMap[sourcePID] ?? sourcePID
        continuity[outputPID, default: ContinuityState()].needsAnchor = true
    }
}
