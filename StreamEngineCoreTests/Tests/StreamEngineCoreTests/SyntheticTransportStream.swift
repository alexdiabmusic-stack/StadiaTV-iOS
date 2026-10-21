import Foundation
@testable import StreamEngineCore

/// Builds small, deterministic MPEG transport streams for the engine's tests: H.264 or HEVC video
/// (parameter sets and IDR, open-GOP intra or predicted pictures) at 25 fps and ADTS AAC audio,
/// with PAT/PMT, PCR and per-PID continuity counters, the way an IPTV encoder emits them.
///
/// Every picture carries its frame number and its encoder's identity in its payload, so a test
/// can tell exactly which pictures reached the output, and in what order.
struct SyntheticTransportStream {
    enum PictureKind { case idr, intra, predicted }

    var videoPID: UInt16 = 0x100
    var audioPID: UInt16 = 0x101
    var pmtPID: UInt16 = 0x1000
    /// 0x1B H.264, 0x24 HEVC.
    var videoStreamType: UInt8 = 0x1B
    /// False for a radio channel: audio only, with the PCR on the audio PID.
    var includeVideo = true
    var includeAudio = true
    var gop = 50
    var frameTicks: Int64 = 3_600
    var audioTicks: Int64 = 1_920
    /// PTS of frame 0 (the encoder's clock, not the engine's).
    var startPTS: Int64 = 900_000
    /// The encoder's identity. It changes every picture's payload, so fingerprints differ between encoders.
    var content: UInt8 = 0
    /// Keyframes after the first are non-IDR intra pictures (H.264 I slices, HEVC CRA).
    var openGOP = false

    private var continuity: [UInt16: UInt8] = [:]
    /// Where the previous call stopped, so a call that carries on from it continues the audio
    /// without repeating any (relative to the frame clock, so a clock jump moves audio too).
    private var resumeFrame: Int?
    private var resumeAudioOffset: Int64 = 0

    init(startPTS: Int64 = 900_000, content: UInt8 = 0) {
        self.startPTS = startPTS
        self.content = content
    }

    /// `seconds` of programme starting at frame `firstFrame`, as one byte stream. A call that
    /// starts where the previous one ended continues it; any other start is a fresh join.
    mutating func bytes(seconds: Double, firstFrame: Int = 0) -> [UInt8] {
        let frames = Int((seconds * 90_000 / Double(frameTicks)).rounded())
        var output: [UInt8] = []
        let audioOffset = resumeFrame == firstFrame ? resumeAudioOffset : -frameTicks
        var nextAudioPTS = MPEGTS.wrap(pts(frame: firstFrame) + audioOffset)
        for index in firstFrame..<(firstFrame + frames) {
            if (index - firstFrame) % 10 == 0 { output += programTables() }
            let framePTS = pts(frame: index)
            if includeVideo { output += videoPES(frame: index, pts: framePTS) }
            while includeAudio, MPEGTS.signedDelta(nextAudioPTS, framePTS + frameTicks) < 0 {
                output += audioPES(pts: nextAudioPTS)
                nextAudioPTS = MPEGTS.wrap(nextAudioPTS + audioTicks)
            }
        }
        resumeFrame = firstFrame + frames
        resumeAudioOffset = MPEGTS.signedDelta(nextAudioPTS, pts(frame: firstFrame + frames))
        return output
    }

    func pts(frame: Int) -> Int64 { MPEGTS.wrap(startPTS + Int64(frame) * frameTicks) }

    func kind(of frame: Int) -> PictureKind {
        guard frame % gop == 0 else { return .predicted }
        return openGOP && frame > 0 ? .intra : .idr
    }

    // MARK: - Tables

    var program: TSProgram {
        var streams: [TSProgram.Stream] = []
        if includeVideo {
            streams.append(TSProgram.Stream(pid: videoPID, streamType: videoStreamType,
                                            kind: TSProgram.kind(streamType: videoStreamType, descriptors: []), descriptors: []))
        }
        if includeAudio {
            streams.append(TSProgram.Stream(pid: audioPID, streamType: 0x0F, kind: .audio(.aac), descriptors: []))
        }
        return TSProgram(programNumber: 1, pmtPID: pmtPID, pcrPID: includeVideo ? videoPID : audioPID,
                         programDescriptors: [], streams: streams)
    }

    mutating func programTables() -> [UInt8] {
        let program = program
        var bytes: [UInt8] = []
        var patCounter = continuity[0, default: 0x0F]
        for packet in PSITables.packetize(section: PSITables.makePAT(for: program, version: 0), pid: 0, continuityCounter: &patCounter) {
            bytes += packet.bytes
        }
        continuity[0] = patCounter
        var pmtCounter = continuity[pmtPID, default: 0x0F]
        for packet in PSITables.packetize(section: PSITables.makePMT(for: program, version: 0), pid: pmtPID, continuityCounter: &pmtCounter) {
            bytes += packet.bytes
        }
        continuity[pmtPID] = pmtCounter
        return bytes
    }

    // MARK: - PES

    mutating func videoPES(frame: Int, pts: Int64) -> [UInt8] {
        let kind = kind(of: frame)
        let dts = MPEGTS.wrap(pts - frameTicks)
        let header = Self.pesHeader(streamID: 0xE0, pts: pts, dts: dts)
        return packetize(pid: videoPID, pes: header + elementaryStream(frame: frame, kind: kind),
                         pcr: dts - 9_000, randomAccess: kind != .predicted)
    }

    /// An access unit delimiter, parameter sets on keyframes, then one slice whose payload starts
    /// with the frame number (7 bits per byte, so no start code can appear) and the encoder identity.
    func elementaryStream(frame: Int, kind: PictureKind) -> [UInt8] {
        var es: [UInt8]
        if videoStreamType == 0x24 {
            es = [0, 0, 0, 1, 0x46, 0x01, 0x50]
            if kind != .predicted {
                es += [0, 0, 0, 1, 0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60]
                es += [0, 0, 0, 1, 0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90]
                es += [0, 0, 0, 1, 0x44, 0x01, 0xC1, 0x72, 0xB4, 0x62, 0x40]
            }
            switch kind {
            case .idr: es += [0, 0, 0, 1, 0x26, 0x01]        // IDR_W_RADL
            case .intra: es += [0, 0, 0, 1, 0x2A, 0x01]      // CRA
            case .predicted: es += [0, 0, 0, 1, 0x02, 0x01]  // TRAIL_R
            }
        } else {
            es = [0, 0, 0, 1, 0x09, 0xF0]
            if kind != .predicted {
                es += [0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50, 0x05, 0xBB, 0x01, 0x10]
                es += [0, 0, 0, 1, 0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0]
            }
            // Slice headers: first_mb_in_slice 0, then slice_type 7 (I) or 0 (P).
            switch kind {
            case .idr: es += [0, 0, 0, 1, 0x65, 0x88]
            case .intra: es += [0, 0, 0, 1, 0x41, 0x88]
            case .predicted: es += [0, 0, 0, 1, 0x41, 0xC0]
            }
        }
        es += [0x80 | UInt8((frame >> 21) & 0x7F), 0x80 | UInt8((frame >> 14) & 0x7F),
               0x80 | UInt8((frame >> 7) & 0x7F), 0x80 | UInt8(frame & 0x7F), 0x80 | (content & 0x7F)]
        let payloadSize = kind == .predicted ? 600 : 3_000
        for index in 0..<payloadSize {
            es.append(UInt8(truncatingIfNeeded: frame &* 31 &+ index &* 7 &+ Int(content) &* 101) | 0x01)
        }
        return es
    }

    mutating func audioPES(pts: Int64) -> [UInt8] {
        let header = Self.pesHeader(streamID: 0xC0, pts: pts, dts: nil)
        let frame = Self.adtsFrame(filler: UInt8(truncatingIfNeeded: pts / audioTicks) | 0x01)
        return packetize(pid: audioPID, pes: header + frame, pcr: includeVideo ? nil : pts - 9_000, randomAccess: false)
    }

    /// One ADTS AAC-LC frame of 1024 samples, stereo, at sampling-frequency index `rateIndex` (3 is 48 kHz).
    static func adtsFrame(rateIndex: UInt8 = 3, payloadSize: Int = 120, filler: UInt8 = 0x11) -> [UInt8] {
        let length = 7 + payloadSize
        var frame: [UInt8] = [0xFF, 0xF1, 0x40 | (rateIndex << 2), 0x80, 0, 0, 0xFC]
        frame[3] |= UInt8((length >> 11) & 0x03)
        frame[4] = UInt8((length >> 3) & 0xFF)
        frame[5] = UInt8((length & 0x07) << 5) | 0x1F
        frame += [UInt8](repeating: filler, count: payloadSize)
        return frame
    }

    static func pesHeader(streamID: UInt8, pts: Int64, dts: Int64?) -> [UInt8] {
        var header: [UInt8] = [0, 0, 1, streamID, 0, 0, 0x80, dts == nil ? 0x80 : 0xC0, dts == nil ? 5 : 10]
        header += timestamp(pts, prefix: dts == nil ? 0x20 : 0x30)
        if let dts { header += timestamp(dts, prefix: 0x10) }
        return header
    }

    static func timestamp(_ value: Int64, prefix: UInt8) -> [UInt8] {
        let v = MPEGTS.wrap(value)
        return [prefix | UInt8(((v >> 30) & 0x07) << 1) | 1, UInt8((v >> 22) & 0xFF),
                UInt8(((v >> 15) & 0x7F) << 1) | 1, UInt8((v >> 7) & 0xFF), UInt8((v & 0x7F) << 1) | 1]
    }

    // MARK: - Transport packets

    /// Splits a PES into transport packets on `pid`, padding the last one with adaptation-field
    /// stuffing so the PES ends exactly at a packet boundary.
    mutating func packetize(pid: UInt16, pes: [UInt8], pcr: Int64?, randomAccess: Bool) -> [UInt8] {
        var output: [UInt8] = []
        var remaining = pes[...]
        var first = true
        while !remaining.isEmpty {
            var adaptation: [UInt8]?
            if first, pcr != nil || randomAccess {
                var field: [UInt8] = [randomAccess ? 0x40 : 0]
                if let pcr {
                    field[0] |= 0x10
                    let base = MPEGTS.wrap(pcr)
                    field += [UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF), UInt8((base >> 9) & 0xFF),
                              UInt8((base >> 1) & 0xFF), UInt8((base & 1) << 7) | 0x7E, 0x00]
                }
                adaptation = field
            }
            let payloadCount = min(remaining.count, 184 - (adaptation.map { 1 + $0.count } ?? 0))
            let stuffing = 184 - payloadCount - (adaptation.map { 1 + $0.count } ?? 0)
            if stuffing > 0 {
                if adaptation == nil {
                    adaptation = stuffing == 1 ? [] : [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 2)
                } else {
                    adaptation? += [UInt8](repeating: 0xFF, count: stuffing)
                }
            }
            let counter = (continuity[pid, default: 0x0F] &+ 1) & 0x0F
            continuity[pid] = counter
            var packet: [UInt8] = [0x47, (first ? 0x40 : 0) | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF)]
            if let adaptation {
                packet += [0x30 | counter, UInt8(adaptation.count)] + adaptation
            } else {
                packet += [0x10 | counter]
            }
            packet += remaining.prefix(payloadCount)
            precondition(packet.count == 188, "synthetic packet is \(packet.count) bytes")
            remaining = remaining.dropFirst(payloadCount)
            output += packet
            first = false
        }
        return output
    }
}

extension SyntheticTransportStream {
    struct Picture: Equatable {
        var frame: Int
        /// The identity of the encoder that coded it.
        var content: Int
    }

    /// The frame number and encoder identity a synthetic picture carries after its slice header.
    static func picture(of unit: NormalizedUnit) -> Picture? {
        picture(in: PESUnit(sourcePID: 0, packets: unit.packets))
    }

    static func picture(in pes: PESUnit) -> Picture? {
        guard let header = pes.parseHeader() else { return nil }
        var bytes: [UInt8] = []
        pes.forEachDataChunk(from: header.dataOffset) { chunk in
            bytes.append(contentsOf: chunk)
            return bytes.count < 200
        }
        guard bytes.count > 11 else { return nil }
        for index in 0..<(bytes.count - 11)
        where bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 0 && bytes[index + 3] == 1 {
            let h264Slice = bytes[index + 4] == 0x65 || bytes[index + 4] == 0x41
            let hevcSlice = [0x26, 0x2A, 0x02].contains(bytes[index + 4]) && bytes[index + 5] == 0x01
            guard h264Slice || hevcSlice else { continue }
            let digits = bytes[(index + 6)..<(index + 11)].map { Int($0 & 0x7F) }
            return Picture(frame: digits[0] << 21 | digits[1] << 14 | digits[2] << 7 | digits[3], content: digits[4])
        }
        return nil
    }
}

/// Splits bytes that are a whole number of transport packets.
func transportPackets(_ bytes: [UInt8]) -> [TSPacket] {
    stride(from: 0, to: bytes.count - bytes.count % MPEGTS.packetSize, by: MPEGTS.packetSize).map {
        TSPacket(bytes: Array(bytes[$0..<($0 + MPEGTS.packetSize)]))
    }
}

/// The PES packets on `pid`, in order, from bytes that are a whole number of transport packets.
func pesUnits(in bytes: [UInt8], pid: UInt16) -> [PESUnit] {
    var units: [PESUnit] = []
    var current: [TSPacket] = []
    for packet in transportPackets(bytes) where packet.pid == pid {
        if packet.payloadUnitStart, !current.isEmpty {
            units.append(PESUnit(sourcePID: pid, packets: current))
            current = []
        }
        if packet.payloadUnitStart || !current.isEmpty { current.append(packet) }
    }
    if !current.isEmpty { units.append(PESUnit(sourcePID: pid, packets: current)) }
    return units
}

/// Runs bytes through aligner → splicer → segmenter the way a session does, one connection per call.
struct PipelineHarness {
    var aligner = TSPacketAligner()
    let splicer = TSTimelineSplicer()
    var segmenter = HLSSegmenter()
    var segments: [MediaSegment] = []
    var units: [NormalizedUnit] = []
    var events: [TSTimelineSplicer.Event] = []
    /// Index into `units` where each connection's output begins.
    var connectionStarts: [Int] = []
    var wall: Double = 0

    mutating func connection(_ bytes: [UInt8], chunk: Int = 1_000, outageBefore: Double = 0) {
        if !connectionStarts.isEmpty {
            // What the session does when a connection ends: drop torn PES, cut the open segment.
            splicer.endConnection()
            if let segment = segmenter.flush() { segments.append(segment) }
            aligner.reset()
        }
        connectionStarts.append(units.count)
        wall += outageBefore
        splicer.beginConnection()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            let produced = splicer.process(aligner.push(bytes[offset..<end]), wallTime: wall)
            units += produced
            segments += segmenter.append(produced)
            events += splicer.drainEvents()
            offset = end
            wall += 0.01
        }
    }

    mutating func finish() {
        splicer.endConnection()
        if let segment = segmenter.flush() { segments.append(segment) }
    }

    var spliceReports: [TSTimelineSplicer.SpliceReport] {
        events.compactMap { if case .splice(let report) = $0 { return report } else { return nil } }
    }

    var videoUnits: [NormalizedUnit] { units.filter { $0.kind == .video } }
    var audioUnits: [NormalizedUnit] { units.filter { $0.kind == .audio } }

    /// The pictures delivered, in delivery order.
    var deliveredPictures: [SyntheticTransportStream.Picture] { videoUnits.compactMap(SyntheticTransportStream.picture(of:)) }
    /// Source frame numbers of the delivered pictures, in delivery order.
    var deliveredFrames: [Int] { deliveredPictures.map(\.frame) }

    /// Steps between consecutive output decode times of the pictures.
    var videoSteps: [Int64] {
        let times = videoUnits.compactMap(\.dts)
        return zip(times.dropFirst(), times).map { MPEGTS.signedDelta($0, $1) }
    }

    /// Steps between consecutive output presentation times of the audio.
    var audioSteps: [Int64] {
        let times = audioUnits.compactMap(\.pts)
        return zip(times.dropFirst(), times).map { MPEGTS.signedDelta($0, $1) }
    }
}
