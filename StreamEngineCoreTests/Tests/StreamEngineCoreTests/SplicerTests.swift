import Foundation
import Testing
@testable import StreamEngineCore

/// The splice layer: what reaches the decoder when connections drop, overlap, restart or change.
@Suite("Splicing reconnects into one timeline")
struct SplicerTests {
    private let initialTime = TSTimelineSplicer.Configuration().initialTime

    /// At a splice audio may overlap the previous frame by a few milliseconds or leave a short gap,
    /// but it never repeats, runs backwards or leaves an audible hole. (One AAC frame is 1920 ticks.)
    private func expectContinuousAudio(_ harness: PipelineHarness, maximumStep: Int64 = 2 * 1_920,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        let steps = harness.audioSteps
        #expect(!steps.isEmpty, sourceLocation: sourceLocation)
        #expect(steps.allSatisfy { $0 >= 1_920 - 480 && $0 <= maximumStep }, "audio steps \(Set(steps).sorted())",
                sourceLocation: sourceLocation)
    }

    @Test("The first connection starts at a keyframe on the output timeline, with its audio")
    func firstConnection() throws {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        harness.finish()

        let first = try #require(harness.videoUnits.first)
        #expect(first.isKeyframe)
        #expect(first.dts == initialTime)
        // The last picture was still arriving when the connection ended.
        #expect(harness.deliveredFrames == Array(0..<149))
        #expect(Set(harness.videoSteps) == [3_600])
        let firstAudio = try #require(harness.audioUnits.first?.pts)
        let firstPicture = try #require(first.pts)
        #expect(abs(MPEGTS.signedDelta(firstAudio, firstPicture)) <= 3_600)
        #expect(Set(harness.audioSteps) == [1_920])
        #expect(harness.spliceReports.map(\.kind) == [.start])
        #expect(harness.splicer.statistics.splices == 0)
    }

    @Test("A reconnect that re-sends the last keyframe takes over from it: nothing skipped, nothing repeated")
    func resumedAtLastKeyframe() throws {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        // The provider's burst re-sends the last two seconds, from the last keyframe delivered.
        harness.connection(stream.bytes(seconds: 6, firstFrame: 100))
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<249))
        #expect(Set(harness.videoSteps) == [3_600])
        #expect(harness.spliceReports.map(\.kind) == [.start, .resumed])
        let splice = try #require(harness.spliceReports.last)
        #expect(splice.missingSeconds == 0)
        #expect(abs(splice.skippedSeconds - 1.96) < 0.001)
        #expect(!harness.units.contains { $0.startsDiscontinuity })
        expectContinuousAudio(harness)
        // The GOP the drop cut short never reached a segment twice.
        let total = harness.segments.reduce(0) { $0 + $1.duration }
        #expect(abs(total - 249 * 0.04) < 0.001)
        for (previous, next) in zip(harness.segments, harness.segments.dropFirst()) {
            #expect(abs(previous.programmeEnd - next.programmeStart) < 0.000_001)
        }
        #expect(harness.segments.allSatisfy { $0.startsWithKeyframe })
    }

    @Test("A burst starting before the last keyframe is skipped up to it, then taken over from it")
    func resumedAfterSkippingResentProgramme() throws {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        harness.connection(stream.bytes(seconds: 6, firstFrame: 10))
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<159))
        #expect(harness.spliceReports.map(\.kind) == [.start, .resumed])
        let splice = try #require(harness.spliceReports.last)
        // Frames 50–99 were re-sent and skipped, 100–148 re-sent and replaced.
        #expect(abs(splice.skippedSeconds - (2.0 + 1.96)) < 0.001)
        expectContinuousAudio(harness)
    }

    @Test("An open-GOP stream resumed at its last keyframe needs no discontinuity")
    func resumedOpenGOP() {
        var stream = SyntheticTransportStream()
        stream.openGOP = true
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        harness.connection(stream.bytes(seconds: 6, firstFrame: 100))
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<249))
        #expect(harness.spliceReports.map(\.kind) == [.start, .resumed])
        #expect(!harness.units.contains { $0.startsDiscontinuity })
        #expect(!harness.segments.contains { $0.isDiscontinuity })
    }

    @Test("Without a held GOP, re-sent programme is skipped up to the next keyframe")
    func overlapRemoved() throws {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.holdsTail = false
        harness.connection(stream.bytes(seconds: 6))
        // The provider's burst re-sends the last two seconds the reserve already holds.
        harness.connection(stream.bytes(seconds: 6, firstFrame: 100))
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<149) + Array(150..<249))
        #expect(Set(harness.videoSteps) == [3_600])
        #expect(harness.spliceReports.map(\.kind) == [.start, .overlapRemoved])
        let splice = try #require(harness.spliceReports.last)
        #expect(abs(splice.skippedSeconds - 1.92) < 0.001)
        #expect(abs(splice.missingSeconds - 0.04) < 0.001)
        #expect(harness.splicer.statistics.overlapsRemoved == 1)
        #expect(!harness.units.contains { $0.startsDiscontinuity })
        expectContinuousAudio(harness)
    }

    enum Restart: String, CaseIterable, CustomTestStringConvertible {
        case behind, ahead, zero
        var testDescription: String { rawValue }
    }

    @Test("A restarted encoder's new clock is re-timed, never mistaken for re-sent programme", arguments: Restart.allCases)
    func restartedEncoder(_ restart: Restart) {
        var first = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.connection(first.bytes(seconds: 6))
        let lastDelivered = first.pts(frame: 148)
        let start: Int64
        switch restart {
        case .behind: start = lastDelivered - 25 * 3_600
        case .ahead: start = lastDelivered + 3_600 * 90_000
        case .zero: start = 0
        }
        var restarted = SyntheticTransportStream(startPTS: MPEGTS.wrap(start), content: 1)
        harness.connection(restarted.bytes(seconds: 6))
        harness.finish()

        #expect(harness.spliceReports.map(\.kind) == [.start, .timebaseReset])
        let before = (0..<149).map { SyntheticTransportStream.Picture(frame: $0, content: 0) }
        let after = (0..<149).map { SyntheticTransportStream.Picture(frame: $0, content: 1) }
        #expect(harness.deliveredPictures == before + after)
        #expect(Set(harness.videoSteps) == [3_600])
        #expect(!harness.units.contains { $0.startsDiscontinuity })
        expectContinuousAudio(harness)
    }

    @Test("Programme missed during an outage is closed up instead of freezing the picture")
    func gapClosed() throws {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        // Five seconds of outage while the channel carried on live; the reconnect lands mid-GOP.
        harness.connection(stream.bytes(seconds: 6, firstFrame: 275), outageBefore: 5)
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<149) + Array(300..<424))
        #expect(Set(harness.videoSteps) == [3_600])
        #expect(harness.spliceReports.map(\.kind) == [.start, .gapClosed])
        let splice = try #require(harness.spliceReports.last)
        #expect(abs(splice.missingSeconds - 6.04) < 0.001)
        expectContinuousAudio(harness)
    }

    @Test("A reconnect that starts just after the tables still joins at its first keyframe")
    func reconnectWithoutTables() {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        // The new connection begins with a keyframe; its own PAT and PMT only follow ten frames later.
        harness.connection(Array(stream.bytes(seconds: 6, firstFrame: 150).dropFirst(2 * 188)))
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<149) + Array(150..<299))
        #expect(harness.spliceReports.map(\.kind) == [.start, .gapClosed])
        #expect(Set(harness.videoSteps) == [3_600])
        expectContinuousAudio(harness)
    }

    @Test("Continuity counters run on unbroken across every kind of splice")
    func continuityAcrossSplices() {
        var stream = SyntheticTransportStream()
        var restarted = SyntheticTransportStream(startPTS: 5_000_000, content: 1)
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        harness.connection(stream.bytes(seconds: 6, firstFrame: 100))
        harness.connection(restarted.bytes(seconds: 6))
        harness.connection(restarted.bytes(seconds: 6, firstFrame: 200), outageBefore: 3)
        harness.finish()

        #expect(harness.spliceReports.map(\.kind) == [.start, .resumed, .timebaseReset, .gapClosed])
        let packets = harness.units.flatMap(\.packets)
        #expect(Set(packets.map(\.pid)) == [0x100, 0x101])
        var last: [UInt16: UInt8] = [:]
        var breaks = 0
        for packet in packets {
            if let previous = last[packet.pid], packet.continuityCounter != (previous &+ 1) & 0x0F { breaks += 1 }
            last[packet.pid] = packet.continuityCounter
        }
        #expect(breaks == 0)
        #expect(Set(harness.videoSteps) == [3_600])
        expectContinuousAudio(harness)
    }

    @Test("The same channel under different PIDs is remapped onto the output program")
    func pidChange() {
        var first = SyntheticTransportStream()
        var moved = SyntheticTransportStream(startPTS: first.pts(frame: 150))
        moved.videoPID = 0x200
        moved.audioPID = 0x201
        moved.pmtPID = 0x1100
        var harness = PipelineHarness()
        harness.connection(first.bytes(seconds: 6))
        harness.connection(moved.bytes(seconds: 4))
        harness.finish()

        #expect(Set(harness.units.flatMap(\.packets).map(\.pid)) == [0x100, 0x101])
        #expect(harness.events.filter { if case .program = $0 { true } else { false } }.count == 1)
        #expect(Set(harness.units.map(\.programVersion)) == [1])
        #expect(!harness.units.contains { $0.startsDiscontinuity })
        #expect(!harness.segments.contains { $0.isDiscontinuity })
        #expect(harness.spliceReports.map(\.kind) == [.start, .gapClosed])
        #expect(harness.deliveredFrames == Array(0..<149) + Array(0..<99))
        #expect(Set(harness.videoSteps) == [3_600])
    }

    @Test("A codec change starts a new output program behind a discontinuity")
    func codecChange() throws {
        var first = SyntheticTransportStream()
        var hevc = SyntheticTransportStream(startPTS: first.pts(frame: 150), content: 2)
        hevc.videoStreamType = 0x24
        var harness = PipelineHarness()
        harness.connection(first.bytes(seconds: 6))
        harness.connection(hevc.bytes(seconds: 4))
        harness.finish()

        #expect(harness.spliceReports.map(\.kind) == [.start, .reconfigured])
        let flagged = harness.units.filter(\.startsDiscontinuity)
        #expect(flagged.count == 1)
        let firstHEVC = try #require(flagged.first)
        #expect(firstHEVC.kind == .video && firstHEVC.isKeyframe)
        #expect(firstHEVC.program.video?.kind == .video(.hevc))
        #expect(firstHEVC.programVersion == 2)
        #expect(harness.deliveredPictures.filter { $0.content == 2 }.map(\.frame) == Array(0..<99))
        #expect(harness.segments.map(\.isDiscontinuity) == [false, false, false, true, false])

        // The segment after the change announces HEVC in its own PMT.
        let segment = try #require(harness.segments.first { $0.isDiscontinuity })
        let packets = transportPackets([UInt8](segment.data))
        #expect(packets.first?.pid == 0)
        var assembler = PSISectionAssembler()
        let pmt = try #require(assembler.push(packets[1]).first)
        #expect(PSITables.parsePMT(pmt, pmtPID: 0x1000)?.video?.kind == .video(.hevc))
    }

    @Test("Joining a reconnect at an open-GOP picture is announced as a discontinuity")
    func openGOPSplice() throws {
        var stream = SyntheticTransportStream()
        stream.openGOP = true
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        harness.connection(stream.bytes(seconds: 6, firstFrame: 175))
        harness.finish()

        #expect(harness.spliceReports.map(\.kind) == [.start, .gapClosed])
        #expect(harness.deliveredFrames == Array(0..<149) + Array(200..<324))
        let flagged = harness.videoUnits.filter(\.startsDiscontinuity)
        #expect(flagged.count == 1)
        #expect(flagged.first.flatMap(SyntheticTransportStream.picture(of:))?.frame == 200)
        #expect(harness.segments.filter(\.isDiscontinuity).count == 1)
        // Within a connection, open-GOP keyframes still start segments.
        #expect(harness.segments.prefix(3).allSatisfy { $0.startsWithKeyframe })
    }

    @Test("A clock jump inside one connection is repaired at the next keyframe")
    func timelineJump() {
        var stream = SyntheticTransportStream()
        var bytes = stream.bytes(seconds: 4)
        stream.startPTS += 3_600 * 90_000
        bytes += stream.bytes(seconds: 4, firstFrame: 100)
        var harness = PipelineHarness()
        harness.connection(bytes)
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<199))
        #expect(Set(harness.videoSteps) == [3_600])
        #expect(harness.spliceReports.map(\.kind) == [.start, .timelineJump])
        #expect(harness.splicer.statistics.timelineJumps == 1)
        // Audio that arrived before the jump was detected is dropped rather than played an hour out.
        expectContinuousAudio(harness, maximumStep: 9_000)
    }

    @Test("Source timestamps crossing the 33-bit wrap stay continuous")
    func wrap() {
        var stream = SyntheticTransportStream(startPTS: MPEGTS.timestampModulo - 2 * 90_000)
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<149))
        #expect(Set(harness.videoSteps) == [3_600])
        #expect(Set(harness.audioSteps) == [1_920])
        #expect(harness.spliceReports.map(\.kind) == [.start])
        #expect(harness.segments.map { ($0.duration * 1_000).rounded() } == [2_000, 2_000, 1_960])
    }

    @Test("A radio channel is timed and segmented by its audio")
    func radio() {
        var stream = SyntheticTransportStream()
        stream.includeVideo = false
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        harness.finish()

        #expect(harness.units.count > 250)
        #expect(harness.units.allSatisfy { $0.kind == .audio && $0.isTiming && $0.isKeyframe })
        #expect(Set(harness.audioSteps) == [1_920])
        #expect(harness.segments.count >= 4)
        #expect(harness.segments.allSatisfy { $0.startsWithKeyframe && $0.duration > 0.7 && $0.duration < 2.1 })
        let total = harness.segments.reduce(0) { $0 + $1.duration }
        #expect(abs(total - Double(harness.units.count) * 1_920 / 90_000) < 0.001)
    }

    @Test("A drop keeps the audio the connection delivered whole; only the open picture is lost")
    func wholeAudioAtDrop() throws {
        var stream = SyntheticTransportStream()
        let bytes = stream.bytes(seconds: 2)
        var harness = PipelineHarness()
        harness.holdsTail = false
        harness.connection(bytes)
        harness.connection(stream.bytes(seconds: 2, firstFrame: 50))
        harness.finish()

        let firstConnection = harness.units[..<harness.connectionStarts[1]]
        // Audio PES announce their length, so the last one sent, whole, is delivered.
        let offset = MPEGTS.signedDelta(try #require(harness.videoUnits.first?.pts), stream.pts(frame: 0))
        let lastSent = try #require(pesUnits(in: bytes, pid: stream.audioPID).last?.parseHeader()?.pts)
        let lastDelivered = try #require(firstConnection.last { $0.kind == .audio }?.pts)
        #expect(MPEGTS.signedDelta(lastDelivered, lastSent) == offset)
        // A video PES doesn't say where it ends: the last picture could have been cut short.
        #expect(firstConnection.filter { $0.kind == .video }.count == 49)
        #expect(harness.spliceReports.map(\.kind) == [.start, .gapClosed])
        expectContinuousAudio(harness)
    }

    @Test("Re-sent audio straddling a splice is cut at an AAC frame, not dropped whole")
    func straddlingAudioTrimmed() throws {
        var stream = SyntheticTransportStream()
        stream.audioFramesPerPES = 8
        let start = stream.bytes(seconds: 4)
        let resent = stream.bytes(seconds: 8, firstFrame: 100)
        var harness = PipelineHarness()
        harness.holdsTail = false
        // The drop tears frame 130; the reconnect re-sends from frame 100, so the splice skips to
        // frame 150 and the audio re-sent around it overlaps what was already played.
        let pictures = transportPackets(resent).indices.filter {
            let packet = transportPackets(resent)[$0]
            return packet.pid == stream.videoPID && packet.payloadUnitStart
        }
        harness.connection(start + resent[..<((pictures[30] + 2) * 188 + 50)])
        harness.connection(resent)
        harness.finish()

        #expect(harness.spliceReports.map(\.kind) == [.start, .overlapRemoved])
        #expect(harness.splicer.statistics.trimmedAudioUnits == 1)
        let spans = try harness.audioUnits.map { unit -> (start: Int64, end: Int64) in
            let pes = PESUnit(sourcePID: stream.audioPID, packets: unit.packets)
            let header = try #require(pes.parseHeader())
            let start = try #require(unit.pts)
            return (start, start + (pes.adtsDuration(dataOffset: header.dataOffset) ?? 0))
        }
        // Each PES picks up where the previous one ended, give or take the 480-tick tolerance.
        let gaps = zip(spans.dropFirst(), spans).map { MPEGTS.signedDelta($0.start, $1.end) }
        #expect(gaps.allSatisfy { $0 >= -480 && $0 < 1_920 }, "audio gaps \(Set(gaps).sorted())")
    }

    @Test("HLS segments join seamlessly across a reconnect, the last picture of the last one included")
    func wholeSegmentsAcrossReconnect() {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.segmentedIngest = true
        // Two-second segments; the reconnect resumes right after the last one delivered.
        harness.connection(stream.bytes(seconds: 2) + stream.bytes(seconds: 2, firstFrame: 50))
        harness.connection(stream.bytes(seconds: 2, firstFrame: 100))
        harness.finish()

        #expect(harness.deliveredFrames == Array(0..<150))
        #expect(harness.spliceReports.map(\.kind) == [.start, .seamless])
        #expect(harness.spliceReports.last?.missingSeconds == 0)
        #expect(Set(harness.videoSteps) == [3_600])
        // Every audio frame in place across the splice: none lost, none overlapping.
        #expect(Set(harness.audioSteps) == [1_920])
    }

    @Test("An HLS discontinuity keeps the last picture of the segment before it")
    func pictureBeforeDiscontinuity() {
        var first = SyntheticTransportStream()
        var second = SyntheticTransportStream(startPTS: 5_000_000, content: 1)
        var harness = PipelineHarness()
        harness.segmentedIngest = true
        harness.connection(first.bytes(seconds: 2))
        harness.sourceDiscontinuity()
        harness.feed(second.bytes(seconds: 2))
        harness.finish()

        let pictures = harness.deliveredPictures
        #expect(pictures.map(\.frame) == Array(0..<50) + Array(0..<50))
        #expect(pictures.map(\.content) == Array(repeating: 0, count: 50) + Array(repeating: 1, count: 50))
        #expect(harness.spliceReports.map(\.kind) == [.start, .timebaseReset])
        #expect(Set(harness.videoSteps) == [3_600])
        expectContinuousAudio(harness)
    }

    @Test("A connection that dies mid-picture never leaks the torn picture into the next one")
    func tornPicture() {
        var stream = SyntheticTransportStream()
        let bytes = stream.bytes(seconds: 6)
        var harness = PipelineHarness()
        // Cut 100 bytes into a packet in the middle of the stream.
        let cut = 188 * 400 + 100
        harness.connection(Array(bytes[..<cut]))
        harness.connection(stream.bytes(seconds: 6, firstFrame: 150))
        harness.finish()

        let frames = harness.deliveredFrames
        #expect(frames == frames.sorted())
        #expect(Set(frames).count == frames.count)
        #expect(Set(harness.videoSteps) == [3_600])
        #expect(harness.splicer.statistics.corruptUnits == 0)
        expectContinuousAudio(harness)
    }
}
