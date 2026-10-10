import Foundation
import Testing
@testable import BannerTV

/// Reading the parts of an MPEG transport stream that cutting it into HLS needs.
@Suite("Transport stream parsing")
struct TransportStreamTests {

    @Test("The CRC matches the published check value for CRC-32/MPEG-2")
    func crc() {
        #expect(TransportStream.crc32(Array("123456789".utf8)[...]) == 0x0376_E6E7)
    }

    @Test("A PAT made for one program reads back, and a damaged one is refused")
    func patRoundTrip() throws {
        let section = TransportStream.makePAT(program: 7, pmtPID: 0x1234)
        #expect(TransportStream.isIntact(section))
        let programs = try #require(TransportStream.parsePAT(section))
        #expect(programs.count == 1 && programs[0].number == 7 && programs[0].pmtPID == 0x1234)

        var damaged = section
        damaged[9] ^= 0x01
        #expect(TransportStream.parsePAT(damaged) == nil, "the CRC no longer matches")
    }

    @Test("A PMT lists the streams and what they are")
    func pmt() throws {
        let stream = SyntheticTransportStream()
        let data = [UInt8](stream.data(seconds: 0.2))
        var assembler = TransportStream.SectionAssembler()
        var program: TransportStream.Program?
        var offset = 0
        while let packet = TransportStream.Packet(data, at: offset) {
            if packet.pid == 0x1000, let section = assembler.feed(data[packet.payload], payloadUnitStart: packet.payloadUnitStart) {
                program = TransportStream.parsePMT(section, pmtPID: 0x1000)
                break
            }
            offset += 188
        }
        let found = try #require(program)
        #expect(found.number == 1 && found.pcrPID == 0x100)
        #expect(found.streams.map(\.pid) == [0x100, 0x101])
        #expect(found.video?.name == "H.264 video" && found.video?.isPlayableVideo == true)
        #expect(found.summary == "H.264 video, AAC audio")
        #expect(found.carriedPIDs == [0x100, 0x101])
    }

    @Test("Stream types are told apart: only H.264 and HEVC video can be played")
    func streamTypes() {
        func stream(_ type: UInt8, _ descriptors: [UInt8] = []) -> TransportStream.ElementaryStream {
            .init(pid: 0x100, type: type, descriptors: descriptors)
        }
        #expect(stream(0x1B).isPlayableVideo && stream(0x24).isPlayableVideo)
        #expect(!stream(0x02).isPlayableVideo, "MPEG-2 video has no decoder on iOS or tvOS")
        #expect(stream(0x02).kind == .video && stream(0x02).name == "MPEG-2 video")
        #expect(stream(0x0F).kind == .audio && stream(0x03).name == "MPEG audio")
        #expect(stream(0x81).name == "AC-3 audio" && stream(0x87).name == "E-AC-3 audio")
        #expect(stream(0x06).kind == .other, "private data is not audio unless a descriptor says so")
        #expect(stream(0x06, [0x6A, 0x01, 0x00]).kind == .audio && stream(0x06, [0x6A, 0x01, 0x00]).name == "AC-3 audio")
        #expect(stream(0x06, [0x7A, 0x00]).name == "E-AC-3 audio")
    }

    @Test("A PES header yields its timestamps")
    func pesTimestamps() throws {
        // PTS 0x123456789 (33 bits) and DTS one frame earlier, encoded as the standard lays them out.
        func encode(_ value: UInt64, prefix: UInt8) -> [UInt8] {
            [prefix | UInt8((value >> 29) & 0x0E) | 1, UInt8((value >> 22) & 0xFF), UInt8((value >> 14) & 0xFE) | 1,
             UInt8((value >> 7) & 0xFF), UInt8((value << 1) & 0xFE) | 1]
        }
        let pts: UInt64 = 0x1_2345_6789 & 0x1_FFFF_FFFF
        let payload = [0, 0, 1, 0xE0, 0, 0, 0x80, 0xC0, 10] + encode(pts, prefix: 0x30) + encode(pts - 3600, prefix: 0x10) + [0xAA]
        let header = try #require(TransportStream.parsePESHeader(payload[...]))
        #expect(header.pts == pts && header.dts == pts - 3600)
        #expect(header.dataOffset == 19 && payload[header.dataOffset] == 0xAA)
        #expect(TransportStream.parsePESHeader([1, 2, 3, 4, 5, 6, 7, 8, 9, 10][...]) == nil, "no start code")
    }

    @Test("Time across a wrap of the 33-bit clock is a short step forward, and a step back stays negative")
    func timestampArithmetic() {
        let modulus = TransportStream.timestampModulus
        #expect(TransportStream.seconds(from: 90_000, to: 270_000) == 2)
        #expect(TransportStream.seconds(from: modulus - 90_000, to: 90_000) == 2, "across the wrap")
        #expect(TransportStream.seconds(from: 270_000, to: 90_000) == -2)
    }

    @Test("The first slice of an access unit says whether it starts a keyframe")
    func keyframes() {
        let aud: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0]
        let sps: [UInt8] = [0, 0, 1, 0x67, 0x42, 0, 0x1E]
        let pps: [UInt8] = [0, 0, 1, 0x68, 0xCE]
        let idr: [UInt8] = [0, 0, 1, 0x65, 0x88]
        let slice: [UInt8] = [0, 0, 1, 0x41, 0x9A]

        #expect(TransportStream.classifyKeyframe(streamType: 0x1B, data: aud + sps + pps + idr, final: false) == .yes)
        #expect(TransportStream.classifyKeyframe(streamType: 0x1B, data: aud + slice, final: false) == .no)
        #expect(TransportStream.classifyKeyframe(streamType: 0x1B, data: aud + sps + pps, final: false) == .undecided, "the slice hasn't arrived")
        #expect(TransportStream.classifyKeyframe(streamType: 0x1B, data: aud + sps + pps, final: true) == .yes, "parameter sets alone are taken as a keyframe")
        #expect(TransportStream.classifyKeyframe(streamType: 0x1B, data: aud, final: true) == .no)
        #expect(TransportStream.classifyKeyframe(streamType: 0x1B, data: [0, 0, 1], final: false) == .undecided)

        // HEVC: the NAL type sits in bits 1...6 of the first header byte.
        let hevcIDR: [UInt8] = [0, 0, 1, 0x26, 0x01]
        let hevcTrail: [UInt8] = [0, 0, 1, 0x02, 0x01]
        #expect(TransportStream.classifyKeyframe(streamType: 0x24, data: hevcIDR, final: false) == .yes)
        #expect(TransportStream.classifyKeyframe(streamType: 0x24, data: hevcTrail, final: false) == .no)
    }

    @Test("A section split over packets is put back together")
    func sectionAssembly() throws {
        let section = TransportStream.makePAT(program: 1, pmtPID: 0x100)
        var assembler = TransportStream.SectionAssembler()
        // Pointer field, then the first half of the section; the rest in a second packet with no pointer.
        let half = section.count / 2
        #expect(assembler.feed(([0] + section[..<half])[...], payloadUnitStart: true) == nil)
        #expect(assembler.feed(section[half...], payloadUnitStart: false) == section)
        // Padding after the section is ignored.
        #expect(assembler.feed(([0] + section + [0xFF, 0xFF, 0xFF])[...], payloadUnitStart: true) == section)
        // A continuation with nothing started is ignored.
        #expect(assembler.feed([1, 2, 3][...], payloadUnitStart: false) == nil)
    }

    @Test("Packet headers: adaptation field flags, payload range and counters")
    func packetHeader() throws {
        var bytes = [UInt8](repeating: 0xFF, count: 188)
        bytes[0] = 0x47; bytes[1] = 0x41; bytes[2] = 0x00   // payload unit start, PID 0x100
        bytes[3] = 0x37                                       // adaptation and payload, counter 7
        bytes[4] = 7; bytes[5] = 0x50                         // 7-byte adaptation field: random access + PCR
        let packet = try #require(TransportStream.Packet(bytes, at: 0))
        #expect(packet.pid == 0x100 && packet.payloadUnitStart && packet.continuityCounter == 7)
        #expect(packet.randomAccess && !packet.discontinuity && !packet.hasError)
        #expect(packet.payload == 12..<188)

        bytes[3] = 0x20                                       // adaptation only
        #expect(try #require(TransportStream.Packet(bytes, at: 0)).payload.isEmpty)
        bytes[3] = 0x10; bytes[1] = 0x80                      // payload only, transport error
        let broken = try #require(TransportStream.Packet(bytes, at: 0))
        #expect(broken.hasError && broken.payload == 4..<188)

        #expect(TransportStream.Packet(Array(bytes.dropLast()), at: 0) == nil, "cut short")
        bytes[0] = 0x00
        #expect(TransportStream.Packet(bytes, at: 0) == nil, "no sync byte")
    }

    @Test("Sync is found by three packets in step, not by one stray 0x47")
    func sync() {
        let stream = [UInt8](SyntheticTransportStream().data(seconds: 0.4))
        #expect(TransportStream.firstSync(in: stream) == 0)
        // Junk, including a lone sync byte, in front of the stream.
        let junk: [UInt8] = [1, 2, 0x47, 3, 4, 5, 6, 7, 8, 9, 10]
        #expect(TransportStream.firstSync(in: junk + stream) == junk.count)
        #expect(TransportStream.firstSync(in: [UInt8](repeating: 0x47, count: 100)) == nil, "bytes that are only sync-shaped")
    }
}
