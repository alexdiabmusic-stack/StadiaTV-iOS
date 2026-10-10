import Foundation

// MARK: - MPEG transport stream basics

/// Reading the parts of an MPEG transport stream that cutting it into HLS segments needs: packets, the program
/// tables, PES timestamps and where a keyframe starts. Nothing here decodes video or audio.
nonisolated enum TransportStream {
    static let packetSize = 188
    static let syncByte: UInt8 = 0x47
    static let patPID = 0
    static let nullPID = 0x1FFF
    /// 90 kHz ticks per second, the unit of PTS and DTS.
    static let ticksPerSecond = 90_000.0
    /// PTS and DTS are 33 bits and wrap after about 26 hours.
    static let timestampModulus: UInt64 = 1 << 33

    /// The packet header fields. `payload` is the range of the 188 bytes that carries data (empty when there is none).
    nonisolated struct Packet: Equatable {
        let pid: Int
        let payloadUnitStart: Bool
        let continuityCounter: Int
        let randomAccess: Bool
        let discontinuity: Bool
        let hasError: Bool
        let payload: Range<Int>

        /// Reads the packet at `offset` in `bytes`; nil when it doesn't start with the sync byte or is cut short.
        init?(_ bytes: [UInt8], at offset: Int) {
            guard offset >= 0, offset + TransportStream.packetSize <= bytes.count, bytes[offset] == TransportStream.syncByte else { return nil }
            let b1 = Int(bytes[offset + 1]), b2 = Int(bytes[offset + 2]), b3 = Int(bytes[offset + 3])
            hasError = b1 & 0x80 != 0
            payloadUnitStart = b1 & 0x40 != 0
            pid = ((b1 & 0x1F) << 8) | b2
            continuityCounter = b3 & 0x0F
            let control = (b3 >> 4) & 0x03
            var start = offset + 4
            var randomAccess = false
            var discontinuity = false
            if control & 0x02 != 0 {
                let length = Int(bytes[offset + 4])
                if length > 0 {
                    let flags = bytes[offset + 5]
                    discontinuity = flags & 0x80 != 0
                    randomAccess = flags & 0x40 != 0
                }
                start = offset + 5 + length
            }
            self.randomAccess = randomAccess
            self.discontinuity = discontinuity
            let end = offset + TransportStream.packetSize
            payload = control & 0x01 != 0 && start < end ? start..<end : end..<end
        }
    }

    /// The offset of the first packet that is followed by two more in step, or nil when `bytes` holds no run of three.
    static func firstSync(in bytes: [UInt8], from start: Int = 0) -> Int? {
        var i = start
        let limit = bytes.count - 2 * packetSize
        while i < limit {
            if bytes[i] == syncByte, bytes[i + packetSize] == syncByte, bytes[i + 2 * packetSize] == syncByte { return i }
            i += 1
        }
        return nil
    }

    // MARK: Program tables

    nonisolated struct ElementaryStream: Equatable {
        let pid: Int
        let type: UInt8
        let descriptors: [UInt8]

        nonisolated enum Kind: Equatable { case video, audio, other }

        var kind: Kind {
            switch type {
            case 0x01, 0x02, 0x10, 0x1B, 0x24, 0x42: return .video
            case 0x03, 0x04, 0x0F, 0x11, 0x81, 0x87, 0x82, 0x83, 0x84, 0x85, 0x86: return .audio
            case 0x06:
                // Private PES: AC-3, E-AC-3 and DTS audio are announced by a descriptor.
                return descriptorTags.contains { [0x6A, 0x7A, 0x7B].contains($0) } ? .audio : .other
            default: return .other
            }
        }

        private var descriptorTags: [UInt8] {
            var tags: [UInt8] = []
            var i = 0
            while i + 2 <= descriptors.count {
                tags.append(descriptors[i])
                i += 2 + Int(descriptors[i + 1])
            }
            return tags
        }

        /// What it is, for a person.
        var name: String {
            switch type {
            case 0x01: return "MPEG-1 video"
            case 0x02: return "MPEG-2 video"
            case 0x10: return "MPEG-4 video"
            case 0x1B: return "H.264 video"
            case 0x24: return "HEVC video"
            case 0x03, 0x04: return "MPEG audio"
            case 0x0F, 0x11: return "AAC audio"
            case 0x81: return "AC-3 audio"
            case 0x87: return "E-AC-3 audio"
            case 0x06 where descriptorTags.contains(0x6A): return "AC-3 audio"
            case 0x06 where descriptorTags.contains(0x7A): return "E-AC-3 audio"
            default: return "stream type 0x\(String(type, radix: 16))"
            }
        }

        /// Whether Apple's player can decode the video of this stream inside HLS. MPEG-2, MPEG-1 and MPEG-4 part 2
        /// video have no decoder on iOS or tvOS.
        var isPlayableVideo: Bool { type == 0x1B || type == 0x24 }
    }

    nonisolated struct Program: Equatable {
        var number: Int
        var pmtPID: Int
        var pcrPID: Int?
        var streams: [ElementaryStream]

        var video: ElementaryStream? { streams.first { $0.kind == .video } }

        /// Every PID whose packets belong in the output: the streams and the clock.
        var carriedPIDs: Set<Int> {
            var pids = Set(streams.map(\.pid))
            if let pcrPID { pids.insert(pcrPID) }
            return pids
        }

        /// A short description of what the program carries, e.g. "H.264 video, AAC audio".
        var summary: String {
            let names = streams.filter { $0.kind != .other }.map(\.name)
            return names.isEmpty ? "no audio or video" : names.joined(separator: ", ")
        }
    }

    /// Puts the sections of a PSI table back together: they start after a pointer byte in a packet that begins a unit
    /// and may continue over several packets.
    nonisolated struct SectionAssembler {
        private var buffer: [UInt8] = []

        /// Feeds one packet's payload; returns a section once all of it has arrived.
        mutating func feed(_ payload: ArraySlice<UInt8>, payloadUnitStart: Bool) -> [UInt8]? {
            if payloadUnitStart {
                guard let pointer = payload.first else { return nil }
                let start = payload.startIndex + 1 + Int(pointer)
                guard start <= payload.endIndex else { buffer.removeAll(); return nil }
                // Bytes before the pointer finish the previous section; a section that is still unfinished is dropped.
                buffer = Array(payload[start...])
            } else if !buffer.isEmpty {
                buffer.append(contentsOf: payload)
            } else {
                return nil
            }
            guard buffer.count >= 3 else { return nil }
            let length = (Int(buffer[1] & 0x0F) << 8) | Int(buffer[2])
            let total = length + 3
            guard buffer.count >= total else { return nil }
            let section = Array(buffer.prefix(total))
            buffer.removeAll()
            return section
        }
    }

    /// CRC-32/MPEG-2, as carried at the end of every PSI section.
    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return crc
    }

    /// A section is sound when the CRC over all of it, its own included, is zero.
    static func isIntact(_ section: [UInt8]) -> Bool {
        section.count >= 12 && crc32(section[...]) == 0
    }

    /// The programs of a PAT section as (program number, PMT PID); the network entry (program 0) is left out.
    static func parsePAT(_ section: [UInt8]) -> [(number: Int, pmtPID: Int)]? {
        guard section.count >= 12, section[0] == 0x00, isIntact(section) else { return nil }
        var programs: [(Int, Int)] = []
        var i = 8
        while i + 4 <= section.count - 4 {
            let number = (Int(section[i]) << 8) | Int(section[i + 1])
            let pid = (Int(section[i + 2] & 0x1F) << 8) | Int(section[i + 3])
            if number != 0 { programs.append((number, pid)) }
            i += 4
        }
        return programs.map { (number: $0.0, pmtPID: $0.1) }
    }

    /// A PMT section as a program.
    static func parsePMT(_ section: [UInt8], pmtPID: Int) -> Program? {
        guard section.count >= 16, section[0] == 0x02, isIntact(section) else { return nil }
        let number = (Int(section[3]) << 8) | Int(section[4])
        let pcr = (Int(section[8] & 0x1F) << 8) | Int(section[9])
        let programInfoLength = (Int(section[10] & 0x0F) << 8) | Int(section[11])
        var i = 12 + programInfoLength
        let end = section.count - 4
        var streams: [ElementaryStream] = []
        while i + 5 <= end {
            let type = section[i]
            let pid = (Int(section[i + 1] & 0x1F) << 8) | Int(section[i + 2])
            let infoLength = (Int(section[i + 3] & 0x0F) << 8) | Int(section[i + 4])
            let descriptorsEnd = min(i + 5 + infoLength, end)
            streams.append(ElementaryStream(pid: pid, type: type, descriptors: Array(section[(i + 5)..<descriptorsEnd])))
            i = descriptorsEnd
        }
        return Program(number: number, pmtPID: pmtPID, pcrPID: pcr == 0x1FFF ? nil : pcr, streams: streams)
    }

    /// A PAT section naming only `program`, for a stream that carries several.
    static func makePAT(program: Int, pmtPID: Int, transportStreamID: Int = 1) -> [UInt8] {
        var section: [UInt8] = [0x00, 0xB0, 0x0D,
                                UInt8(transportStreamID >> 8), UInt8(transportStreamID & 0xFF),
                                0xC1, 0x00, 0x00,
                                UInt8(program >> 8), UInt8(program & 0xFF),
                                0xE0 | UInt8((pmtPID >> 8) & 0x1F), UInt8(pmtPID & 0xFF)]
        let crc = crc32(section[...])
        section.append(contentsOf: [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)])
        return section
    }

    /// The packets that carry `section` on `pid`, numbered from `counter`. The counter after them is returned too.
    static func makePackets(section: [UInt8], pid: Int, counter: Int) -> (packets: [UInt8], nextCounter: Int) {
        var packets: [UInt8] = []
        var counter = counter & 0x0F
        var body: [UInt8] = [0x00] + section   // the pointer field, then the section
        var first = true
        while !body.isEmpty {
            let chunk = Array(body.prefix(184))
            body.removeFirst(chunk.count)
            packets.append(syncByte)
            packets.append((first ? 0x40 : 0x00) | UInt8((pid >> 8) & 0x1F))
            packets.append(UInt8(pid & 0xFF))
            packets.append(0x10 | UInt8(counter))
            packets.append(contentsOf: chunk)
            packets.append(contentsOf: [UInt8](repeating: 0xFF, count: 184 - chunk.count))
            counter = (counter + 1) & 0x0F
            first = false
        }
        return (packets, counter)
    }

    // MARK: PES

    nonisolated struct PESHeader: Equatable {
        let pts: UInt64?
        let dts: UInt64?
        /// Where the elementary stream data begins, counted from the start of the PES packet.
        let dataOffset: Int
    }

    /// The PES header at the start of a payload; nil when the payload doesn't begin with one.
    static func parsePESHeader(_ payload: ArraySlice<UInt8>) -> PESHeader? {
        let b = payload.startIndex
        guard payload.count >= 9, payload[b] == 0, payload[b + 1] == 0, payload[b + 2] == 1 else { return nil }
        let flags = payload[b + 7] >> 6
        let headerLength = Int(payload[b + 8])
        var pts: UInt64?
        var dts: UInt64?
        if flags & 0x02 != 0, payload.count >= 14 { pts = timestamp(payload[(b + 9)..<(b + 14)]) }
        if flags == 0x03, payload.count >= 19 { dts = timestamp(payload[(b + 14)..<(b + 19)]) }
        return PESHeader(pts: pts, dts: dts, dataOffset: 9 + headerLength)
    }

    private static func timestamp(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        let b = bytes.startIndex
        return (UInt64(bytes[b] & 0x0E) << 29) | (UInt64(bytes[b + 1]) << 22) | (UInt64(bytes[b + 2] & 0xFE) << 14)
            | (UInt64(bytes[b + 3]) << 7) | (UInt64(bytes[b + 4]) >> 1)
    }

    /// Seconds from `start` to `end`, across a wrap of the 33-bit clock.
    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        let ticks = (end &+ timestampModulus &- start) % timestampModulus
        // A difference over half the range is a step backwards, not a day-long forward jump.
        let signed = ticks > timestampModulus / 2 ? Double(ticks) - Double(timestampModulus) : Double(ticks)
        return signed / ticksPerSecond
    }

    // MARK: Keyframes

    nonisolated enum Keyframe: Equatable {
        case yes, no, undecided
    }

    /// Whether the access unit whose data begins `data` starts a keyframe. The first slice decides: an IDR slice is a
    /// keyframe and any other slice is not. When only parameter sets have been seen, so far, the answer waits for more
    /// bytes unless `final`, when parameter sets alone are taken as the sign of a keyframe (encoders repeat them
    /// only in front of one).
    static func classifyKeyframe(streamType: UInt8, data: [UInt8], final: Bool) -> Keyframe {
        var sawParameterSet = false
        var i = 0
        while i + 3 < data.count {
            guard data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 else { i += 1; continue }
            let header = data[i + 3]
            i += 4
            if streamType == 0x24 {
                switch Int((header >> 1) & 0x3F) {
                case 16...21: return .yes
                case 0...9: return .no
                case 32...34: sawParameterSet = true
                default: break
                }
            } else {
                switch header & 0x1F {
                case 5: return .yes
                case 1...4: return .no
                case 7, 8: sawParameterSet = true
                default: break
                }
            }
        }
        if sawParameterSet && final { return .yes }
        return final ? .no : .undecided
    }
}
