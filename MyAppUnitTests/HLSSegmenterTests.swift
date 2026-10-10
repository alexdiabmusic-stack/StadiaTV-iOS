import Foundation
import Testing
@testable import BannerTV

/// Cutting a live transport stream into HLS segments that Apple's player can start from.
@Suite("HLS segmenter")
struct HLSSegmenterTests {

    private func segments(of data: Data, chunk: Int = 65_536, settings: HLSSegmenter.Settings = .init()) -> (segments: [HLSSegmenter.Segment], segmenter: HLSSegmenter) {
        let segmenter = HLSSegmenter(settings: settings)
        var out: [HLSSegmenter.Segment] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            out += segmenter.feed(data.subdata(in: offset..<end))
            offset = end
        }
        return (out, segmenter)
    }

    @Test("A segment is cut at every keyframe, and the one still being filled is held back")
    func cutsAtKeyframes() {
        // Two-second GOPs for 11 seconds: keyframes at 0, 2, 4, 6, 8 and 10 s, so five segments are complete.
        let result = segments(of: SyntheticTransportStream().data(seconds: 11))
        #expect(result.segmenter.problem == nil)
        #expect(result.segmenter.summary == "H.264 video, AAC audio")
        #expect(result.segments.map(\.sequence) == [0, 1, 2, 3, 4])
        #expect(result.segments.allSatisfy { abs($0.duration - 2.0) < 0.001 })
        #expect(result.segments.allSatisfy { !$0.discontinuity })
    }

    @Test("Every segment can be played from its start")
    func segmentsStandAlone() {
        let result = segments(of: SyntheticTransportStream().data(seconds: 11))
        #expect(!result.segments.isEmpty)
        for segment in result.segments {
            let contents = SegmentContents(segment.data)
            #expect(contents.remainder == 0, "whole packets only")
            #expect(contents.startsWithTables, "PAT, then PMT")
            #expect(contents.entries.filter { $0.pid == 0 }.count == 1, "one PAT, not the stream's own repeats too")
            #expect(contents.firstMediaEntry?.pid == 0x100 && contents.firstMediaEntry?.payloadUnitStart == true && contents.firstMediaEntry?.randomAccess == true,
                    "the first media packet starts a keyframe")
            #expect(contents.startsWithKeyframe(pid: 0x100, streamType: 0x1B))
            #expect(contents.videoFrames(pid: 0x100) == 50, "two seconds of 25 fps video")
            #expect(contents.audioFramesAreWhole(pid: 0x101), "no audio frame is cut in half, though the cut falls inside one")
            #expect(contents.countersAreContinuous())
        }
    }

    @Test("The program tables' counters run on from one segment to the next")
    func tableCounters() {
        let result = segments(of: SyntheticTransportStream().data(seconds: 11))
        let counters = result.segments.map { SegmentContents($0.data).entries[0].counter }
        #expect(counters == Array(0..<result.segments.count))
    }

    @Test("How the bytes arrive doesn't change the segments")
    func chunking() {
        let stream = SyntheticTransportStream().data(seconds: 9)
        let whole = segments(of: stream).segments.map(\.data)
        #expect(!whole.isEmpty)
        for chunk in [1, 7, 187, 188, 189, 1_000, 40_000] {
            #expect(segments(of: stream, chunk: chunk).segments.map(\.data) == whole, "chunks of \(chunk) bytes")
        }
    }

    @Test("Joining mid-stream waits for the first keyframe and skips the half-frame before it")
    func joiningMidStream() {
        let stream = SyntheticTransportStream().data(seconds: 11)
        let whole = segments(of: stream).segments
        // Start 3 seconds' worth of bytes in, in the middle of a packet.
        let skip = stream.count * 3 / 11 + 77
        let joined = segments(of: stream.subdata(in: skip..<stream.count)).segments
        #expect(joined.count >= 3)
        #expect(joined.first.map { SegmentContents($0.data).startsWithKeyframe(pid: 0x100, streamType: 0x1B) } == true)
        #expect(joined.allSatisfy { SegmentContents($0.data).audioFramesAreWhole(pid: 0x101) })
        #expect(joined.allSatisfy { abs($0.duration - 2.0) < 0.001 })
        #expect(joined.count < whole.count, "what came before the join is missing")
    }

    @Test("Keyframes closer together than the minimum are joined into one segment")
    func shortGOPs() {
        var stream = SyntheticTransportStream()
        stream.gopFrames = 13   // 0.52 s
        let result = segments(of: stream.data(seconds: 8))
        #expect(result.segments.count >= 3)
        #expect(result.segments.allSatisfy { abs($0.duration - 1.56) < 0.001 }, "three GOPs, the first multiple over 1.5 s")
        #expect(result.segments.allSatisfy { SegmentContents($0.data).startsWithKeyframe(pid: 0x100, streamType: 0x1B) })
    }

    @Test("A stream with no keyframes is still cut, at the maximum length")
    func noKeyframes() {
        var stream = SyntheticTransportStream()
        stream.gopFrames = 100_000   // only the very first frame is a keyframe
        let result = segments(of: stream.data(seconds: 26))
        #expect(result.segments.count == 2)
        #expect(result.segments.allSatisfy { abs($0.duration - 10.0) < 0.001 })
    }

    @Test("Video that Apple's player can't decode is reported at once, with no segments")
    func unsupportedVideo() {
        var stream = SyntheticTransportStream()
        stream.videoType = 0x02
        let result = segments(of: stream.data(seconds: 6))
        #expect(result.segments.isEmpty)
        #expect(result.segmenter.problem == "This channel's video is MPEG-2 video, which Apple's player can't decode.")
    }

    @Test("HEVC is cut at its IRAP pictures")
    func hevc() {
        var stream = SyntheticTransportStream()
        stream.videoType = 0x24
        let result = segments(of: stream.data(seconds: 7))
        #expect(result.segmenter.problem == nil && result.segmenter.summary == "HEVC video, AAC audio")
        #expect(result.segments.count == 3)
        #expect(result.segments.allSatisfy { SegmentContents($0.data).startsWithKeyframe(pid: 0x100, streamType: 0x24) })
    }

    @Test("Other audio formats are carried: AC-3 as an audio stream, MP2 too")
    func audioFormats() {
        for type: UInt8 in [0x81, 0x03, 0x11] {
            var stream = SyntheticTransportStream()
            stream.audioType = type
            let result = segments(of: stream.data(seconds: 6))
            #expect(result.segmenter.problem == nil)
            #expect(result.segments.count == 2, "audio type \(type)")
        }
    }

    @Test("A stream with only audio is cut on time")
    func audioOnly() {
        var stream = SyntheticTransportStream()
        stream.videoType = nil
        let result = segments(of: stream.data(seconds: 9))
        #expect(result.segmenter.problem == nil && result.segmenter.summary == "AAC audio")
        #expect(result.segments.count >= 3)
        #expect(result.segments.allSatisfy { $0.duration >= 2.0 && $0.duration < 2.1 })
        #expect(result.segments.allSatisfy { SegmentContents($0.data).audioFramesAreWhole(pid: 0x101) })
    }

    @Test("The 33-bit clock wrapping mid-stream doesn't upset the durations")
    func timestampWrap() {
        var stream = SyntheticTransportStream()
        stream.startTimestamp = TransportStream.timestampModulus - 90_000 * 3   // wraps three seconds in
        let result = segments(of: stream.data(seconds: 9))
        #expect(result.segments.count == 4)
        #expect(result.segments.allSatisfy { abs($0.duration - 2.0) < 0.001 })
    }

    @Test("After a reconnect the next segment is marked as following a break")
    func discontinuity() {
        let first = SyntheticTransportStream().data(seconds: 7)
        var second = SyntheticTransportStream()
        second.startTimestamp = 5_000_000   // a different clock
        let segmenter = HLSSegmenter()
        var out = segmenter.feed(first)
        let before = out.count
        segmenter.markDiscontinuity()
        out += segmenter.feed(second.data(seconds: 7))
        #expect(before == 3 && out.count == 6)
        #expect(out.map(\.discontinuity) == [false, false, false, true, false, false])
        #expect(out.allSatisfy { abs($0.duration - 2.0) < 0.001 }, "a new clock doesn't make a wild duration")
        #expect(out.map(\.sequence) == [0, 1, 2, 3, 4, 5])
    }

    @Test("A jump of the stream's own clock, as when a source restarts, cuts there and is marked as a break")
    func clockJump() {
        let first = SyntheticTransportStream().data(seconds: 7)
        var second = SyntheticTransportStream()
        second.startTimestamp = 5_000_000   // a different clock, with no reconnect to explain it
        let segmenter = HLSSegmenter()
        var out = segmenter.feed(first)
        #expect(out.count == 3)
        out += segmenter.feed(second.data(seconds: 7))
        #expect(segmenter.problem == nil)
        #expect(out.count == 7, "the half-built segment before the jump, then three of the new clock")
        #expect(out.map(\.discontinuity) == [false, false, false, false, true, false, false])
        #expect(abs(out[3].duration - 1.0) < 0.001, "the segment cut short by the jump is as long as its own frames, 25 at 25 fps, not as the data happened to arrive")
        #expect(out.suffix(3).allSatisfy { abs($0.duration - 2.0) < 0.001 }, "durations after the jump follow the new clock")
        #expect(out.map(\.sequence) == Array(0..<7))
        #expect(out.allSatisfy { SegmentContents($0.data).startsWithKeyframe(pid: 0x100, streamType: 0x1B) })
    }

    @Test("A step back in the clock is a break too")
    func clockStepsBack() {
        var early = SyntheticTransportStream()
        early.startTimestamp = 900_000 + 90_000 * 3600   // an hour in
        let late = SyntheticTransportStream()           // and then the clock starts again from the beginning
        let segmenter = HLSSegmenter()
        var out = segmenter.feed(early.data(seconds: 5))
        out += segmenter.feed(late.data(seconds: 5))
        #expect(out.contains { $0.discontinuity })
        #expect(out.filter(\.discontinuity).count == 1)
    }

    @Test("A stream carrying two programs is cut down to the first, and its PAT says so")
    func twoPrograms() throws {
        var stream = SyntheticTransportStream()
        stream.extraProgram = true
        let result = segments(of: stream.data(seconds: 5))
        let segment = try #require(result.segments.first)
        let contents = SegmentContents(segment.data)
        let pat = TransportStream.Packet(contents.bytes, at: 0)
        let section = try #require(pat.flatMap { packet -> [UInt8]? in
            var assembler = TransportStream.SectionAssembler()
            return assembler.feed(contents.bytes[packet.payload], payloadUnitStart: packet.payloadUnitStart)
        })
        let programs = try #require(TransportStream.parsePAT(section))
        #expect(programs.count == 1 && programs[0].number == 1 && programs[0].pmtPID == 0x1000)
    }

    @Test("Bytes that aren't packets are skipped, and the stream carries on after them")
    func garbage() {
        let stream = SyntheticTransportStream().data(seconds: 11)
        let middle = stream.count / 2
        var damaged = stream.subdata(in: 0..<middle)
        damaged.append(Data(repeating: 0xAA, count: 777))   // the stream is no longer on the packet grid
        damaged.append(stream.subdata(in: middle..<stream.count))
        let result = segments(of: damaged)
        #expect(result.segmenter.problem == nil)
        #expect(result.segments.count >= 4, "segments keep coming after the damage")
        #expect(result.segments.last.map { SegmentContents($0.data).startsWithKeyframe(pid: 0x100, streamType: 0x1B) } == true)
    }

    @Test("Something that isn't a transport stream is given up on rather than buffered for ever")
    func notATransportStream() {
        let segmenter = HLSSegmenter()
        let page = Data(repeating: UInt8(ascii: "x"), count: 64 * 1024)
        var segments: [HLSSegmenter.Segment] = []
        for _ in 0..<10 { segments += segmenter.feed(page) }
        #expect(segments.isEmpty)
        #expect(segmenter.problem == "The provider's stream isn't an MPEG transport stream.")
    }

    @Test("Nothing is cut before the program tables are known")
    func noTablesNoSegments() {
        // The stream's first tables are missing; they come round again after a second, and segmenting begins then.
        var stream = SyntheticTransportStream().data(seconds: 6)
        stream.removeSubrange(0..<(188 * 2))
        let result = segments(of: stream)
        #expect(result.segmenter.problem == nil)
        #expect(!result.segments.isEmpty)
        #expect(result.segments.allSatisfy { SegmentContents($0.data).startsWithTables })
    }
}
