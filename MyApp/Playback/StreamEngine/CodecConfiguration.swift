import Foundation

/// Reads the RBSP of an H.264 or HEVC NAL unit, emulation-prevention bytes removed, bit by bit.
nonisolated struct RBSPReader {
    private let bytes: [UInt8]
    private var position = 0

    /// `nal` is a whole NAL unit; its first `headerBytes` (the NAL header) are skipped.
    init<C: Collection>(nal: C, headerBytes: Int) where C.Element == UInt8 {
        var rbsp: [UInt8] = []
        rbsp.reserveCapacity(nal.count)
        var zeros = 0
        for byte in nal.dropFirst(headerBytes) {
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            rbsp.append(byte)
        }
        bytes = rbsp
    }

    var bitsLeft: Int { bytes.count * 8 - position }

    mutating func bits(_ count: Int) -> UInt64? {
        guard count >= 0, count <= 64, bitsLeft >= count else { return nil }
        var value: UInt64 = 0
        for _ in 0..<count {
            value = value << 1 | UInt64((bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1)
            position += 1
        }
        return value
    }

    mutating func flag() -> Bool? { bits(1).map { $0 == 1 } }

    /// Unsigned Exp-Golomb.
    mutating func ue() -> UInt64? {
        var zeros = 0
        while true {
            guard let bit = bits(1) else { return nil }
            if bit == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard let rest = bits(zeros) else { return nil }
        return (UInt64(1) << UInt64(zeros)) - 1 + rest
    }

    /// Signed Exp-Golomb.
    mutating func se() -> Int64? {
        guard let value = ue() else { return nil }
        return value & 1 == 1 ? Int64((value + 1) / 2) : -Int64(value / 2)
    }
}

/// Annex B byte streams: NAL units separated by start codes.
nonisolated enum AnnexB {
    /// The NAL units in `bytes`, without their start codes or the zero bytes before the next one.
    static func nalUnits(_ bytes: [UInt8]) -> [Range<Int>] {
        var units: [Range<Int>] = []
        var start: Int?
        var index = 0
        let count = bytes.count
        while index + 2 < count {
            if bytes[index + 2] > 1 {
                index += 3
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start { units.append(start..<trimmedEnd(bytes, start, index)) }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < count { units.append(start..<trimmedEnd(bytes, start, count)) }
        return units.filter { !$0.isEmpty }
    }

    /// A NAL unit never ends in a zero byte: zeros before a start code belong to it.
    private static func trimmedEnd(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Int {
        var end = end
        while end > start, bytes[end - 1] == 0 { end -= 1 }
        return end
    }

    /// Inserts emulation-prevention bytes into an RBSP to make it a NAL unit payload.
    static func addingEmulationPrevention(_ rbsp: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(rbsp.count + rbsp.count / 64)
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 0x03 {
                output.append(0x03)
                zeros = 0
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }
}

/// Colour signalling from a sequence parameter set's VUI (ITU-T H.273 code points).
nonisolated struct ColourDescription: Equatable, Sendable {
    var primaries: UInt8
    var transfer: UInt8
    var matrix: UInt8
    var fullRange: Bool

    /// HLS VIDEO-RANGE: PQ (SMPTE ST 2084) and HLG (ARIB STD-B67) are HDR; everything else is SDR.
    var videoRange: String {
        switch transfer {
        case 16: return "PQ"
        case 18: return "HLG"
        default: return "SDR"
        }
    }
}

/// What a video track's initialization section needs, read from its parameter sets.
nonisolated struct VideoTrackFormat: Equatable, Sendable {
    enum Codec: Equatable, Sendable { case hevc, h264 }
    var codec: Codec
    /// 'hvcC' or 'avcC' payload.
    var configuration: [UInt8]
    /// RFC 6381 codec string, e.g. "hvc1.2.4.L153.B0".
    var codecString: String
    var width: Int
    var height: Int
    var colour: ColourDescription?

    var sampleEntryType: String { codec == .hevc ? "hvc1" : "avc1" }
    var configurationBoxType: String { codec == .hevc ? "hvcC" : "avcC" }
    var videoRange: String { colour?.videoRange ?? "SDR" }
}

// MARK: - HEVC

nonisolated enum HEVCParameterSets {
    struct SequenceInfo: Equatable {
        var profileSpace: UInt8
        var tier: Bool
        var profile: UInt8
        /// general_profile_compatibility_flag[0...31], flag 0 in the most significant bit.
        var compatibility: UInt32
        /// The 48 bits from general_progressive_source_flag on.
        var constraints: UInt64
        var level: UInt8
        var chromaFormat: UInt8
        var bitDepthLuma: UInt8
        var bitDepthChroma: UInt8
        var width: Int
        var height: Int
        var subLayers: UInt8
        var temporalIDNested: Bool
        var colour: ColourDescription?
    }

    static func nalType(_ firstByte: UInt8) -> UInt8 { (firstByte >> 1) & 0x3F }

    /// Parses a sequence parameter set NAL unit (header included). The colour description needs
    /// the whole SPS before the VUI; if that part doesn't parse, it's left out.
    static func parseSPS<C: Collection>(_ nal: C) -> SequenceInfo? where C.Element == UInt8 {
        var reader = RBSPReader(nal: nal, headerBytes: 2)
        guard reader.bits(4) != nil, let subLayersMinus1 = reader.bits(3), let nested = reader.flag(),
              let space = reader.bits(2), let tier = reader.flag(), let profile = reader.bits(5),
              let compatibility = reader.bits(32), let constraints = reader.bits(48), let level = reader.bits(8)
        else { return nil }
        let subLayers = Int(subLayersMinus1)
        var profilePresent: [Bool] = []
        var levelPresent: [Bool] = []
        for _ in 0..<subLayers {
            guard let p = reader.flag(), let l = reader.flag() else { return nil }
            profilePresent.append(p)
            levelPresent.append(l)
        }
        if subLayers > 0 {
            for _ in subLayers..<8 { guard reader.bits(2) != nil else { return nil } }
        }
        for index in 0..<subLayers {
            if profilePresent[index] { guard reader.bits(64) != nil, reader.bits(24) != nil else { return nil } }
            if levelPresent[index] { guard reader.bits(8) != nil else { return nil } }
        }
        guard reader.ue() != nil, let chroma = reader.ue(), chroma <= 3 else { return nil }
        if chroma == 3 { guard reader.flag() != nil else { return nil } }
        guard let lumaWidth = reader.ue(), let lumaHeight = reader.ue(), let windowed = reader.flag() else { return nil }
        var window: [UInt64] = [0, 0, 0, 0]
        if windowed {
            for index in 0..<4 { guard let value = reader.ue() else { return nil }; window[index] = value }
        }
        guard let depthLuma = reader.ue(), let depthChroma = reader.ue(), depthLuma <= 8, depthChroma <= 8 else { return nil }
        let subWidth: UInt64 = chroma == 1 || chroma == 2 ? 2 : 1
        let subHeight: UInt64 = chroma == 1 ? 2 : 1
        var info = SequenceInfo(
            profileSpace: UInt8(space), tier: tier, profile: UInt8(profile), compatibility: UInt32(compatibility),
            constraints: constraints, level: UInt8(level), chromaFormat: UInt8(chroma),
            bitDepthLuma: UInt8(depthLuma + 8), bitDepthChroma: UInt8(depthChroma + 8),
            width: Int(lumaWidth) - Int(subWidth * (window[0] + window[1])),
            height: Int(lumaHeight) - Int(subHeight * (window[2] + window[3])),
            subLayers: UInt8(subLayers + 1), temporalIDNested: nested, colour: nil)
        info.colour = parseColour(&reader, subLayers: subLayers)
        return info
    }

    /// Walks the rest of the SPS to its VUI and reads the colour description, if present.
    private static func parseColour(_ reader: inout RBSPReader, subLayers: Int) -> ColourDescription? {
        guard let pocBitsMinus4 = reader.ue(), let orderingInfo = reader.flag() else { return nil }
        for _ in (orderingInfo ? 0 : subLayers)...subLayers {
            guard reader.ue() != nil, reader.ue() != nil, reader.ue() != nil else { return nil }
        }
        for _ in 0..<6 { guard reader.ue() != nil else { return nil } }
        guard let scalingLists = reader.flag() else { return nil }
        if scalingLists {
            guard let present = reader.flag() else { return nil }
            if present, !skipScalingListData(&reader) { return nil }
        }
        guard reader.flag() != nil, reader.flag() != nil, let pcm = reader.flag() else { return nil }
        if pcm {
            guard reader.bits(8) != nil, reader.ue() != nil, reader.ue() != nil, reader.flag() != nil else { return nil }
        }
        guard let sets = reader.ue(), sets <= 64 else { return nil }
        var deltaCounts: [Int] = []
        for index in 0..<Int(sets) {
            guard let count = skipShortTermReferenceSet(&reader, index: index, deltaCounts: deltaCounts) else { return nil }
            deltaCounts.append(count)
        }
        guard let longTerm = reader.flag() else { return nil }
        if longTerm {
            guard let count = reader.ue(), count <= 32 else { return nil }
            for _ in 0..<count { guard reader.bits(Int(pocBitsMinus4) + 4) != nil, reader.flag() != nil else { return nil } }
        }
        guard reader.flag() != nil, reader.flag() != nil, let vui = reader.flag(), vui else { return nil }
        return parseVUIColour(&reader)
    }

    private static func skipScalingListData(_ reader: inout RBSPReader) -> Bool {
        for size in 0..<4 {
            var matrix = 0
            while matrix < 6 {
                guard let predicted = reader.flag() else { return false }
                if !predicted {
                    guard reader.ue() != nil else { return false }
                } else {
                    let coefficients = min(64, 1 << (4 + (size << 1)))
                    if size > 1 { guard reader.se() != nil else { return false } }
                    for _ in 0..<coefficients { guard reader.se() != nil else { return false } }
                }
                matrix += size == 3 ? 3 : 1
            }
        }
        return true
    }

    /// Skips st_ref_pic_set(index) and returns its NumDeltaPocs.
    private static func skipShortTermReferenceSet(_ reader: inout RBSPReader, index: Int, deltaCounts: [Int]) -> Int? {
        var predicted = false
        if index != 0 { guard let flag = reader.flag() else { return nil }; predicted = flag }
        if predicted {
            guard reader.flag() != nil, reader.ue() != nil, let reference = deltaCounts.last else { return nil }
            var count = 0
            for _ in 0...reference {
                guard let used = reader.flag() else { return nil }
                var useDelta = true
                if !used { guard let flag = reader.flag() else { return nil }; useDelta = flag }
                if used || useDelta { count += 1 }
            }
            return count
        }
        guard let negative = reader.ue(), let positive = reader.ue(), negative <= 16, positive <= 16 else { return nil }
        for _ in 0..<(negative + positive) { guard reader.ue() != nil, reader.flag() != nil else { return nil } }
        return Int(negative + positive)
    }

    /// Builds the 'hvcC' payload: parameter sets in the sample entry ('hvc1': complete arrays),
    /// plus declarative SEI such as HDR10 static metadata.
    static func decoderConfiguration(info: SequenceInfo, vps: [[UInt8]], sps: [[UInt8]], pps: [[UInt8]],
                                     sei: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = [1, info.profileSpace << 6 | (info.tier ? 0x20 : 0) | info.profile]
        bytes += [UInt8(info.compatibility >> 24), UInt8((info.compatibility >> 16) & 0xFF),
                  UInt8((info.compatibility >> 8) & 0xFF), UInt8(info.compatibility & 0xFF)]
        for shift in stride(from: 40, through: 0, by: -8) { bytes.append(UInt8((info.constraints >> UInt64(shift)) & 0xFF)) }
        bytes += [info.level, 0xF0, 0x00, 0xFC, 0xFC | info.chromaFormat,
                  0xF8 | (info.bitDepthLuma - 8), 0xF8 | (info.bitDepthChroma - 8), 0x00, 0x00,
                  (info.subLayers & 0x07) << 3 | (info.temporalIDNested ? 0x04 : 0) | 0x03]
        let arrays = [(UInt8(32), vps, true), (33, sps, true), (34, pps, true), (39, sei, false)].filter { !$0.1.isEmpty }
        bytes.append(UInt8(arrays.count))
        for (type, units, complete) in arrays {
            bytes += [(complete ? 0x80 : 0) | type, UInt8(units.count >> 8), UInt8(units.count & 0xFF)]
            for unit in units { bytes += [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit }
        }
        return bytes
    }

    /// ISO/IEC 14496-15 annex E codec string, e.g. "hvc1.2.4.L153.B0".
    static func codecString(_ info: SequenceInfo) -> String {
        let space = ["", "A", "B", "C"][Int(info.profileSpace & 3)]
        var reversed: UInt32 = 0
        for bit in 0..<32 where info.compatibility & (1 << UInt32(31 - bit)) != 0 { reversed |= 1 << UInt32(bit) }
        var text = "hvc1.\(space)\(info.profile).\(String(reversed, radix: 16, uppercase: true)).\(info.tier ? "H" : "L")\(info.level)"
        var constraintBytes = (0..<6).map { UInt8((info.constraints >> UInt64(40 - $0 * 8)) & 0xFF) }
        while constraintBytes.last == 0 { constraintBytes.removeLast() }
        for byte in constraintBytes { text += "." + String(byte, radix: 16, uppercase: true) }
        return text
    }

    /// The HDR10 static metadata (mastering display colour volume, content light level) from
    /// prefix SEI NAL units, rebuilt as one SEI NAL unit for the 'hvcC' declarative array.
    static func staticHDRMetadata(_ seiUnits: [[UInt8]]) -> [UInt8]? {
        var messages: [UInt8] = []
        var seen: Set<UInt64> = []
        for unit in seiUnits where unit.count > 2 && nalType(unit[0]) == 39 {
            var reader = RBSPReader(nal: unit, headerBytes: 2)
            // A message needs a type and a size byte; the last byte is the RBSP stop bit.
            while reader.bitsLeft > 8 {
                guard let type = readSEIValue(&reader), let size = readSEIValue(&reader), size <= 1024 else { break }
                var payload: [UInt8] = []
                for _ in 0..<size {
                    guard let byte = reader.bits(8) else { return messages.isEmpty ? nil : finish(messages) }
                    payload.append(UInt8(byte))
                }
                if type == 137 || type == 144, seen.insert(type).inserted {
                    messages += seiValue(type) + seiValue(UInt64(payload.count)) + payload
                }
            }
        }
        return messages.isEmpty ? nil : finish(messages)
    }

    /// The preferred transfer characteristics an alternative-transfer-characteristics SEI announces.
    /// Broadcasters send HLG with a BT.2020 SDR transfer in the VUI, for older receivers, and this
    /// SEI naming HLG (18).
    static func preferredTransfer(_ seiUnits: [[UInt8]]) -> UInt8? {
        for unit in seiUnits where unit.count > 2 && nalType(unit[0]) == 39 {
            var reader = RBSPReader(nal: unit, headerBytes: 2)
            while reader.bitsLeft > 8 {
                guard let type = readSEIValue(&reader), let size = readSEIValue(&reader) else { break }
                if type == 147, size >= 1, let value = reader.bits(8) { return UInt8(value) }
                for _ in 0..<size { guard reader.bits(8) != nil else { break } }
            }
        }
        return nil
    }

    private static func finish(_ messages: [UInt8]) -> [UInt8] {
        [0x4E, 0x01] + AnnexB.addingEmulationPrevention(messages + [0x80])
    }

    private static func readSEIValue(_ reader: inout RBSPReader) -> UInt64? {
        var value: UInt64 = 0
        while true {
            guard let byte = reader.bits(8) else { return nil }
            value += byte
            if byte != 0xFF { return value }
        }
    }

    private static func seiValue(_ value: UInt64) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: Int(value / 255)) + [UInt8(value % 255)]
    }
}

// MARK: - H.264

nonisolated enum AVCParameterSets {
    struct SequenceInfo: Equatable {
        var profile: UInt8
        var constraints: UInt8
        var level: UInt8
        var chromaFormat: UInt8
        var bitDepthLuma: UInt8
        var bitDepthChroma: UInt8
        var width: Int
        var height: Int
        var colour: ColourDescription?
    }

    static func nalType(_ firstByte: UInt8) -> UInt8 { firstByte & 0x1F }

    static func parseSPS<C: Collection>(_ nal: C) -> SequenceInfo? where C.Element == UInt8 {
        var reader = RBSPReader(nal: nal, headerBytes: 1)
        guard let profile = reader.bits(8), let constraints = reader.bits(8), let level = reader.bits(8), reader.ue() != nil else {
            return nil
        }
        var chroma: UInt64 = 1
        var depthLuma: UInt64 = 0
        var depthChroma: UInt64 = 0
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let value = reader.ue(), value <= 3 else { return nil }
            chroma = value
            if chroma == 3 { guard reader.flag() != nil else { return nil } }
            guard let luma = reader.ue(), let chromaDepth = reader.ue(), reader.flag() != nil, let matrices = reader.flag() else { return nil }
            depthLuma = luma
            depthChroma = chromaDepth
            if matrices {
                for index in 0..<(chroma == 3 ? 12 : 8) {
                    guard let present = reader.flag() else { return nil }
                    if present, !skipScalingList(&reader, size: index < 6 ? 16 : 64) { return nil }
                }
            }
        }
        guard reader.ue() != nil, let pocType = reader.ue() else { return nil }
        if pocType == 0 {
            guard reader.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard reader.flag() != nil, reader.se() != nil, reader.se() != nil, let cycle = reader.ue(), cycle <= 255 else { return nil }
            for _ in 0..<cycle { guard reader.se() != nil else { return nil } }
        }
        guard reader.ue() != nil, reader.flag() != nil, let widthMBs = reader.ue(), let heightUnits = reader.ue(),
              let frameOnly = reader.flag() else { return nil }
        if !frameOnly { guard reader.flag() != nil else { return nil } }
        guard reader.flag() != nil, let cropped = reader.flag() else { return nil }
        var crop: [UInt64] = [0, 0, 0, 0]
        if cropped {
            for index in 0..<4 { guard let value = reader.ue() else { return nil }; crop[index] = value }
        }
        let frames: UInt64 = frameOnly ? 1 : 2
        let cropX: UInt64 = chroma == 1 || chroma == 2 ? 2 : 1
        let cropY: UInt64 = (chroma == 1 ? 2 : 1) * frames
        var info = SequenceInfo(
            profile: UInt8(profile), constraints: UInt8(constraints), level: UInt8(level), chromaFormat: UInt8(chroma),
            bitDepthLuma: UInt8(depthLuma + 8), bitDepthChroma: UInt8(depthChroma + 8),
            width: Int((widthMBs + 1) * 16) - Int(cropX * (crop[0] + crop[1])),
            height: Int(frames * (heightUnits + 1) * 16) - Int(cropY * (crop[2] + crop[3])),
            colour: nil)
        if let vui = reader.flag(), vui { info.colour = parseVUIColour(&reader) }
        return info
    }

    private static func skipScalingList(_ reader: inout RBSPReader, size: Int) -> Bool {
        var last: Int64 = 8
        var next: Int64 = 8
        for _ in 0..<size {
            if next != 0 {
                guard let delta = reader.se() else { return false }
                next = (last + delta + 256) % 256
            }
            if next != 0 { last = next }
        }
        return true
    }

    static func decoderConfiguration(info: SequenceInfo, sps: [[UInt8]], pps: [[UInt8]]) -> [UInt8] {
        guard let first = sps.first, first.count >= 4 else { return [] }
        var bytes: [UInt8] = [1, first[1], first[2], first[3], 0xFF, 0xE0 | UInt8(sps.count & 0x1F)]
        for unit in sps { bytes += [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit }
        bytes.append(UInt8(pps.count & 0xFF))
        for unit in pps { bytes += [UInt8(unit.count >> 8), UInt8(unit.count & 0xFF)] + unit }
        if [100, 110, 122, 144].contains(info.profile) {
            bytes += [0xFC | info.chromaFormat, 0xF8 | (info.bitDepthLuma - 8), 0xF8 | (info.bitDepthChroma - 8), 0]
        }
        return bytes
    }

    static func codecString(sps: [UInt8]) -> String {
        guard sps.count >= 4 else { return "avc1" }
        return String(format: "avc1.%02x%02x%02x", sps[1], sps[2], sps[3])
    }
}

/// aspect_ratio_info, overscan_info and video_signal_type, up to the colour description.
nonisolated private func parseVUIColour(_ reader: inout RBSPReader) -> ColourDescription? {
    guard let aspect = reader.flag() else { return nil }
    if aspect {
        guard let idc = reader.bits(8) else { return nil }
        if idc == 255 { guard reader.bits(32) != nil else { return nil } }
    }
    guard let overscan = reader.flag() else { return nil }
    if overscan { guard reader.flag() != nil else { return nil } }
    guard let signalType = reader.flag(), signalType, reader.bits(3) != nil, let fullRange = reader.flag(),
          let described = reader.flag(), described,
          let primaries = reader.bits(8), let transfer = reader.bits(8), let matrix = reader.bits(8) else { return nil }
    return ColourDescription(primaries: UInt8(primaries), transfer: UInt8(transfer), matrix: UInt8(matrix), fullRange: fullRange)
}

// MARK: - Audio

/// What an audio track's initialization section needs, read from the first frame.
nonisolated struct AudioTrackFormat: Equatable, Sendable {
    enum Codec: Equatable, Sendable { case aac, ac3, eac3 }
    var codec: Codec
    /// Track timescale: the decoded sample rate.
    var sampleRate: Int
    var channelCount: Int
    /// Decoded samples per access unit.
    var samplesPerFrame: Int
    /// 'esds' AudioSpecificConfig, 'dac3' or 'dec3' payload.
    var configuration: [UInt8]
    var codecString: String
    /// Kilobits per second, where the bitstream says (AC-3, E-AC-3).
    var bitrate: Int?

    var sampleEntryType: String {
        switch codec {
        case .aac: return "mp4a"
        case .ac3: return "ac-3"
        case .eac3: return "ec-3"
        }
    }
}

nonisolated enum AudioFrames {
    static let aacSampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
    private static let ac3Rates = [48_000, 44_100, 32_000]
    /// AC-3 frame sizes in 16-bit words by frmsizecod, for 48, 44.1 and 32 kHz.
    private static let ac3FrameWords: [[Int]] = [
        [64, 64, 80, 80, 96, 96, 112, 112, 128, 128, 160, 160, 192, 192, 224, 224, 256, 256, 320, 320, 384, 384,
         448, 448, 512, 512, 640, 640, 768, 768, 896, 896, 1024, 1024, 1152, 1152, 1280, 1280],
        [69, 70, 87, 88, 104, 105, 121, 122, 139, 140, 174, 175, 208, 209, 243, 244, 278, 279, 348, 349, 417, 418,
         487, 488, 557, 558, 696, 697, 835, 836, 975, 976, 1114, 1115, 1253, 1254, 1393, 1394],
        [96, 96, 120, 120, 144, 144, 168, 168, 192, 192, 240, 240, 288, 288, 336, 336, 384, 384, 480, 480, 576, 576,
         672, 672, 768, 768, 960, 960, 1152, 1152, 1344, 1344, 1536, 1536, 1728, 1728, 1920, 1920]
    ]
    private static let ac3Bitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
    /// Full-bandwidth channels by acmod.
    private static let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]

    /// One access unit: where it starts in the elementary stream and the bytes the MP4 sample keeps.
    struct Frame {
        var range: Range<Int>
        var payload: Range<Int>
    }

    /// Splits whole frames off the front of `bytes`; what's left is an incomplete frame.
    static func split(_ bytes: [UInt8], codec: TSProgram.AudioCodec) -> (frames: [Frame], consumed: Int) {
        var frames: [Frame] = []
        var index = 0
        while index < bytes.count {
            guard let frame = frame(in: bytes, at: index, codec: codec) else {
                // Not a frame start: resynchronise on the next sync word.
                guard let next = nextSync(bytes, after: index, codec: codec) else { return (frames, bytes.count) }
                index = next
                continue
            }
            guard frame.range.upperBound <= bytes.count else { break }
            frames.append(frame)
            index = frame.range.upperBound
        }
        return (frames, index)
    }

    private static func frame(in bytes: [UInt8], at index: Int, codec: TSProgram.AudioCodec) -> Frame? {
        switch codec {
        case .aac:
            guard index + 7 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] & 0xF6 == 0xF0 else { return nil }
            let headerLength = bytes[index + 1] & 0x01 == 1 ? 7 : 9
            let length = (Int(bytes[index + 3] & 0x03) << 11) | (Int(bytes[index + 4]) << 3) | Int(bytes[index + 5] >> 5)
            // Several raw data blocks in one ADTS frame can't be told apart without its CRCs.
            guard length > headerLength, bytes[index + 6] & 0x03 == 0 else { return nil }
            return Frame(range: index..<(index + length), payload: (index + headerLength)..<(index + length))
        case .ac3:
            guard index + 6 <= bytes.count, bytes[index] == 0x0B, bytes[index + 1] == 0x77 else { return nil }
            let fscod = Int(bytes[index + 4] >> 6)
            let sizeCode = Int(bytes[index + 4] & 0x3F)
            guard fscod < 3, sizeCode < 38 else { return nil }
            let length = ac3FrameWords[fscod][sizeCode] * 2
            return Frame(range: index..<(index + length), payload: index..<(index + length))
        case .eac3:
            guard index + 6 <= bytes.count, bytes[index] == 0x0B, bytes[index + 1] == 0x77 else { return nil }
            let length = (((Int(bytes[index + 2] & 0x07) << 8) | Int(bytes[index + 3])) + 1) * 2
            guard length >= 6 else { return nil }
            return Frame(range: index..<(index + length), payload: index..<(index + length))
        case .aacLATM, .mpegAudio:
            return nil
        }
    }

    private static func nextSync(_ bytes: [UInt8], after index: Int, codec: TSProgram.AudioCodec) -> Int? {
        var candidate = index + 1
        while candidate + 1 < bytes.count {
            switch codec {
            case .aac: if bytes[candidate] == 0xFF, bytes[candidate + 1] & 0xF6 == 0xF0 { return candidate }
            default: if bytes[candidate] == 0x0B, bytes[candidate + 1] == 0x77 { return candidate }
            }
            candidate += 1
        }
        return nil
    }

    /// The track format a frame announces. `strmtyp` and dependent substreams of E-AC-3 are folded
    /// into the access unit by the caller; this reads the independent substream's header.
    static func format(of frame: ArraySlice<UInt8>, codec: TSProgram.AudioCodec) -> AudioTrackFormat? {
        let bytes = Array(frame)
        switch codec {
        case .aac: return aacFormat(bytes)
        case .ac3: return ac3Format(bytes)
        case .eac3: return eac3Format(bytes)
        case .aacLATM, .mpegAudio: return nil
        }
    }

    private static func aacFormat(_ bytes: [UInt8]) -> AudioTrackFormat? {
        guard bytes.count >= 7 else { return nil }
        let objectType = Int(bytes[2] >> 6) + 1
        let rateIndex = Int((bytes[2] >> 2) & 0x0F)
        let channels = Int((bytes[2] & 0x01) << 2 | bytes[3] >> 6)
        guard rateIndex < aacSampleRates.count, channels > 0, objectType <= 4 else { return nil }
        let rate = aacSampleRates[rateIndex]
        let channelCount = channels == 7 ? 8 : channels
        // Broadcast AAC at 24 kHz or less is HE-AAC: SBR doubles the rate. Apple requires SBR to be
        // signalled explicitly in fMP4 (AudioSpecificConfig with object type 5).
        if objectType == 2, rate <= 24_000, let doubled = aacSampleRates.firstIndex(of: rate * 2) {
            var writer = BitWriter()
            writer.write(5, bits: 5)
            writer.write(UInt64(rateIndex), bits: 4)
            writer.write(UInt64(channels), bits: 4)
            writer.write(UInt64(doubled), bits: 4)
            writer.write(2, bits: 5)
            writer.write(0, bits: 3)
            return AudioTrackFormat(codec: .aac, sampleRate: rate * 2, channelCount: channelCount, samplesPerFrame: 2048,
                                    configuration: writer.bytes, codecString: "mp4a.40.5", bitrate: nil)
        }
        var writer = BitWriter()
        writer.write(UInt64(objectType), bits: 5)
        writer.write(UInt64(rateIndex), bits: 4)
        writer.write(UInt64(channels), bits: 4)
        writer.write(0, bits: 3)
        return AudioTrackFormat(codec: .aac, sampleRate: rate, channelCount: channelCount, samplesPerFrame: 1024,
                                configuration: writer.bytes, codecString: "mp4a.40.\(objectType)", bitrate: nil)
    }

    private static func ac3Format(_ bytes: [UInt8]) -> AudioTrackFormat? {
        guard bytes.count >= 8 else { return nil }
        var reader = BitReader(bytes: Array(bytes[4...]))
        guard let fscod = reader.read(2), let sizeCode = reader.read(6), let bsid = reader.read(5), let bsmod = reader.read(3),
              let acmod = reader.read(3), fscod < 3, sizeCode < 38 else { return nil }
        if acmod & 1 != 0, acmod != 1 { _ = reader.read(2) }
        if acmod & 4 != 0 { _ = reader.read(2) }
        if acmod == 2 { _ = reader.read(2) }
        guard let lfe = reader.read(1) else { return nil }
        var writer = BitWriter()
        writer.write(fscod, bits: 2)
        writer.write(bsid, bits: 5)
        writer.write(bsmod, bits: 3)
        writer.write(acmod, bits: 3)
        writer.write(lfe, bits: 1)
        writer.write(sizeCode >> 1, bits: 5)
        writer.write(0, bits: 5)
        return AudioTrackFormat(codec: .ac3, sampleRate: ac3Rates[Int(fscod)], channelCount: acmodChannels[Int(acmod)] + Int(lfe),
                                samplesPerFrame: 1536, configuration: writer.bytes, codecString: "ac-3",
                                bitrate: ac3Bitrates[Int(sizeCode >> 1)])
    }

    private static func eac3Format(_ bytes: [UInt8]) -> AudioTrackFormat? {
        guard bytes.count >= 6 else { return nil }
        var reader = BitReader(bytes: Array(bytes[2...]))
        guard reader.read(2) != nil, reader.read(3) != nil, let size = reader.read(11), let fscod = reader.read(2) else { return nil }
        var rate: Int
        var blocks = 6
        if fscod == 3 {
            guard let half = reader.read(2), half < 3 else { return nil }
            rate = ac3Rates[Int(half)] / 2
        } else {
            guard let blockCode = reader.read(2) else { return nil }
            rate = ac3Rates[Int(fscod)]
            blocks = [1, 2, 3, 6][Int(blockCode)]
        }
        guard let acmod = reader.read(3), let lfe = reader.read(1), let bsid = reader.read(5) else { return nil }
        let frameBytes = Int(size + 1) * 2
        let kilobits = frameBytes * 8 * rate / (blocks * 256) / 1000
        var writer = BitWriter()
        writer.write(UInt64(kilobits), bits: 13)
        writer.write(0, bits: 3)
        writer.write(fscod == 3 ? 3 : fscod, bits: 2)
        writer.write(bsid, bits: 5)
        writer.write(0, bits: 1)
        writer.write(0, bits: 1)
        writer.write(0, bits: 3)
        writer.write(acmod, bits: 3)
        writer.write(lfe, bits: 1)
        writer.write(0, bits: 3)
        writer.write(0, bits: 4)
        writer.write(0, bits: 1)
        return AudioTrackFormat(codec: .eac3, sampleRate: rate, channelCount: acmodChannels[Int(acmod)] + Int(lfe),
                                samplesPerFrame: 1536, configuration: writer.bytes, codecString: "ec-3", bitrate: kilobits)
    }

    /// E-AC-3 syncframe fields that decide how frames group into 1536-sample access units.
    static func eac3Frame(_ bytes: ArraySlice<UInt8>) -> (independent: Bool, substream: Int, blocks: Int)? {
        guard bytes.count >= 5 else { return nil }
        let start = bytes.startIndex
        let streamType = Int(bytes[start + 2] >> 6)
        let substream = Int((bytes[start + 2] >> 3) & 0x07)
        let fscod = bytes[start + 4] >> 6
        let blocks = fscod == 3 ? 6 : [1, 2, 3, 6][Int((bytes[start + 4] >> 4) & 0x03)]
        return (streamType != 1, substream, blocks)
    }
}

/// Big-endian bit packing for small configuration records.
nonisolated struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var used = 8

    mutating func write(_ value: UInt64, bits count: Int) {
        for index in stride(from: count - 1, through: 0, by: -1) {
            if used == 8 {
                bytes.append(0)
                used = 0
            }
            if (value >> UInt64(index)) & 1 == 1 { bytes[bytes.count - 1] |= 0x80 >> UInt8(used) }
            used += 1
        }
    }
}

/// Big-endian bit reading for audio headers (no emulation prevention).
nonisolated struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> UInt64? {
        guard position + count <= bytes.count * 8 else { return nil }
        var value: UInt64 = 0
        for _ in 0..<count {
            value = value << 1 | UInt64((bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1)
            position += 1
        }
        return value
    }
}
