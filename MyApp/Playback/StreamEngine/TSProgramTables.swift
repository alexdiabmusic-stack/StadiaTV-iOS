import Foundation

/// The elementary streams of one MPEG-TS program, as described by its PMT.
nonisolated struct TSProgram: Equatable, Sendable {
    nonisolated enum VideoCodec: String, Sendable { case h264 = "H.264", hevc = "HEVC", mpeg2 = "MPEG-2", mpeg1 = "MPEG-1" }
    nonisolated enum AudioCodec: String, Sendable { case aac = "AAC", aacLATM = "AAC-LATM", mpegAudio = "MPEG audio", ac3 = "AC-3", eac3 = "E-AC-3" }

    nonisolated enum Kind: Equatable, Sendable {
        case video(VideoCodec)
        case audio(AudioCodec)
        /// ID3 timed metadata, which AVPlayer surfaces as timed metadata.
        case metadata
        /// Subtitles, teletext, SCTE-35 and anything else the output doesn't carry.
        case other
    }

    struct Stream: Equatable, Sendable {
        var pid: UInt16
        var streamType: UInt8
        var kind: Kind
        /// Raw ES_info descriptors, re-emitted unchanged in the output PMT.
        var descriptors: [UInt8]
    }

    var programNumber: UInt16
    var pmtPID: UInt16
    var pcrPID: UInt16
    var programDescriptors: [UInt8]
    var streams: [Stream]

    var video: Stream? { streams.first { if case .video = $0.kind { return true } else { return false } } }
    var audio: [Stream] { streams.filter { if case .audio = $0.kind { return true } else { return false } } }
    /// Streams the output carries: video, audio and ID3 metadata.
    var carriedStreams: [Stream] { streams.filter { $0.kind != .other } }

    func stream(pid: UInt16) -> Stream? { streams.first { $0.pid == pid } }

    /// Same codecs in the same order: the decoder can continue across a splice between the two.
    func isSpliceCompatible(with other: TSProgram) -> Bool {
        carriedStreams.map(\.kind) == other.carriedStreams.map(\.kind)
    }

    /// The codec summary shown in diagnostics, e.g. "H.264 · AAC".
    var codecSummary: String {
        let names = carriedStreams.compactMap { stream -> String? in
            switch stream.kind {
            case .video(let codec): return codec.rawValue
            case .audio(let codec): return codec.rawValue
            case .metadata, .other: return nil
            }
        }
        return names.joined(separator: " · ")
    }

    static func kind(streamType: UInt8, descriptors: [UInt8]) -> Kind {
        switch streamType {
        case 0x1B: return .video(.h264)
        case 0x24: return .video(.hevc)
        case 0x02: return .video(.mpeg2)
        case 0x01: return .video(.mpeg1)
        case 0x0F: return .audio(.aac)
        case 0x11: return .audio(.aacLATM)
        case 0x03, 0x04: return .audio(.mpegAudio)
        case 0x81: return .audio(.ac3)
        case 0x87: return .audio(.eac3)
        case 0x15: return .metadata
        case 0x06:
            // DVB carries AC-3/E-AC-3 as private PES, identified by descriptor tag.
            var index = 0
            while index + 2 <= descriptors.count {
                let tag = descriptors[index]
                let length = Int(descriptors[index + 1])
                if tag == 0x6A { return .audio(.ac3) }
                if tag == 0x7A { return .audio(.eac3) }
                index += 2 + length
            }
            return .other
        default:
            return .other
        }
    }
}

/// Reassembles PSI sections that span transport packets.
nonisolated struct PSISectionAssembler {
    private var buffer: [UInt8] = []
    private var expectedLength: Int?

    /// Feeds one packet; returns any sections it completes.
    mutating func push(_ packet: TSPacket) -> [[UInt8]] {
        var payload = Array(packet.payload)
        guard !payload.isEmpty else { return [] }
        var sections: [[UInt8]] = []
        if packet.payloadUnitStart {
            let pointer = Int(payload[0])
            guard 1 + pointer <= payload.count else { reset(); return [] }
            // Bytes before the pointer finish the section already in progress.
            if !buffer.isEmpty {
                buffer.append(contentsOf: payload[1..<(1 + pointer)])
                if let section = takeSection() { sections.append(section) }
            }
            reset()
            payload = Array(payload[(1 + pointer)...])
        } else if buffer.isEmpty {
            // The continuation of a section whose start we never saw.
            return []
        }
        buffer.append(contentsOf: payload)
        // Further sections may follow in the same packet; a 0xFF table ID marks stuffing.
        while buffer.first != 0xFF, let section = takeSection() {
            sections.append(section)
        }
        if buffer.first == 0xFF { reset() }
        return sections
    }

    private mutating func reset() {
        buffer = []
        expectedLength = nil
    }

    private mutating func takeSection() -> [UInt8]? {
        if expectedLength == nil {
            guard buffer.count >= 3 else { return nil }
            let length = 3 + (Int(buffer[1] & 0x0F) << 8 | Int(buffer[2]))
            // PSI sections are at most 1024 bytes; anything larger is garbage.
            guard length <= 4096 else { reset(); return nil }
            expectedLength = length
        }
        guard let length = expectedLength, buffer.count >= length else { return nil }
        let section = Array(buffer[0..<length])
        buffer.removeFirst(length)
        expectedLength = nil
        return section
    }
}

/// Parses and builds PAT/PMT sections.
nonisolated enum PSITables {
    struct PATEntry: Equatable { let programNumber: UInt16; let pmtPID: UInt16 }

    static func isValid(_ section: [UInt8]) -> Bool {
        guard section.count >= 12 else { return false }
        return MPEGCRC32.checksum(section) == 0
    }

    static func parsePAT(_ section: [UInt8]) -> [PATEntry]? {
        guard section.first == 0x00, isValid(section) else { return nil }
        var entries: [PATEntry] = []
        var index = 8
        while index + 4 <= section.count - 4 {
            let number = UInt16(section[index]) << 8 | UInt16(section[index + 1])
            let pid = UInt16(section[index + 2] & 0x1F) << 8 | UInt16(section[index + 3])
            if number != 0 { entries.append(PATEntry(programNumber: number, pmtPID: pid)) }
            index += 4
        }
        return entries
    }

    static func parsePMT(_ section: [UInt8], pmtPID: UInt16) -> TSProgram? {
        guard section.first == 0x02, isValid(section), section.count >= 16 else { return nil }
        let programNumber = UInt16(section[3]) << 8 | UInt16(section[4])
        let pcrPID = UInt16(section[8] & 0x1F) << 8 | UInt16(section[9])
        let programInfoLength = Int(section[10] & 0x0F) << 8 | Int(section[11])
        let end = section.count - 4
        guard 12 + programInfoLength <= end else { return nil }
        let programDescriptors = Array(section[12..<(12 + programInfoLength)])
        var streams: [TSProgram.Stream] = []
        var index = 12 + programInfoLength
        while index + 5 <= end {
            let streamType = section[index]
            let pid = UInt16(section[index + 1] & 0x1F) << 8 | UInt16(section[index + 2])
            let infoLength = Int(section[index + 3] & 0x0F) << 8 | Int(section[index + 4])
            guard index + 5 + infoLength <= end else { return nil }
            let descriptors = Array(section[(index + 5)..<(index + 5 + infoLength)])
            streams.append(TSProgram.Stream(pid: pid, streamType: streamType,
                                            kind: TSProgram.kind(streamType: streamType, descriptors: descriptors),
                                            descriptors: descriptors))
            index += 5 + infoLength
        }
        return TSProgram(programNumber: programNumber, pmtPID: pmtPID, pcrPID: pcrPID,
                         programDescriptors: programDescriptors, streams: streams)
    }

    /// A single-program PAT pointing at `program`'s PMT.
    static func makePAT(for program: TSProgram, version: UInt8) -> [UInt8] {
        var body: [UInt8] = [
            0x00, 0x01,                                  // transport_stream_id
            0xC1 | ((version & 0x1F) << 1),              // version, current_next
            0x00, 0x00,                                  // section_number, last_section_number
            UInt8(program.programNumber >> 8), UInt8(program.programNumber & 0xFF),
            0xE0 | UInt8((program.pmtPID >> 8) & 0x1F), UInt8(program.pmtPID & 0xFF)
        ]
        return finishSection(tableID: 0x00, body: &body)
    }

    /// The PMT for the streams the output carries.
    static func makePMT(for program: TSProgram, version: UInt8) -> [UInt8] {
        var body: [UInt8] = [
            UInt8(program.programNumber >> 8), UInt8(program.programNumber & 0xFF),
            0xC1 | ((version & 0x1F) << 1),
            0x00, 0x00,
            0xE0 | UInt8((program.pcrPID >> 8) & 0x1F), UInt8(program.pcrPID & 0xFF),
            0xF0 | UInt8((program.programDescriptors.count >> 8) & 0x0F), UInt8(program.programDescriptors.count & 0xFF)
        ]
        body.append(contentsOf: program.programDescriptors)
        for stream in program.carriedStreams {
            body.append(stream.streamType)
            body.append(0xE0 | UInt8((stream.pid >> 8) & 0x1F))
            body.append(UInt8(stream.pid & 0xFF))
            body.append(0xF0 | UInt8((stream.descriptors.count >> 8) & 0x0F))
            body.append(UInt8(stream.descriptors.count & 0xFF))
            body.append(contentsOf: stream.descriptors)
        }
        return finishSection(tableID: 0x02, body: &body)
    }

    private static func finishSection(tableID: UInt8, body: inout [UInt8]) -> [UInt8] {
        let sectionLength = body.count + 4
        var section: [UInt8] = [tableID, 0xB0 | UInt8((sectionLength >> 8) & 0x0F), UInt8(sectionLength & 0xFF)]
        section.append(contentsOf: body)
        let crc = MPEGCRC32.checksum(section)
        section.append(contentsOf: [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
        return section
    }

    /// Splits a section into transport packets on `pid`, advancing `continuityCounter`.
    static func packetize(section: [UInt8], pid: UInt16, continuityCounter: inout UInt8) -> [TSPacket] {
        var packets: [TSPacket] = []
        var remaining = ArraySlice([0x00] + section) // pointer_field = 0
        var first = true
        while !remaining.isEmpty {
            var bytes = [UInt8](repeating: 0xFF, count: MPEGTS.packetSize)
            bytes[0] = MPEGTS.syncByte
            bytes[1] = (first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F)
            bytes[2] = UInt8(pid & 0xFF)
            continuityCounter = (continuityCounter + 1) & 0x0F
            bytes[3] = 0x10 | continuityCounter
            let chunk = remaining.prefix(MPEGTS.packetSize - 4)
            bytes.replaceSubrange(4..<(4 + chunk.count), with: chunk)
            remaining = remaining.dropFirst(chunk.count)
            packets.append(TSPacket(bytes: bytes))
            first = false
        }
        return packets
    }
}
