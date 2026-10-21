import Foundation

/// MPEG-2 transport stream constants and timestamp arithmetic (ISO/IEC 13818-1).
///
/// PTS, DTS and the PCR base all tick at 90 kHz in a 33-bit field, so every comparison
/// goes through `signedDelta` to survive the wrap that happens every ~26.5 hours.
nonisolated enum MPEGTS {
    static let packetSize = 188
    static let syncByte: UInt8 = 0x47
    static let patPID: UInt16 = 0x0000
    static let nullPID: UInt16 = 0x1FFF
    static let clockRate: Int64 = 90_000
    static let timestampModulo: Int64 = 1 << 33
    static let timestampMask: Int64 = timestampModulo - 1

    static func wrap(_ ticks: Int64) -> Int64 { ticks & timestampMask }

    /// `a - b` on the 33-bit circle, in -2³²..<2³².
    static func signedDelta(_ a: Int64, _ b: Int64) -> Int64 {
        var delta = (a - b) & timestampMask
        if delta >= timestampModulo / 2 { delta -= timestampModulo }
        return delta
    }

    static func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(clockRate) }
    static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * Double(clockRate)).rounded()) }
}

/// One 188-byte transport packet. Field setters rewrite the bytes in place.
nonisolated struct TSPacket: Equatable {
    var bytes: [UInt8]

    init(bytes: [UInt8]) {
        precondition(bytes.count == MPEGTS.packetSize, "transport packets are 188 bytes")
        self.bytes = bytes
    }

    var pid: UInt16 {
        get { (UInt16(bytes[1] & 0x1F) << 8) | UInt16(bytes[2]) }
        set {
            bytes[1] = (bytes[1] & 0xE0) | UInt8((newValue >> 8) & 0x1F)
            bytes[2] = UInt8(newValue & 0xFF)
        }
    }

    var transportError: Bool { bytes[1] & 0x80 != 0 }
    var payloadUnitStart: Bool { bytes[1] & 0x40 != 0 }
    var isScrambled: Bool { bytes[3] & 0xC0 != 0 }
    var hasAdaptationField: Bool { bytes[3] & 0x20 != 0 }
    var hasPayload: Bool { bytes[3] & 0x10 != 0 }

    var continuityCounter: UInt8 {
        get { bytes[3] & 0x0F }
        set { bytes[3] = (bytes[3] & 0xF0) | (newValue & 0x0F) }
    }

    private var adaptationFieldLength: Int { hasAdaptationField ? Int(bytes[4]) : 0 }

    /// Where the payload starts, or nil when the adaptation field claims more than the packet holds.
    var payloadOffset: Int? {
        guard hasPayload else { return nil }
        let offset = hasAdaptationField ? 5 + adaptationFieldLength : 4
        return offset < MPEGTS.packetSize ? offset : nil
    }

    private var adaptationFlags: UInt8? {
        guard hasAdaptationField, adaptationFieldLength > 0, adaptationFieldLength <= 183 else { return nil }
        return bytes[5]
    }

    var randomAccessIndicator: Bool { (adaptationFlags ?? 0) & 0x40 != 0 }
    var discontinuityIndicator: Bool { (adaptationFlags ?? 0) & 0x80 != 0 }

    /// The 33-bit, 90 kHz half of the PCR (the 27 MHz extension is left untouched).
    var pcrBase: Int64? {
        guard let flags = adaptationFlags, flags & 0x10 != 0, adaptationFieldLength >= 7 else { return nil }
        return (Int64(bytes[6]) << 25) | (Int64(bytes[7]) << 17) | (Int64(bytes[8]) << 9)
            | (Int64(bytes[9]) << 1) | Int64(bytes[10] >> 7)
    }

    mutating func setPCRBase(_ value: Int64) {
        guard pcrBase != nil else { return }
        let base = MPEGTS.wrap(value)
        bytes[6] = UInt8((base >> 25) & 0xFF)
        bytes[7] = UInt8((base >> 17) & 0xFF)
        bytes[8] = UInt8((base >> 9) & 0xFF)
        bytes[9] = UInt8((base >> 1) & 0xFF)
        bytes[10] = (bytes[10] & 0x7F) | UInt8((base & 0x01) << 7)
    }

    /// Payload bytes, or an empty slice for adaptation-only or malformed packets.
    var payload: ArraySlice<UInt8> {
        guard let offset = payloadOffset else { return [] }
        return bytes[offset...]
    }
}

/// A PES packet reassembled from its transport packets, with timestamps that can be rewritten
/// in place even when the PES header straddles two transport packets.
nonisolated struct PESUnit {
    let sourcePID: UInt16
    var packets: [TSPacket]

    /// Payload byte positions as (packet index, byte offset), in PES order.
    private func payloadPositions(limit: Int) -> [(packet: Int, offset: Int)] {
        var positions: [(packet: Int, offset: Int)] = []
        positions.reserveCapacity(limit)
        for (index, packet) in packets.enumerated() {
            guard let start = packet.payloadOffset else { continue }
            for offset in start..<MPEGTS.packetSize {
                positions.append((index, offset))
                if positions.count == limit { return positions }
            }
        }
        return positions
    }

    struct Header {
        let streamID: UInt8
        let pts: Int64?
        let dts: Int64?
        /// Offset of the elementary-stream data within the PES.
        let dataOffset: Int
        fileprivate let ptsPositions: [(packet: Int, offset: Int)]?
        fileprivate let dtsPositions: [(packet: Int, offset: Int)]?
    }

    /// Parses the PES header; nil when the unit doesn't start with a PES start code.
    func parseHeader() -> Header? {
        let positions = payloadPositions(limit: 19)
        guard positions.count >= 6 else { return nil }
        func byte(_ index: Int) -> UInt8 {
            let position = positions[index]
            return packets[position.packet].bytes[position.offset]
        }
        guard byte(0) == 0x00, byte(1) == 0x00, byte(2) == 0x01 else { return nil }
        let streamID = byte(3)
        // Stream IDs without the optional header: map, padding, private 2, ECM, EMM, DSM-CC, type E, directory.
        let headerless: Set<UInt8> = [0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF]
        guard !headerless.contains(streamID), positions.count >= 9 else {
            return Header(streamID: streamID, pts: nil, dts: nil, dataOffset: 6, ptsPositions: nil, dtsPositions: nil)
        }
        let flags = (byte(7) >> 6) & 0x03
        let dataOffset = 9 + Int(byte(8))
        var ptsPositions: [(packet: Int, offset: Int)]?
        var dtsPositions: [(packet: Int, offset: Int)]?
        if flags & 0x02 != 0, positions.count >= 14 {
            ptsPositions = Array(positions[9..<14])
        }
        if flags == 0x03, positions.count >= 19 {
            dtsPositions = Array(positions[14..<19])
        }
        let pts = ptsPositions.map { Self.decodeTimestamp(packets, $0) }
        let dts = dtsPositions.map { Self.decodeTimestamp(packets, $0) }
        return Header(streamID: streamID, pts: pts, dts: dts, dataOffset: dataOffset,
                      ptsPositions: ptsPositions, dtsPositions: dtsPositions)
    }

    /// Rewrites PTS/DTS using the positions found by `parseHeader`. The marker bits and the
    /// 4-bit prefix are preserved exactly as the muxer wrote them.
    mutating func rewriteTimestamps(_ header: Header, pts: Int64?, dts: Int64?) {
        if let pts, let positions = header.ptsPositions { Self.encodeTimestamp(&packets, positions, pts) }
        if let dts, let positions = header.dtsPositions { Self.encodeTimestamp(&packets, positions, dts) }
    }

    private static func decodeTimestamp(_ packets: [TSPacket], _ positions: [(packet: Int, offset: Int)]) -> Int64 {
        let b = positions.map { packets[$0.packet].bytes[$0.offset] }
        return (Int64((b[0] >> 1) & 0x07) << 30) | (Int64(b[1]) << 22) | (Int64((b[2] >> 1) & 0x7F) << 15)
            | (Int64(b[3]) << 7) | Int64((b[4] >> 1) & 0x7F)
    }

    private static func encodeTimestamp(_ packets: inout [TSPacket], _ positions: [(packet: Int, offset: Int)], _ value: Int64) {
        let v = MPEGTS.wrap(value)
        let prefix = packets[positions[0].packet].bytes[positions[0].offset] & 0xF0
        let encoded: [UInt8] = [
            prefix | UInt8(((v >> 30) & 0x07) << 1) | 0x01,
            UInt8((v >> 22) & 0xFF),
            UInt8(((v >> 15) & 0x7F) << 1) | 0x01,
            UInt8((v >> 7) & 0xFF),
            UInt8((v & 0x7F) << 1) | 0x01
        ]
        for (index, position) in positions.enumerated() {
            packets[position.packet].bytes[position.offset] = encoded[index]
        }
    }

    /// Calls `body` with successive elementary-stream byte runs (after the PES header) until it returns false.
    func forEachDataChunk(from dataOffset: Int, _ body: (ArraySlice<UInt8>) -> Bool) {
        var skipped = 0
        for packet in packets {
            var payload = packet.payload
            guard !payload.isEmpty else { continue }
            if skipped < dataOffset {
                let skip = min(dataOffset - skipped, payload.count)
                skipped += skip
                payload = payload.dropFirst(skip)
                if payload.isEmpty { continue }
            }
            if !body(payload) { return }
        }
    }

    var byteCount: Int { packets.count * MPEGTS.packetSize }

    /// Whether every byte the PES header announces has arrived; nil when the header leaves the
    /// length open, as video PES usually do, so only the next unit's start shows where it ends.
    var isCompleteByLength: Bool? {
        let positions = payloadPositions(limit: 6)
        guard positions.count == 6 else { return false }
        func byte(_ index: Int) -> UInt8 { packets[positions[index].packet].bytes[positions[index].offset] }
        guard byte(0) == 0x00, byte(1) == 0x00, byte(2) == 0x01 else { return false }
        let declared = Int(byte(4)) << 8 | Int(byte(5))
        guard declared > 0 else { return nil }
        return packets.reduce(0) { $0 + $1.payload.count } >= 6 + declared
    }

    /// Playing time of an ADTS AAC PES, in 90 kHz ticks, counted from its frame headers.
    /// A PES often carries several AAC frames, so its start time alone doesn't say where it ends.
    func adtsDuration(dataOffset: Int) -> Int64? {
        var bytes: [UInt8] = []
        forEachDataChunk(from: dataOffset) { chunk in
            bytes.append(contentsOf: chunk)
            return true
        }
        let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        var index = 0
        var samples = 0
        var sampleRate: Int?
        while index + 7 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] & 0xF0 == 0xF0 {
            let rateIndex = Int((bytes[index + 2] >> 2) & 0x0F)
            guard rateIndex < rates.count else { return nil }
            sampleRate = rates[rateIndex]
            let length = (Int(bytes[index + 3] & 0x03) << 11) | (Int(bytes[index + 4]) << 3) | Int(bytes[index + 5] >> 5)
            guard length >= 7 else { return nil }
            samples += (Int(bytes[index + 6] & 0x03) + 1) * 1024
            index += length
        }
        guard let sampleRate, samples > 0 else { return nil }
        return Int64(samples) * MPEGTS.clockRate / Int64(sampleRate)
    }

    /// This ADTS AAC PES without the frames that begin in its first `ticks`, its timestamps moved
    /// past them. A PES often holds a fifth of a second of audio or more: when a splice has already
    /// played the start of one, cutting at a frame keeps the rest instead of leaving a hole. Nil when
    /// the payload isn't ADTS, a packet carries a PCR, or no frame would be left.
    func droppingADTSFrames(startingWithin ticks: Int64, header: Header) -> (unit: PESUnit, header: Header, droppedTicks: Int64)? {
        guard ticks > 0, let pts = header.pts, let last = packets.last, !packets.contains(where: { $0.pcrBase != nil }) else {
            return nil
        }
        var pes: [UInt8] = []
        for packet in packets { pes += packet.payload }
        let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        func frame(at index: Int) -> (length: Int, samples: Int, rate: Int)? {
            guard index + 7 <= pes.count, pes[index] == 0xFF, pes[index + 1] & 0xF0 == 0xF0 else { return nil }
            let rateIndex = Int((pes[index + 2] >> 2) & 0x0F)
            let length = (Int(pes[index + 3] & 0x03) << 11) | (Int(pes[index + 4]) << 3) | Int(pes[index + 5] >> 5)
            guard rateIndex < rates.count, length >= 7, index + length <= pes.count else { return nil }
            return (length, (Int(pes[index + 6] & 0x03) + 1) * 1024, rates[rateIndex])
        }
        var index = header.dataOffset
        var samples = 0
        var dropped: Int64 = 0
        while dropped < ticks, let next = frame(at: index) {
            index += next.length
            samples += next.samples
            dropped = Int64(samples) * MPEGTS.clockRate / Int64(next.rate)
        }
        guard dropped > 0, frame(at: index) != nil else { return nil }

        var trimmed = Array(pes[..<header.dataOffset]) + pes[index...]
        let declared = Int(trimmed[4]) << 8 | Int(trimmed[5])
        if declared > 0 {
            let length = declared - (index - header.dataOffset)
            guard length > 0 else { return nil }
            trimmed[4] = UInt8(length >> 8)
            trimmed[5] = UInt8(length & 0xFF)
        }
        // Repacketized on the same PID; the counters count back from the original last packet, so
        // the next PES still follows on.
        let count = (trimmed.count + 183) / 184
        var rebuilt: [TSPacket] = []
        rebuilt.reserveCapacity(count)
        for number in 0..<count {
            let chunk = trimmed[(number * 184)..<min((number + 1) * 184, trimmed.count)]
            let counter = (last.continuityCounter &- UInt8((count - 1 - number) & 0x0F)) & 0x0F
            var bytes: [UInt8] = [0x47, (last.bytes[1] & 0x1F) | (number == 0 ? 0x40 : 0), last.bytes[2], 0x10 | counter]
            if chunk.count < 184 {
                // Adaptation-field stuffing fills the last packet.
                let stuffing = 183 - chunk.count
                bytes[3] |= 0x20
                bytes.append(UInt8(stuffing))
                if stuffing > 0 { bytes += [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 1) }
            }
            bytes += chunk
            rebuilt.append(TSPacket(bytes: bytes))
        }
        var unit = PESUnit(sourcePID: sourcePID, packets: rebuilt)
        guard let parsed = unit.parseHeader() else { return nil }
        unit.rewriteTimestamps(parsed, pts: MPEGTS.wrap(pts + dropped), dts: header.dts.map { MPEGTS.wrap($0 + dropped) })
        guard let shifted = unit.parseHeader() else { return nil }
        return (unit, shifted, dropped)
    }

    /// FNV-1a over the first elementary-stream bytes: identifies the same coded picture when a
    /// reconnect re-sends it, regardless of the transport framing around it.
    func fingerprint(dataOffset: Int, length: Int = 256) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        var remaining = length
        forEachDataChunk(from: dataOffset) { chunk in
            for byte in chunk.prefix(remaining) {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
            remaining -= min(remaining, chunk.count)
            return remaining > 0
        }
        return hash
    }
}

/// CRC-32/MPEG-2, the checksum on every PSI section.
nonisolated enum MPEGCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index) << 24
        for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        return crc
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc << 8) ^ table[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)]
        }
        return crc
    }
}
