import Foundation

/// Finds out whether a video PES starts a picture the decoder can begin from.
///
/// Splices and segment cuts may only happen at such pictures; anything else would hand
/// VideoToolbox frames whose references it never saw. The first coded slice decides:
/// an IDR/IRAP picture, or (for broadcast H.264 that only sends periodic I-frames with
/// recovery points) a slice whose header says it is intra-coded, when the sequence parameter
/// set comes with it: some encoders send their parameter sets only with an IDR every few
/// seconds and flag the I-frames between as random access too, but no decoder can start at
/// one. The transport layer's random-access flag is only used when the NAL units can't be read.
nonisolated enum AccessUnitInspector {
    struct Result: Equatable {
        var isKeyframe: Bool
        /// An IDR/BLA picture, which resets the decoder's reference state. Joining a new connection
        /// at any other keyframe (an open-GOP I or CRA picture) breaks frame numbering, so the
        /// splice must be announced to AVPlayer as a discontinuity.
        var isInstantRefresh: Bool
        /// The sequence parameter set, when this picture carries one.
        var sequenceParameterSet: [UInt8]?
    }

    /// Inspects at most this many elementary-stream bytes per picture.
    private static let scanLimit = 96 * 1024

    static func inspect(_ unit: PESUnit, dataOffset: Int, codec: TSProgram.VideoCodec) -> Result {
        var scanner = NALScanner(codec: codec)
        var scanned = 0
        unit.forEachDataChunk(from: dataOffset) { chunk in
            scanned += chunk.count
            return scanner.feed(chunk) && scanned < scanLimit
        }
        scanner.finish()
        let randomAccess = unit.packets.first?.randomAccessIndicator ?? false
        let isKeyframe = scanner.verdict ?? randomAccess
        return Result(isKeyframe: isKeyframe, isInstantRefresh: isKeyframe && scanner.isInstantRefresh,
                      sequenceParameterSet: scanner.sequenceParameterSet)
    }
}

/// A start-code scanner that stops at the first coded slice.
nonisolated private struct NALScanner {
    let codec: TSProgram.VideoCodec
    /// Nil until the first coded slice (or MPEG-2 picture header) has been classified.
    private(set) var verdict: Bool?
    private(set) var isInstantRefresh = false
    private(set) var sequenceParameterSet: [UInt8]?

    private enum Capture {
        case none
        case header(kind: HeaderKind, bytes: [UInt8], needed: Int)
        case parameterSet(bytes: [UInt8])
    }
    private enum HeaderKind { case nalHeader, h264Slice, mpeg2Picture }

    private var zeros = 0
    private var capture: Capture = .none
    private var sawMPEG2SequenceHeader = false

    init(codec: TSProgram.VideoCodec) { self.codec = codec }

    /// Returns false once a verdict has been reached.
    mutating func feed(_ chunk: ArraySlice<UInt8>) -> Bool {
        for byte in chunk {
            if verdict != nil { return false }
            consume(byte)
        }
        return verdict == nil
    }

    mutating func finish() {
        if case .parameterSet(let bytes) = capture { storeParameterSet(bytes) }
        capture = .none
    }

    private mutating func consume(_ byte: UInt8) {
        // Start code: two or more zero bytes then 0x01.
        if byte == 0x01, zeros >= 2 {
            zeros = 0
            if case .parameterSet(let bytes) = capture { storeParameterSet(bytes) }
            capture = .header(kind: .nalHeader, bytes: [], needed: codec == .hevc ? 2 : 1)
            return
        }
        zeros = byte == 0x00 ? zeros + 1 : 0

        switch capture {
        case .none:
            return
        case .parameterSet(var bytes):
            if bytes.count < 256 { bytes.append(byte) }
            capture = .parameterSet(bytes: bytes)
        case .header(let kind, var bytes, let needed):
            bytes.append(byte)
            if bytes.count < needed {
                capture = .header(kind: kind, bytes: bytes, needed: needed)
            } else {
                capture = .none
                headerComplete(kind: kind, bytes: bytes)
            }
        }
    }

    private mutating func headerComplete(kind: HeaderKind, bytes: [UInt8]) {
        switch kind {
        case .nalHeader:
            classifyNAL(bytes)
        case .h264Slice:
            verdict = Self.isIntraSlice(bytes) && sequenceParameterSet != nil
        case .mpeg2Picture:
            let pictureCodingType = (bytes[1] >> 3) & 0x07
            verdict = pictureCodingType == 1 || sawMPEG2SequenceHeader
        }
    }

    private mutating func classifyNAL(_ header: [UInt8]) {
        switch codec {
        case .h264:
            let type = header[0] & 0x1F
            switch type {
            case 5:
                verdict = true
                isInstantRefresh = true
            case 1: capture = .header(kind: .h264Slice, bytes: [], needed: 8)
            case 2...4: verdict = false
            case 7: capture = .parameterSet(bytes: header)
            default: break
            }
        case .hevc:
            let type = (header[0] >> 1) & 0x3F
            switch type {
            case 16...20:
                // BLA and IDR pictures start a fresh coded video sequence.
                verdict = true
                isInstantRefresh = true
            case 21...23: verdict = true
            case 0...15, 24...31: verdict = false
            case 33: capture = .parameterSet(bytes: header)
            default: break
            }
        case .mpeg2, .mpeg1:
            switch header[0] {
            case 0xB3:
                sawMPEG2SequenceHeader = true
                capture = .parameterSet(bytes: header)
            case 0x00:
                capture = .header(kind: .mpeg2Picture, bytes: [], needed: 2)
            default:
                break
            }
        }
    }

    private mutating func storeParameterSet(_ bytes: [UInt8]) {
        guard sequenceParameterSet == nil else { return }
        var trimmed = bytes
        while trimmed.last == 0x00 { trimmed.removeLast() }
        if !trimmed.isEmpty { sequenceParameterSet = trimmed }
    }

    /// `first_mb_in_slice` then `slice_type` (both Exp-Golomb) from an H.264 slice header.
    /// Slice types 2/7 (I) and 4/9 (SI) start an intra picture.
    private static func isIntraSlice(_ bytes: [UInt8]) -> Bool {
        var reader = ExpGolombReader(bytes: removingEmulationPrevention(bytes))
        guard let firstMB = reader.readUE(), let sliceType = reader.readUE() else { return false }
        return firstMB == 0 && (sliceType % 5 == 2 || sliceType % 5 == 4)
    }

    private static func removingEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2, byte == 0x03 { zeros = 0; continue }
            zeros = byte == 0 ? zeros + 1 : 0
            output.append(byte)
        }
        return output
    }
}

nonisolated private struct ExpGolombReader {
    let bytes: [UInt8]
    private var bitIndex = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    private mutating func readBit() -> Int? {
        guard bitIndex < bytes.count * 8 else { return nil }
        let bit = Int(bytes[bitIndex / 8] >> (7 - UInt8(bitIndex % 8))) & 1
        bitIndex += 1
        return bit
    }

    mutating func readUE() -> Int? {
        var leadingZeros = 0
        while true {
            guard let bit = readBit() else { return nil }
            if bit == 1 { break }
            leadingZeros += 1
            if leadingZeros > 31 { return nil }
        }
        var value = 0
        for _ in 0..<leadingZeros {
            guard let bit = readBit() else { return nil }
            value = (value << 1) | bit
        }
        return (1 << leadingZeros) - 1 + value
    }
}
