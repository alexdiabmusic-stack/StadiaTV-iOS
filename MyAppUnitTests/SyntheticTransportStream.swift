import Foundation
@testable import BannerTV

/// Builds MPEG transport streams that are right in structure (PAT, PMT, PES packets with timestamps, PCR, keyframe
/// markers, audio frames that straddle video frames) but carry no picture, so the segmenter can be exercised without
/// a media file.
struct SyntheticTransportStream {
    var videoType: UInt8? = 0x1B
    var audioType: UInt8? = 0x0F
    var framesPerSecond = 25
    /// A keyframe every this many video frames.
    var gopFrames = 50
    /// The first timestamp, in 90 kHz ticks.
    var startTimestamp: UInt64 = 90_000
    var programNumber = 1
    var pmtPID = 0x1000
    var videoPID = 0x100
    var audioPID = 0x101
    /// Adds a second program that the segmenter must leave out.
    var extraProgram = false

    private static let patPID = 0

    /// `seconds` of the stream, beginning with its tables.
    func data(seconds: Double) -> Data {
        var writer = Writer()
        writer.appendTables(pat: pat(), pmt: pmt(), pmtPID: pmtPID)

        let frames = Int(seconds * Double(framesPerSecond))
        let step = 90_000 / UInt64(framesPerSecond)
        var pendingAudioTail: [UInt8]?
        for frame in 0..<frames {
            let timestamp = (startTimestamp + UInt64(frame) * step) % TransportStream.timestampModulus
            let isKey = frame % gopFrames == 0
            if frame % 25 == 0, frame > 0 { writer.appendTables(pat: pat(), pmt: pmt(), pmtPID: pmtPID) }

            if let videoType {
                let packets = writer.pesPackets(pid: videoPID, streamID: 0xE0, timestamp: timestamp,
                                                payload: videoPayload(type: videoType, key: isKey, frame: frame),
                                                keyframe: isKey, pcr: timestamp)
                // The first video packet, then the tail of the previous audio frame (which therefore straddles
                // the keyframe), then the rest of the video frame.
                writer.append(packets[0])
                if let tail = pendingAudioTail { writer.append(tail); pendingAudioTail = nil }
                for packet in packets.dropFirst() { writer.append(packet) }
            }
            if let audioType {
                _ = audioType
                let packets = writer.pesPackets(pid: audioPID, streamID: 0xC0, timestamp: timestamp, payload: audioPayload(frame: frame),
                                                keyframe: false, pcr: nil)
                writer.append(packets[0])
                if packets.count > 1 {
                    if videoType != nil {
                        pendingAudioTail = Array(packets[1...].joined())
                    } else {
                        for packet in packets.dropFirst() { writer.append(packet) }
                    }
                }
            }
        }
        if let tail = pendingAudioTail { writer.append(tail) }
        return Data(writer.bytes)
    }

    // MARK: Tables

    private func pat() -> [UInt8] {
        var entries: [(Int, Int)] = [(programNumber, pmtPID)]
        if extraProgram { entries.append((programNumber + 1, pmtPID + 1)) }
        var section: [UInt8] = [0x00, 0xB0, UInt8(9 + entries.count * 4), 0x00, 0x01, 0xC1, 0x00, 0x00]
        for (number, pid) in entries {
            section += [UInt8(number >> 8), UInt8(number & 0xFF), 0xE0 | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF)]
        }
        return Self.sealed(section)
    }

    private func pmt() -> [UInt8] {
        var streams: [UInt8] = []
        if let videoType { streams += [videoType, 0xE0 | UInt8(videoPID >> 8), UInt8(videoPID & 0xFF), 0xF0, 0x00] }
        if let audioType { streams += [audioType, 0xE0 | UInt8(audioPID >> 8), UInt8(audioPID & 0xFF), 0xF0, 0x00] }
        let pcr = videoType != nil ? videoPID : audioPID
        var section: [UInt8] = [0x02, 0xB0, UInt8(13 + streams.count), UInt8(programNumber >> 8), UInt8(programNumber & 0xFF),
                                0xC1, 0x00, 0x00, 0xE0 | UInt8(pcr >> 8), UInt8(pcr & 0xFF), 0xF0, 0x00]
        section += streams
        return Self.sealed(section)
    }

    private static func sealed(_ section: [UInt8]) -> [UInt8] {
        let crc = TransportStream.crc32(section[...])
        return section + [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }

    // MARK: Payloads

    private func videoPayload(type: UInt8, key: Bool, frame: Int) -> [UInt8] {
        var data: [UInt8] = [0, 0, 0, 1]
        if type == 0x24 {
            // HEVC: AUD, then parameter sets and an IDR slice, or a trailing slice.
            data += [0x46, 0x01, 0x50]
            if key { data += [0, 0, 1, 0x40, 0x01, 0x0C, 0, 0, 1, 0x42, 0x01, 0x01, 0, 0, 1, 0x44, 0x01, 0xC0, 0, 0, 1, 0x26, 0x01] }
            else { data += [0, 0, 1, 0x02, 0x01] }
        } else {
            // H.264: AUD, then SPS, PPS and an IDR slice, or a non-IDR slice.
            data += [0x09, 0xF0]
            if key { data += [0, 0, 1, 0x67, 0x42, 0x00, 0x1E, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80, 0, 0, 1, 0x65, 0x88, 0x84] }
            else { data += [0, 0, 1, 0x41, 0x9A, 0x24] }
        }
        // A body that varies in size and has no start codes of its own.
        let size = key ? 700 : 150 + (frame % 5) * 90
        data += (0..<size).map { UInt8(truncatingIfNeeded: ($0 &* 31 &+ frame) | 0x04) & 0xFD | 0x04 }
        return data
    }

    private func audioPayload(frame: Int) -> [UInt8] {
        [0xFF, 0xF1, 0x50, 0x80] + (0..<230).map { UInt8(truncatingIfNeeded: $0 &+ frame) }
    }

    // MARK: Packetizing

    private struct Writer {
        var bytes: [UInt8] = []
        private var counters: [Int: Int] = [:]

        mutating func append(_ packet: [UInt8]) { bytes += packet }

        mutating func appendTables(pat: [UInt8], pmt: [UInt8], pmtPID: Int) {
            let a = TransportStream.makePackets(section: pat, pid: SyntheticTransportStream.patPID, counter: counters[0] ?? 0)
            counters[0] = a.nextCounter
            bytes += a.packets
            let b = TransportStream.makePackets(section: pmt, pid: pmtPID, counter: counters[pmtPID] ?? 0)
            counters[pmtPID] = b.nextCounter
            bytes += b.packets
        }

        /// One PES packet as TS packets: the first begins the unit, carries the clock if `pcr` and marks a keyframe.
        mutating func pesPackets(pid: Int, streamID: UInt8, timestamp: UInt64, payload: [UInt8], keyframe: Bool, pcr: UInt64?) -> [[UInt8]] {
            var pes: [UInt8] = [0, 0, 1, streamID, 0, 0, 0x80, 0x80, 0x05]
            pes += [0x21 | UInt8((timestamp >> 29) & 0x0E), UInt8((timestamp >> 22) & 0xFF), 0x01 | UInt8((timestamp >> 14) & 0xFE),
                    UInt8((timestamp >> 7) & 0xFF), 0x01 | UInt8((timestamp << 1) & 0xFE)]
            pes += payload

            var packets: [[UInt8]] = []
            var offset = 0
            var first = true
            while offset < pes.count {
                var packet: [UInt8] = [TransportStream.syncByte, (first ? 0x40 : 0) | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF), 0]
                var adaptation: [UInt8] = []
                if first, pcr != nil || keyframe {
                    var flags: UInt8 = keyframe ? 0x40 : 0
                    adaptation = [0]
                    if let pcr {
                        flags |= 0x10
                        adaptation += [flags, UInt8((pcr >> 25) & 0xFF), UInt8((pcr >> 17) & 0xFF), UInt8((pcr >> 9) & 0xFF),
                                       UInt8((pcr >> 1) & 0xFF), UInt8(((pcr & 1) << 7) | 0x7E), 0]
                    } else {
                        adaptation += [flags]
                    }
                    adaptation[0] = UInt8(adaptation.count - 1)
                }
                let room = 184 - adaptation.count
                let remaining = pes.count - offset
                if remaining < room {
                    // Pad the last packet with stuffing in the adaptation field.
                    let stuffing = room - remaining
                    if adaptation.isEmpty {
                        adaptation = stuffing == 1 ? [0] : [UInt8(stuffing - 1), 0] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                    } else {
                        adaptation += [UInt8](repeating: 0xFF, count: stuffing)
                        adaptation[0] = UInt8(adaptation.count - 1)
                    }
                }
                let take = min(184 - adaptation.count, remaining)
                packet[3] = (adaptation.isEmpty ? 0x10 : 0x30) | UInt8(counters[pid, default: 0])
                counters[pid, default: 0] = (counters[pid, default: 0] + 1) & 0x0F
                packet += adaptation
                packet += pes[offset..<(offset + take)]
                offset += take
                first = false
                packets.append(packet)
            }
            return packets
        }
    }
}

// MARK: - Reading segments back

/// What a test needs to know about the packets of a segment.
struct SegmentContents {
    struct Entry { let pid: Int; let payloadUnitStart: Bool; let counter: Int; let randomAccess: Bool; let payload: [UInt8] }
    let entries: [Entry]
    let bytes: [UInt8]

    init(_ data: Data) {
        bytes = [UInt8](data)
        var entries: [Entry] = []
        var offset = 0
        while let packet = TransportStream.Packet(bytes, at: offset) {
            entries.append(Entry(pid: packet.pid, payloadUnitStart: packet.payloadUnitStart, counter: packet.continuityCounter,
                                 randomAccess: packet.randomAccess, payload: Array(bytes[packet.payload])))
            offset += TransportStream.packetSize
        }
        self.entries = entries
        remainder = bytes.count - offset
    }

    let remainder: Int

    func entries(for pid: Int) -> [Entry] { entries.filter { $0.pid == pid } }

    /// How many video access units (frames) the segment holds.
    func videoFrames(pid: Int) -> Int { entries(for: pid).filter(\.payloadUnitStart).count }

    /// Audio frames are two packets each in the synthetic stream: a start and a continuation. A segment cut cleanly
    /// has them all paired up.
    func audioFramesAreWhole(pid: Int) -> Bool {
        let audio = entries(for: pid)
        guard audio.count % 2 == 0 else { return false }
        return stride(from: 0, to: audio.count, by: 2).allSatisfy { audio[$0].payloadUnitStart && !audio[$0 + 1].payloadUnitStart }
    }

    /// The first packet after the PAT and PMT.
    var firstMediaEntry: Entry? { entries.first { $0.pid != 0 && $0.pid != 0x1000 } }

    var startsWithTables: Bool {
        entries.count >= 2 && entries[0].pid == 0 && entries[0].payloadUnitStart && entries[1].pid == 0x1000 && entries[1].payloadUnitStart
    }

    /// Whether the first video frame holds an IDR slice (H.264) or IRAP slice (HEVC).
    func startsWithKeyframe(pid: Int, streamType: UInt8) -> Bool {
        guard let first = entries(for: pid).first, first.payloadUnitStart,
              let header = TransportStream.parsePESHeader(first.payload[...]) else { return false }
        let es = Array(first.payload.dropFirst(header.dataOffset))
        return TransportStream.classifyKeyframe(streamType: streamType, data: es, final: true) == .yes
    }

    /// Whether the continuity counter of every PID counts on by one from packet to packet.
    func countersAreContinuous() -> Bool {
        var last: [Int: Int] = [:]
        for entry in entries {
            if let previous = last[entry.pid], entry.counter != (previous + 1) & 0x0F { return false }
            last[entry.pid] = entry.counter
        }
        return true
    }
}
