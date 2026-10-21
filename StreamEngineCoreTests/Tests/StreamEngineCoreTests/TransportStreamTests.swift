import Foundation
import Testing
@testable import StreamEngineCore

@Suite("Transport stream parsing")
struct TransportStreamTests {
    /// One PES on PID 0x100, packetized like an encoder would.
    private func pesUnit(_ pes: [UInt8], pcr: Int64? = nil, randomAccess: Bool = false) -> PESUnit {
        var stream = SyntheticTransportStream()
        let bytes = stream.packetize(pid: 0x100, pes: pes, pcr: pcr, randomAccess: randomAccess)
        return PESUnit(sourcePID: 0x100, packets: transportPackets(bytes))
    }

    private func inspection(of es: [UInt8], codec: TSProgram.VideoCodec, randomAccess: Bool = false) throws -> AccessUnitInspector.Result {
        let unit = pesUnit(SyntheticTransportStream.pesHeader(streamID: 0xE0, pts: 900_000, dts: nil) + es, randomAccess: randomAccess)
        let header = try #require(unit.parseHeader())
        return AccessUnitInspector.inspect(unit, dataOffset: header.dataOffset, codec: codec)
    }

    // MARK: - Timestamps

    @Test("Timestamp arithmetic survives the 33-bit wrap")
    func timestampArithmetic() {
        #expect(MPEGTS.signedDelta(5, MPEGTS.timestampModulo - 5) == 10)
        #expect(MPEGTS.signedDelta(MPEGTS.timestampModulo - 5, 5) == -10)
        #expect(MPEGTS.signedDelta(900_000, 0) == 900_000)
        #expect(MPEGTS.wrap(MPEGTS.timestampModulo + 7) == 7)
        #expect(MPEGTS.wrap(-1) == MPEGTS.timestampMask)
        #expect(MPEGTS.ticks(1.5) == 135_000)
        #expect(MPEGTS.seconds(45_000) == 0.5)
    }

    // MARK: - Packet alignment

    @Test("Leading garbage is skipped and every packet comes out intact")
    func alignerSkipsGarbage() {
        var stream = SyntheticTransportStream()
        let bytes = stream.bytes(seconds: 1)
        var garbage = [UInt8](repeating: 0x00, count: 100)
        garbage[3] = 0x47
        garbage[50] = 0x47
        let input = garbage + bytes
        var aligner = TSPacketAligner()
        var packets: [TSPacket] = []
        for start in stride(from: 0, to: input.count, by: 50) {
            packets += aligner.push(input[start..<min(start + 50, input.count)])
        }
        #expect(packets.count == bytes.count / 188)
        #expect(aligner.discardedBytes == 100)
        #expect(packets.flatMap(\.bytes) == bytes)
    }

    @Test("A torn packet is dropped on reset and a connection starting mid-packet resynchronises")
    func alignerReset() {
        var stream = SyntheticTransportStream()
        let bytes = stream.bytes(seconds: 1)
        var aligner = TSPacketAligner()
        #expect(aligner.push(bytes[0..<1_000]).count == 5)
        #expect(aligner.pendingByteCount == 60)
        aligner.reset()
        #expect(aligner.discardedBytes == 60)
        #expect(aligner.pendingByteCount == 0)

        let next = aligner.push(bytes[1_000...])
        #expect(next.count == (bytes.count - 1_128) / 188)
        #expect(aligner.discardedBytes == 60 + 128)
        #expect(next.first?.bytes == Array(bytes[1_128..<1_316]))
    }

    @Test("Lost sync in mid-stream costs only the bytes that broke it")
    func alignerRecoversFromLostSync() {
        var stream = SyntheticTransportStream()
        let bytes = stream.bytes(seconds: 1)
        let damaged = Array(bytes[0..<940]) + [1, 2, 3, 4, 5] + Array(bytes[940...])
        var aligner = TSPacketAligner()
        let packets = aligner.push(damaged)
        #expect(packets.count == bytes.count / 188)
        #expect(aligner.syncLosses == 1)
        #expect(aligner.discardedBytes == 5)
        #expect(packets.flatMap(\.bytes) == bytes)
    }

    // MARK: - Program tables

    @Test("PAT and PMT survive a round trip; a corrupted byte is rejected")
    func programTablesRoundTrip() throws {
        let program = TSProgram(
            programNumber: 7, pmtPID: 0x1000, pcrPID: 0x100, programDescriptors: [0x05, 0x04, 0x48, 0x44, 0x4D, 0x56],
            streams: [
                .init(pid: 0x100, streamType: 0x1B, kind: .video(.h264), descriptors: []),
                .init(pid: 0x101, streamType: 0x0F, kind: .audio(.aac), descriptors: [0x0A, 0x04, 0x65, 0x6E, 0x67, 0x00]),
                .init(pid: 0x102, streamType: 0x06, kind: .other, descriptors: [0x56, 0x05, 0x65, 0x6E, 0x67, 0x09, 0x00]),
                .init(pid: 0x103, streamType: 0x06, kind: .audio(.ac3), descriptors: [0x6A, 0x01, 0x00]),
                .init(pid: 0x104, streamType: 0x15, kind: .metadata, descriptors: [])
            ])
        let pat = PSITables.makePAT(for: program, version: 3)
        #expect(PSITables.parsePAT(pat) == [PSITables.PATEntry(programNumber: 7, pmtPID: 0x1000)])

        let pmt = PSITables.makePMT(for: program, version: 3)
        let parsed = try #require(PSITables.parsePMT(pmt, pmtPID: 0x1000))
        #expect(parsed.programNumber == 7)
        #expect(parsed.pcrPID == 0x100)
        #expect(parsed.programDescriptors == program.programDescriptors)
        // Teletext isn't carried; every other stream keeps its PID, type and descriptors.
        #expect(parsed.streams == program.carriedStreams)
        #expect(parsed.codecSummary == "H.264 · AAC · AC-3")

        var corrupted = pmt
        corrupted[14] ^= 0x01
        #expect(!PSITables.isValid(corrupted))
        #expect(PSITables.parsePMT(corrupted, pmtPID: 0x1000) == nil)
    }

    @Test("Stream types map onto the codecs the output carries")
    func streamTypes() {
        #expect(TSProgram.kind(streamType: 0x1B, descriptors: []) == .video(.h264))
        #expect(TSProgram.kind(streamType: 0x24, descriptors: []) == .video(.hevc))
        #expect(TSProgram.kind(streamType: 0x02, descriptors: []) == .video(.mpeg2))
        #expect(TSProgram.kind(streamType: 0x0F, descriptors: []) == .audio(.aac))
        #expect(TSProgram.kind(streamType: 0x03, descriptors: []) == .audio(.mpegAudio))
        #expect(TSProgram.kind(streamType: 0x81, descriptors: []) == .audio(.ac3))
        #expect(TSProgram.kind(streamType: 0x06, descriptors: [0x0A, 0x04, 0x65, 0x6E, 0x67, 0x00, 0x7A, 0x00]) == .audio(.eac3))
        #expect(TSProgram.kind(streamType: 0x06, descriptors: []) == .other)
        #expect(TSProgram.kind(streamType: 0x86, descriptors: []) == .other)
    }

    @Test("A PMT spanning two packets is reassembled; a continuation without its start is ignored")
    func sectionAssembly() throws {
        let streams = (0..<20).map { index in
            TSProgram.Stream(pid: UInt16(0x200 + index), streamType: 0x0F, kind: .audio(.aac),
                             descriptors: [0x0A, 0x04, 0x65, 0x6E, 0x67, UInt8(index)])
        }
        let program = TSProgram(programNumber: 1, pmtPID: 0x1000, pcrPID: 0x200, programDescriptors: [], streams: streams)
        let section = PSITables.makePMT(for: program, version: 0)
        var counter: UInt8 = 0x0F
        let packets = PSITables.packetize(section: section, pid: 0x1000, continuityCounter: &counter)
        #expect(packets.count == 2)
        #expect(packets.map(\.continuityCounter) == [0, 1])

        var assembler = PSISectionAssembler()
        #expect(assembler.push(packets[0]).isEmpty)
        #expect(assembler.push(packets[1]) == [section])
        let parsed = try #require(PSITables.parsePMT(section, pmtPID: 0x1000))
        #expect(parsed.streams == program.carriedStreams)

        var fresh = PSISectionAssembler()
        #expect(fresh.push(packets[1]).isEmpty)
    }

    // MARK: - PES

    @Test("Timestamps are rewritten even when the PES header straddles two packets", arguments: [6, 12, 16])
    func timestampRewriteAcrossPackets(firstPayload: Int) throws {
        let pes = SyntheticTransportStream.pesHeader(streamID: 0xE0, pts: 1_234_567, dts: 1_230_967)
            + [UInt8](repeating: 0x5A, count: 300)
        // The first packet's adaptation field leaves room for only `firstPayload` bytes of the PES.
        var first: [UInt8] = [0x47, 0x41, 0x00, 0x30, UInt8(183 - firstPayload), 0x00]
        first += [UInt8](repeating: 0xFF, count: 182 - firstPayload)
        first += pes.prefix(firstPayload)
        let second: [UInt8] = [0x47, 0x01, 0x00, 0x11] + pes.dropFirst(firstPayload).prefix(184)
        var unit = PESUnit(sourcePID: 0x100, packets: [TSPacket(bytes: first), TSPacket(bytes: second)])

        let header = try #require(unit.parseHeader())
        #expect(header.pts == 1_234_567)
        #expect(header.dts == 1_230_967)
        #expect(header.dataOffset == 19)

        unit.rewriteTimestamps(header, pts: MPEGTS.timestampModulo - 1, dts: 42)
        let rewritten = try #require(unit.parseHeader())
        #expect(rewritten.pts == MPEGTS.timestampModulo - 1)
        #expect(rewritten.dts == 42)
        // Prefix nibbles and marker bits stay exactly as a muxer writes them.
        let expected = SyntheticTransportStream.pesHeader(streamID: 0xE0, pts: MPEGTS.timestampModulo - 1, dts: 42)
        #expect(Array(unit.packets.flatMap { Array($0.payload) }.prefix(19)) == expected)
    }

    @Test("A PES carrying several AAC frames lasts as long as all of them")
    func adtsDuration() throws {
        let header = SyntheticTransportStream.pesHeader(streamID: 0xC0, pts: 0, dts: nil)
        let three = pesUnit(header + (0..<3).flatMap { _ in SyntheticTransportStream.adtsFrame() })
        #expect(three.adtsDuration(dataOffset: 14) == 5_760)
        let slower = pesUnit(header + SyntheticTransportStream.adtsFrame(rateIndex: 4))
        #expect(slower.adtsDuration(dataOffset: 14) == 2_089)
        let notADTS = pesUnit(header + [UInt8](repeating: 0x12, count: 64))
        #expect(notADTS.adtsDuration(dataOffset: 14) == nil)
    }

    @Test("A picture's fingerprint ignores transport framing but not content")
    func fingerprint() {
        let header = SyntheticTransportStream.pesHeader(streamID: 0xE0, pts: 900_000, dts: 896_400)
        let first = SyntheticTransportStream(content: 0)
        let other = SyntheticTransportStream(content: 1)
        let pes = header + first.elementaryStream(frame: 0, kind: .idr)
        let plain = pesUnit(pes)
        let framed = pesUnit(pes, pcr: 887_400, randomAccess: true)
        #expect(plain.packets != framed.packets)
        #expect(plain.fingerprint(dataOffset: 19) == framed.fingerprint(dataOffset: 19))
        #expect(plain.fingerprint(dataOffset: 19) != pesUnit(header + other.elementaryStream(frame: 0, kind: .idr)).fingerprint(dataOffset: 19))
    }

    // MARK: - Keyframes

    @Test("H.264 pictures are classified by their first slice")
    func h264Keyframes() throws {
        let stream = SyntheticTransportStream()
        let idr = try inspection(of: stream.elementaryStream(frame: 0, kind: .idr), codec: .h264)
        #expect(idr.isKeyframe && idr.isInstantRefresh)
        #expect(idr.sequenceParameterSet?.first == 0x67)
        let intra = try inspection(of: stream.elementaryStream(frame: 50, kind: .intra), codec: .h264)
        #expect(intra.isKeyframe && !intra.isInstantRefresh)
        let predicted = try inspection(of: stream.elementaryStream(frame: 1, kind: .predicted), codec: .h264)
        #expect(!predicted.isKeyframe)
    }

    @Test("HEVC IDR and CRA pictures are keyframes; only IDR resets the decoder")
    func hevcKeyframes() throws {
        var stream = SyntheticTransportStream()
        stream.videoStreamType = 0x24
        let idr = try inspection(of: stream.elementaryStream(frame: 0, kind: .idr), codec: .hevc)
        #expect(idr.isKeyframe && idr.isInstantRefresh)
        #expect(idr.sequenceParameterSet?.first == 0x42)
        let cra = try inspection(of: stream.elementaryStream(frame: 50, kind: .intra), codec: .hevc)
        #expect(cra.isKeyframe && !cra.isInstantRefresh)
        let trailing = try inspection(of: stream.elementaryStream(frame: 1, kind: .predicted), codec: .hevc)
        #expect(!trailing.isKeyframe)
    }

    @Test("MPEG-2 I pictures and sequence starts are keyframes")
    func mpeg2Keyframes() throws {
        let sequenceHeader: [UInt8] = [0, 0, 1, 0xB3, 0x2D, 0x02, 0x40, 0x33, 0xFF, 0xFF, 0xE0, 0x18]
        let iPicture: [UInt8] = [0, 0, 1, 0x00, 0x00, 0x08, 0xFF, 0xF8]
        let pPicture: [UInt8] = [0, 0, 1, 0x00, 0x00, 0x50, 0xFF, 0xF8]
        #expect(try inspection(of: iPicture, codec: .mpeg2).isKeyframe)
        #expect(try !inspection(of: pPicture, codec: .mpeg2).isKeyframe)
        #expect(try inspection(of: sequenceHeader + iPicture, codec: .mpeg2).isKeyframe)
    }

    @Test("Without readable NAL units the transport's random-access flag decides")
    func randomAccessFallback() throws {
        let unreadable = [UInt8](repeating: 0x11, count: 64)
        let flagged = try inspection(of: unreadable, codec: .h264, randomAccess: true)
        #expect(flagged.isKeyframe && !flagged.isInstantRefresh)
        #expect(try !inspection(of: unreadable, codec: .h264).isKeyframe)
    }
}
