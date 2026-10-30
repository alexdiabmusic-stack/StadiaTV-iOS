import Foundation
import Testing
@testable import StreamEngineCore

/// Parameter sets and SEI written by real encoders (x265 3.5, x264), and what independent tools
/// (MP4Box, ffprobe) read from them.
enum EncoderSamples {
    /// x265: 3840x2160 Main 10, level 5.1, BT.2020 PQ; MP4Box: hvc1.2.4.L153.90.
    static let pqVPS = hex("40010c01ffff022000000300900000030000030099959409")
    static let pqSPS = hex("420101022000000300900000030000030099a001e020021c4d965654a4c2f016a122012080000003008000001904")
    static let pps = hex("4401c073c189")
    /// Content light level SEI: MaxCLL 1000, MaxFALL 400.
    static let contentLightLevel = hex("4e01900403e8019080")
    /// Mastering display colour volume SEI: BT.2020 primaries, D65, 1000 and 0.0001 cd/m².
    static let masteringDisplay = hex("4e01891833c286c41d4c0bb884d03e803d13404200989680000003000180")
    /// x265: 1280x720 Main 10, level 4, BT.2020 HLG; MP4Box: hvc1.2.4.L120.90.
    static let hlgVPS = hex("40010c01ffff022000000300900000030000030078959409")
    static let hlgSPS = hex("420101022000000300900000030000030078a00280802d136595952930bc05a848904820000003002000000641")
    /// x265: the same 720p Main 10 with a BT.2020 SDR transfer (14) in the VUI, the way broadcasters
    /// send HLG to older receivers.
    static let bt2020VPS = hex("40010c01ffff022000000300900000030000030078959809")
    static let bt2020SPS = hex("420101022000000300900000030000030078a00280802d1365959a4932bc05a848704820000003002000000641")
    static let bt2020PPS = hex("4401c172b46240")
    /// Alternative transfer characteristics SEI preferring HLG (18).
    static let preferHLG: [UInt8] = [0x4E, 0x01, 0x93, 0x01, 0x12, 0x80]
    /// x265: 1920x1080 Main, level 4, no colour description; MP4Box: hvc1.1.6.L120.90.
    static let sdrVPS = hex("40010c01ffff016000000300900000030000030078959409")
    static let sdrSPS = hex("420101016000000300900000030000030078a003c0801107cb965654a4c2f0168080000003008000000c84")
    /// x264: 1280x720 High, level 3.2, BT.709; MP4Box: avc1.640020.
    static let avcHighSPS = hex("67640020acd9405005bb016a020202800000030080000032078c18cb")
    static let avcHighPPS = hex("68ebe3cb22c0")
    /// x264: 1920x1080, coded as 1088 lines and cropped, Constrained Baseline, level 4; MP4Box: avc1.42C028.
    static let avcBaselineSPS = hex("6742c028da01e0089f97016a020202800000030080000019078c1950")

    /// What a 4K PQ channel sends before each keyframe.
    static var pq: [[UInt8]] { [pqVPS, pqSPS, pps, contentLightLevel, masteringDisplay] }

    /// The two HDR10 SEI messages in one SEI NAL unit, as the configuration record carries them.
    static let combinedHDR10 = hex("4e01900403e80190891833c286c41d4c0bb884d03e803d13404200989680000003000180")

    static func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}

@Suite("Codec configuration")
struct CodecConfigurationTests {
    @Test("HEVC sequence parameter sets from x265 give the size, profile, colour and codec MP4Box reads")
    func hevcSequenceParameterSets() throws {
        let pq = try #require(HEVCParameterSets.parseSPS(EncoderSamples.pqSPS))
        #expect(pq.width == 3840 && pq.height == 2160)
        #expect(pq.profile == 2 && !pq.tier && pq.level == 153)
        #expect(pq.chromaFormat == 1 && pq.bitDepthLuma == 10 && pq.bitDepthChroma == 10)
        #expect(pq.colour == ColourDescription(primaries: 9, transfer: 16, matrix: 9, fullRange: false))
        #expect(pq.colour?.videoRange == "PQ")
        #expect(HEVCParameterSets.codecString(pq) == "hvc1.2.4.L153.90")

        let hlg = try #require(HEVCParameterSets.parseSPS(EncoderSamples.hlgSPS))
        #expect(hlg.width == 1280 && hlg.height == 720)
        #expect(hlg.colour == ColourDescription(primaries: 9, transfer: 18, matrix: 9, fullRange: false))
        #expect(hlg.colour?.videoRange == "HLG")
        #expect(HEVCParameterSets.codecString(hlg) == "hvc1.2.4.L120.90")

        let sdr = try #require(HEVCParameterSets.parseSPS(EncoderSamples.sdrSPS))
        #expect(sdr.width == 1920 && sdr.height == 1080)
        #expect(sdr.profile == 1 && sdr.bitDepthLuma == 8)
        #expect(sdr.colour == nil)
        #expect(HEVCParameterSets.codecString(sdr) == "hvc1.1.6.L120.90")

        // High tier and other constraint flags, as broadcast encoders set them.
        var high = pq
        high.tier = true
        high.constraints = 0xB000_0000_0000
        #expect(HEVCParameterSets.codecString(high) == "hvc1.2.4.H153.B0")
        #expect(HEVCParameterSets.parseSPS(EncoderSamples.pqSPS.prefix(12)) == nil)
    }

    @Test("The hvcC record carries the profile, the parameter sets as complete arrays and the HDR10 SEI")
    func hevcConfigurationRecord() throws {
        let info = try #require(HEVCParameterSets.parseSPS(EncoderSamples.pqSPS))
        let record = HEVCParameterSets.decoderConfiguration(info: info, vps: [EncoderSamples.pqVPS], sps: [EncoderSamples.pqSPS],
                                                             pps: [EncoderSamples.pps], sei: [EncoderSamples.combinedHDR10])
        // Profile, compatibility and constraint flags and level as in the SPS (emulation prevention
        // removed); 4:2:0 10-bit; one temporal layer, nested; 4-byte NAL unit lengths; four arrays.
        let header: [UInt8] = [0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x99,
                               0xF0, 0x00, 0xFC, 0xFD, 0xFA, 0xFA, 0x00, 0x00, 0x0F, 0x04]
        #expect(Array(record.prefix(header.count)) == header)
        var index = header.count
        let arrays: [(UInt8, [UInt8])] = [(0xA0, EncoderSamples.pqVPS), (0xA1, EncoderSamples.pqSPS), (0xA2, EncoderSamples.pps),
                                          (0x27, EncoderSamples.combinedHDR10)]
        for (typeByte, unit) in arrays {
            guard index + 5 <= record.count else {
                Issue.record("record ends early")
                return
            }
            #expect(record[index] == typeByte)
            #expect(record[index + 1] == 0 && record[index + 2] == 1)
            let length = Int(record[index + 3]) << 8 | Int(record[index + 4])
            #expect(Array(record[(index + 5)..<min(record.count, index + 5 + length)]) == unit)
            index += 5 + length
        }
        #expect(index == record.count)
    }

    @Test("HDR10 static metadata is gathered into one SEI for the configuration record; other SEI is left out")
    func hdrStaticMetadata() throws {
        // x265's encoder-settings SEI (user data unregistered) comes first on the keyframe.
        let userData: [UInt8] = [0x4E, 0x01, 0x05, 0x12] + [UInt8](repeating: 0x5A, count: 18) + [0x80]
        let sei = try #require(HEVCParameterSets.staticHDRMetadata([userData, EncoderSamples.contentLightLevel,
                                                                     EncoderSamples.masteringDisplay, EncoderSamples.contentLightLevel]))
        #expect(sei == EncoderSamples.combinedHDR10)
        #expect(HEVCParameterSets.staticHDRMetadata([userData]) == nil)
        #expect(HEVCParameterSets.staticHDRMetadata([]) == nil)
    }

    @Test("HLG sent with an SDR transfer in the VUI is recognised from its alternative transfer SEI")
    func alternativeTransfer() {
        let userData: [UInt8] = [0x4E, 0x01, 0x05, 0x12] + [UInt8](repeating: 0x5A, count: 18)
        #expect(HEVCParameterSets.preferredTransfer([userData + [0x93, 0x01, 0x12, 0x80]]) == 18)
        #expect(HEVCParameterSets.preferredTransfer([EncoderSamples.contentLightLevel]) == nil)
    }

    @Test("H.264 sequence parameter sets from x264 give the size MP4Box reads, cropping included, and the avcC record")
    func h264SequenceParameterSets() throws {
        let high = try #require(AVCParameterSets.parseSPS(EncoderSamples.avcHighSPS))
        #expect(high.width == 1280 && high.height == 720)
        #expect(high.profile == 100 && high.level == 32)
        #expect(high.colour == ColourDescription(primaries: 1, transfer: 1, matrix: 1, fullRange: false))
        #expect(AVCParameterSets.codecString(sps: EncoderSamples.avcHighSPS) == "avc1.640020")

        let baseline = try #require(AVCParameterSets.parseSPS(EncoderSamples.avcBaselineSPS))
        #expect(baseline.width == 1920 && baseline.height == 1080)
        #expect(AVCParameterSets.codecString(sps: EncoderSamples.avcBaselineSPS) == "avc1.42c028")

        let record = AVCParameterSets.decoderConfiguration(info: high, sps: [EncoderSamples.avcHighSPS], pps: [EncoderSamples.avcHighPPS])
        let expected: [UInt8] = [0x01, 0x64, 0x00, 0x20, 0xFF, 0xE1, 0x00, 28] + EncoderSamples.avcHighSPS
            + [0x01, 0x00, 6] + EncoderSamples.avcHighPPS + [0xFD, 0xF8, 0xF8, 0x00]
        #expect(record == expected)
    }

    @Test("ADTS headers give the AudioSpecificConfig, with HE-AAC's SBR signalled explicitly")
    func aacFormats() throws {
        let lc = try #require(AudioFrames.format(of: SyntheticTransportStream.adtsFrame()[...], codec: .aac))
        #expect(lc.sampleRate == 48_000 && lc.channelCount == 2 && lc.samplesPerFrame == 1_024)
        #expect(lc.configuration == [0x11, 0x90])
        #expect(lc.codecString == "mp4a.40.2")
        let cd = try #require(AudioFrames.format(of: SyntheticTransportStream.adtsFrame(rateIndex: 4)[...], codec: .aac))
        #expect(cd.sampleRate == 44_100 && cd.configuration == [0x12, 0x10])
        // AAC at 24 kHz on air is HE-AAC: 48 kHz out of the decoder, 2048 samples a frame, object type 5.
        let he = try #require(AudioFrames.format(of: SyntheticTransportStream.adtsFrame(rateIndex: 6)[...], codec: .aac))
        #expect(he.sampleRate == 48_000 && he.channelCount == 2 && he.samplesPerFrame == 2_048)
        #expect(he.configuration == [0x2B, 0x11, 0x88, 0x00])
        #expect(he.codecString == "mp4a.40.5")
    }

    @Test("AC-3 and E-AC-3 headers give the dac3 and dec3 records")
    func dolbyFormats() throws {
        // AC-3 at 48 kHz, 384 kb/s, bsid 8, 3/2 with LFE.
        let ac3: [UInt8] = [0x0B, 0x77, 0x00, 0x00, 0x1C, 0x40, 0xE1] + [UInt8](repeating: 0x11, count: 1_529)
        let dolby = try #require(AudioFrames.format(of: ac3[...], codec: .ac3))
        #expect(dolby.configuration == [0x10, 0x3D, 0xC0])
        #expect(dolby.sampleRate == 48_000 && dolby.channelCount == 6 && dolby.samplesPerFrame == 1_536)
        #expect(dolby.bitrate == 384 && dolby.codecString == "ac-3")
        #expect(AudioFrames.split(ac3 + ac3, codec: .ac3).frames.count == 2)

        // E-AC-3 5.1 at 640 kb/s, as a 4K channel sends it.
        let eac3: [UInt8] = [0x0B, 0x77, 0x04, 0xFF, 0x3F, 0x85] + [UInt8](repeating: 0x11, count: 2_554)
        let plus = try #require(AudioFrames.format(of: eac3[...], codec: .eac3))
        #expect(plus.configuration == [0x14, 0x00, 0x20, 0x0F, 0x00])
        #expect(plus.sampleRate == 48_000 && plus.channelCount == 6 && plus.bitrate == 640)
        #expect(plus.codecString == "ec-3")
        let generated = try #require(AudioFrames.format(of: SyntheticTransportStream.eac3Frame()[...], codec: .eac3))
        #expect(generated.configuration == [0x0C, 0x00, 0x20, 0x0F, 0x00])

        let short = SyntheticTransportStream.eac3Frame(blocks: 1)
        #expect(AudioFrames.split(short + short + short, codec: .eac3).frames.count == 3)
        #expect(AudioFrames.eac3Frame(short[...])?.blocks == 1)
        #expect(AudioFrames.eac3Frame(SyntheticTransportStream.eac3Frame(dependent: true)[...])?.independent == false)
    }

    @Test("Frames are split off an elementary stream, resynchronising after garbage and keeping an incomplete tail")
    func frameSplitting() {
        let frame = SyntheticTransportStream.adtsFrame()
        let split = AudioFrames.split(frame + [0x00, 0x13, 0x37] + frame + Array(frame.prefix(50)), codec: .aac)
        #expect(split.frames.map(\.range) == [0..<127, 130..<257])
        #expect(split.frames.map(\.payload) == [7..<127, 137..<257])
        #expect(split.consumed == 257)
    }
}

@Suite("Fragmented MP4 boxes")
struct FragmentedMP4BoxTests {
    @Test("A video initialization section is ftyp and moov, with an hvc1 entry holding hvcC, colour and aspect")
    func videoInitialization() throws {
        let info = try #require(HEVCParameterSets.parseSPS(EncoderSamples.pqSPS))
        let record = HEVCParameterSets.decoderConfiguration(info: info, vps: [EncoderSamples.pqVPS], sps: [EncoderSamples.pqSPS],
                                                             pps: [EncoderSamples.pps], sei: [])
        let format = VideoTrackFormat(codec: .hevc, configuration: record, codecString: HEVCParameterSets.codecString(info),
                                      width: info.width, height: info.height, colour: info.colour)
        let section = [UInt8](FragmentedMP4.initializationSection(for: .video(format)))
        let top = try #require(MP4Box.parse(section[...]))
        #expect(top.map(\.type) == ["ftyp", "moov"])
        #expect(Array(top[0].body) == Array("iso5".utf8) + [0, 0, 2, 0] + Array("iso5iso6mp41".utf8))
        let moov = top[1]
        #expect(moov.children().map(\.type) == ["mvhd", "trak", "mvex"])
        let trak = try #require(moov.child("trak"))
        #expect(trak.children().map(\.type) == ["tkhd", "mdia"])
        let tkhd = try #require(trak.child("tkhd"))
        #expect(readU32(tkhd.body, 12) == 1)
        #expect(readU32(tkhd.body, 76) == 3840 << 16 && readU32(tkhd.body, 80) == 2160 << 16)
        let mdia = try #require(trak.child("mdia"))
        #expect(mdia.children().map(\.type) == ["mdhd", "hdlr", "minf"])
        let mdhd = try #require(mdia.child("mdhd"))
        #expect(readU32(mdhd.body, 12) == 90_000)
        let hdlr = try #require(mdia.child("hdlr"))
        #expect(fourCC(hdlr.body, 8) == "vide")
        let minf = try #require(mdia.child("minf"))
        #expect(minf.children().map(\.type) == ["vmhd", "dinf", "stbl"])
        let stbl = try #require(minf.child("stbl"))
        #expect(stbl.children().map(\.type) == ["stsd", "stts", "stsc", "stsz", "stco"])
        let entry = try #require(sampleEntry(of: section[...]))
        #expect(entry.type == "hvc1")
        #expect(readU16(entry.body, 24) == 3840 && readU16(entry.body, 26) == 2160)
        let boxes = entry.children(skipping: 78)
        #expect(boxes.map(\.type) == ["hvcC", "colr", "pasp"])
        #expect(Array(boxes.first?.body ?? []) == record)
        #expect(Array(entry.child("colr", skipping: 78)?.body ?? []) == Array("nclx".utf8) + [0, 9, 0, 16, 0, 9, 0x00])
        let trex = try #require(moov.child("mvex")?.child("trex"))
        #expect(readU32(trex.body, 4) == 1)
    }

    @Test("Audio initialization sections carry the rate, the language and the AudioSpecificConfig, dac3 or dec3")
    func audioInitialization() throws {
        let aac = try #require(AudioFrames.format(of: SyntheticTransportStream.adtsFrame()[...], codec: .aac))
        let section = [UInt8](FragmentedMP4.initializationSection(for: .audio(aac, language: "eng")))
        let mdhd = try #require(MP4Box.parse(section[...])?.last?.child("trak")?.child("mdia")?.child("mdhd"))
        #expect(readU32(mdhd.body, 12) == 48_000)
        #expect(readU16(mdhd.body, 20) == 0x15C7)
        let entry = try #require(sampleEntry(of: section[...]))
        #expect(entry.type == "mp4a")
        #expect(readU16(entry.body, 16) == 2)
        #expect(readU32(entry.body, 24) == 48_000 << 16)
        // ES_Descriptor > DecoderConfigDescriptor (MPEG-4 audio, audio stream) > DecoderSpecificInfo.
        let esds = try #require(entry.child("esds", skipping: 28))
        let descriptor: [UInt8] = [0x03, 0x19, 0x00, 0x01, 0x00, 0x04, 0x11, 0x40, 0x15, 0x00, 0x06, 0x00, 0, 0, 0, 0, 0, 0, 0, 0,
                                   0x05, 0x02, 0x11, 0x90, 0x06, 0x01, 0x02]
        #expect(Array(esds.body) == [0, 0, 0, 0] + descriptor)

        let eac3 = try #require(AudioFrames.format(of: SyntheticTransportStream.eac3Frame()[...], codec: .eac3))
        let surround = try #require(sampleEntry(of: [UInt8](FragmentedMP4.initializationSection(for: .audio(eac3, language: "fra")))[...]))
        #expect(surround.type == "ec-3")
        #expect(readU16(surround.body, 16) == 6)
        #expect(Array(surround.child("dec3", skipping: 28)?.body ?? []) == [0x0C, 0x00, 0x20, 0x0F, 0x00])
        let unknown = [UInt8](FragmentedMP4.initializationSection(for: .audio(eac3, language: "und")))
        let unknownHeader = try #require(MP4Box.parse(unknown[...])?.last?.child("trak")?.child("mdia")?.child("mdhd"))
        #expect(readU16(unknownHeader.body, 20) == 0x55C4)
    }

    @Test("A fragment's data offset points at its first sample; negative composition offsets use trun version 1")
    func fragmentLayout() throws {
        let samples = [FragmentedMP4.Sample(size: 5, duration: 3_600, flags: FragmentedMP4.syncFlags, compositionOffset: 7_200),
                       FragmentedMP4.Sample(size: 3, duration: 3_600, flags: FragmentedMP4.dependentFlags, compositionOffset: -3_600),
                       FragmentedMP4.Sample(size: 4, duration: 3_000, flags: FragmentedMP4.undecodableLeadingFlags, compositionOffset: 0)]
        let data = FragmentedMP4.fragment(sequence: 42, baseDecodeTime: 8_589_934_609, samples: samples,
                                          payload: Data((1...12).map { UInt8($0) }), compositionOffsets: true)
        let fragment = try #require(ParsedFragment(data))
        #expect(fragment.sequence == 42)
        #expect(fragment.baseDecodeTime == 8_589_934_609)
        #expect(fragment.trunVersion == 1)
        #expect(fragment.samples == samples)
        #expect(fragment.sampleData.map { Array($0) } == [[1, 2, 3, 4, 5], [6, 7, 8], [9, 10, 11, 12]])
        #expect(fragment.duration == 10_200)

        let audio = try #require(ParsedFragment(FragmentedMP4.fragment(sequence: 1, baseDecodeTime: 0, samples: [samples[0]],
                                                                       payload: Data((1...5).map { UInt8($0) }),
                                                                       compositionOffsets: false)))
        #expect(audio.trunVersion == 0)
        #expect(audio.samples.first?.compositionOffset == 0)
        let empty = try #require(ParsedFragment(FragmentedMP4.fragment(sequence: 2, baseDecodeTime: 960, samples: [],
                                                                       payload: Data(), compositionOffsets: false)))
        #expect(empty.samples.isEmpty && empty.baseDecodeTime == 960)
    }
}

@Suite("fMP4 packaging")
struct FragmentedPackagerTests {
    private func hevcStream() -> SyntheticTransportStream {
        var stream = SyntheticTransportStream()
        stream.videoStreamType = 0x24
        stream.parameterSets = EncoderSamples.pq
        return stream
    }

    /// The stream cut into segments the way a session's segmenter cuts it.
    private func segments(_ stream: inout SyntheticTransportStream, seconds: Double) -> [MediaSegment] {
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: seconds))
        harness.finish()
        return harness.segments
    }

    @Test("HEVC segments become one initialization section and fragments whose decode times run on unbroken")
    func hevcSegments() throws {
        var stream = hevcStream()
        stream.audioLanguage = "eng"
        let source = segments(&stream, seconds: 10)
        let packager = FragmentedPackager()
        let packaged = source.compactMap { packager.package($0) }
        #expect(source.count >= 4)
        #expect(packaged.count == source.count)
        #expect(packaged.allSatisfy { $0.initialization == 1 && !$0.isDiscontinuity })
        let format = try #require(packager.videoFormat)
        #expect(format.codecString == "hvc1.2.4.L153.90")
        #expect(format.width == 3840 && format.height == 2160 && format.videoRange == "PQ")
        #expect(packager.frameRate == 25)
        #expect(packager.audioRenditions.map(\.language) == ["eng"])
        #expect(packager.audioRenditions.map(\.format.codecString) == ["mp4a.40.2"])

        // The initialization section holds the stream's parameter sets and its HDR10 metadata.
        let initialization = try #require(packager.videoInitialization(1))
        let record = try #require(sampleEntry(of: [UInt8](initialization)[...])?.child("hvcC", skipping: 78))
        let units = configurationUnits(Array(record.body))
        #expect(units == [EncoderSamples.pqVPS, EncoderSamples.pqSPS, EncoderSamples.pps, EncoderSamples.combinedHDR10])

        // Video: every picture once and in order, keyframes as sync samples starting each fragment.
        let fragments = try packaged.map { try #require(ParsedFragment($0.data)) }
        expectContinuous(fragments)
        let samples = fragments.flatMap { zip($0.samples, $0.sampleData).map { $0 } }
        let frames = samples.compactMap { SyntheticTransportStream.picture(inSample: $0.1)?.frame }
        #expect(frames == Array(0..<frames.count))
        #expect(frames.count >= 245)
        #expect(samples.allSatisfy { $0.0.duration == 3_600 && $0.0.compositionOffset == 3_600 })
        #expect(fragments.allSatisfy { $0.samples.first?.flags == FragmentedMP4.syncFlags })
        let syncFrames = samples.filter { $0.0.flags == FragmentedMP4.syncFlags }.compactMap {
            SyntheticTransportStream.picture(inSample: $0.1)?.frame
        }
        #expect(syncFrames == [0, 50, 100, 150, 200])
        // Parameter sets the initialization section holds and access unit delimiters are left out; SEI stays.
        let types = Set(samples.flatMap { lengthPrefixedUnits($0.1).map { HEVCParameterSets.nalType($0.first ?? 0) } })
        #expect(types.isDisjoint(with: [32, 33, 34, 35]))
        #expect(types.isSuperset(of: [1, 19, 39]))

        // Audio: one rendition, decode times unbroken, starting with the pictures.
        let audio = try packaged.map { try #require($0.audio.first.flatMap { ParsedFragment($0.data) }) }
        expectContinuous(audio)
        #expect(packaged.allSatisfy { $0.audio.map(\.rendition) == [0] && $0.audio.first?.initialization == 1 })
        #expect(audio.allSatisfy { $0.samples.allSatisfy { $0.duration == 1_024 && $0.size == 120 } })
        let pictureStart = Double(fragments[0].baseDecodeTime) / 90_000 + Double(fragments[0].samples[0].compositionOffset) / 90_000
        let audioStart = Double(audio[0].baseDecodeTime) / 48_000
        #expect(abs(audioStart - pictureStart) < 0.1)
        let audioEnd = Double(audio[audio.count - 1].baseDecodeTime + audio[audio.count - 1].duration) / 48_000
        let videoEnd = Double(fragments[fragments.count - 1].baseDecodeTime + fragments[fragments.count - 1].duration) / 90_000
        #expect(abs(audioEnd - videoEnd) < 0.1)
    }

    @Test("A new picture format starts a new initialization section behind a discontinuity")
    func formatChange() throws {
        var stream = hevcStream()
        stream.parameterSets = [EncoderSamples.sdrVPS, EncoderSamples.sdrSPS, EncoderSamples.pps]
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 4))
        stream.parameterSets = EncoderSamples.pq
        harness.feed(stream.bytes(seconds: 4, firstFrame: 100))
        harness.finish()
        let packager = FragmentedPackager()
        let packaged = harness.segments.compactMap { packager.package($0) }
        #expect(packaged.count == harness.segments.count)
        let change = try #require(packaged.firstIndex { $0.initialization == 2 })
        #expect(change > 0)
        #expect(packaged[change].isDiscontinuity)
        #expect(packaged[..<change].allSatisfy { $0.initialization == 1 && !$0.isDiscontinuity })
        #expect(packaged[change...].allSatisfy { $0.initialization == 2 })
        let first = try #require(packager.videoInitialization(1))
        #expect(sampleEntry(of: [UInt8](first)[...]).map { readU16($0.body, 24) } == 1920)
        #expect(packager.videoFormat?.codecString == "hvc1.2.4.L153.90")
        // The timeline is continuous: only the decoder is told to start over.
        expectContinuous(try packaged.map { try #require(ParsedFragment($0.data)) })
    }

    @Test("A splice that resumes a few frames late keeps decode times continuous; a discontinuity keeps its jump")
    func decodeTimeJumps() throws {
        var stream = hevcStream()
        stream.gop = 25
        let packager = FragmentedPackager()
        let first = try #require(packager.package(segment(&stream, sequence: 0, frames: 0..<48)))
        // The splicer resumed two frames late: a gap in decode order.
        let late = try #require(packager.package(segment(&stream, sequence: 1, frames: 50..<100)))
        let next = try #require(packager.package(segment(&stream, sequence: 2, frames: 100..<150)))
        let (a, b, c) = (try #require(ParsedFragment(first.data)), try #require(ParsedFragment(late.data)),
                         try #require(ParsedFragment(next.data)))
        #expect(b.baseDecodeTime == a.baseDecodeTime + a.duration)
        // Its first picture is decoded two frames early and presented when it was due.
        #expect(b.samples.first?.duration == 10_800)
        #expect(b.samples.first?.compositionOffset == 10_800)
        #expect(Int64(b.baseDecodeTime) + Int64(b.samples.first?.compositionOffset ?? 0) == stream.pts(frame: 50))
        #expect(c.baseDecodeTime == b.baseDecodeTime + b.duration)

        // Behind a discontinuity the decoder starts over, so the decode times keep the jump.
        let reset = try #require(packager.package(segment(&stream, sequence: 3, frames: 175..<200, isDiscontinuity: true)))
        let d = try #require(ParsedFragment(reset.data))
        #expect(Int64(d.baseDecodeTime) == stream.pts(frame: 175) - stream.frameTicks)
        #expect(d.samples.first?.duration == 3_600)
    }

    @Test("A hole at the start of a segment's audio is taken into its first frame; behind a discontinuity it stays")
    func audioHoleAtFragmentStart() throws {
        var stream = hevcStream()
        let packager = FragmentedPackager()
        let first = try #require(packager.package(segment(&stream, sequence: 0, frames: 0..<50)))
        // The next segment's first five audio frames never arrived.
        let holed = try #require(packager.package(droppingAudio(segment(&stream, sequence: 1, frames: 50..<100), first: 5, of: stream)))
        let a = try #require(first.audio.first.flatMap { ParsedFragment($0.data) })
        let b = try #require(holed.audio.first.flatMap { ParsedFragment($0.data) })
        #expect(b.baseDecodeTime == a.baseDecodeTime + a.duration)
        #expect(b.samples.first?.duration == 6_144)
        #expect(b.samples.dropFirst().allSatisfy { $0.duration == 1_024 })

        // Behind a discontinuity the decoder starts over, and the audio keeps its own time.
        let reset = try #require(packager.package(droppingAudio(segment(&stream, sequence: 2, frames: 100..<150, isDiscontinuity: true),
                                                                first: 5, of: stream)))
        let c = try #require(reset.audio.first.flatMap { ParsedFragment($0.data) })
        #expect(c.baseDecodeTime == b.baseDecodeTime + b.duration + 5_120)
        #expect(c.samples.first?.duration == 1_024)
    }

    /// `segment` without its first `count` audio PES.
    private func droppingAudio(_ segment: MediaSegment, first count: Int, of stream: SyntheticTransportStream) -> MediaSegment {
        var dropped = 0
        let packets = transportPackets([UInt8](segment.data)).filter { packet in
            guard packet.pid == stream.audioPID, dropped < count else { return true }
            if packet.payloadUnitStart { dropped += 1 }
            return false
        }
        return MediaSegment(sequence: segment.sequence, data: Data(packets.flatMap(\.bytes)), duration: segment.duration,
                            programmeStart: segment.programmeStart, startsWithKeyframe: segment.startsWithKeyframe,
                            isDiscontinuity: segment.isDiscontinuity, startTime: segment.startTime, endTime: segment.endTime)
    }

    @Test("Audio the next segment repeats is dropped where the previous fragment already carried it")
    func repeatedAudio() throws {
        var stream = hevcStream()
        // An encoder joined afresh at frame 50 starts its audio a frame early.
        var rejoined = stream
        let packager = FragmentedPackager()
        let first = try #require(packager.package(segment(&stream, sequence: 0, frames: 0..<50)))
        let source = segment(&rejoined, sequence: 1, frames: 50..<100)
        let second = try #require(packager.package(source))
        let a = try #require(first.audio.first.flatMap { ParsedFragment($0.data) })
        let b = try #require(second.audio.first.flatMap { ParsedFragment($0.data) })
        #expect(b.baseDecodeTime == a.baseDecodeTime + a.duration)
        // Two of its frames overlapped what was delivered; the third began within half a frame of
        // the end and carries on from it.
        #expect(b.samples.count == pesUnits(in: [UInt8](source.data), pid: stream.audioPID).count - 2)
    }

    @Test("HLG sent as BT.2020 SDR with an alternative transfer SEI is published as HLG")
    func backwardCompatibleHLG() throws {
        for preferring in [true, false] {
            var stream = hevcStream()
            stream.parameterSets = [EncoderSamples.bt2020VPS, EncoderSamples.bt2020SPS, EncoderSamples.bt2020PPS]
                + (preferring ? [EncoderSamples.preferHLG] : [])
            let packager = FragmentedPackager()
            #expect(!segments(&stream, seconds: 3).compactMap { packager.package($0) }.isEmpty)
            let transfer: UInt8 = preferring ? 18 : 14
            #expect(packager.videoFormat?.colour == ColourDescription(primaries: 9, transfer: transfer, matrix: 9, fullRange: false))
            #expect(packager.videoFormat?.videoRange == (preferring ? "HLG" : "SDR"))
            let entry = try #require(packager.videoInitialization(1).flatMap { sampleEntry(of: [UInt8]($0)[...]) })
            #expect(Array(entry.child("colr", skipping: 78)?.body ?? []) == Array("nclx".utf8) + [0, 9, 0, transfer, 0, 9, 0x00])
        }
    }

    @Test("Each audio track becomes its own rendition, with its language and format")
    func audioRenditions() throws {
        var stream = hevcStream()
        stream.audioLanguage = "eng"
        stream.surroundTracks = [(pid: 0x102, language: "fra")]
        let source = segments(&stream, seconds: 6)
        let packager = FragmentedPackager()
        let packaged = source.compactMap { packager.package($0) }
        #expect(packaged.count == source.count)
        #expect(packager.audioRenditions.map(\.index) == [0, 1])
        #expect(packager.audioRenditions.map(\.language) == ["eng", "fra"])
        #expect(packager.audioRenditions.map(\.format.codecString) == ["mp4a.40.2", "ec-3"])
        #expect(packager.audioRenditions.map(\.format.channelCount) == [2, 6])
        #expect(packaged.allSatisfy { $0.audio.map(\.rendition) == [0, 1] })
        let surround = try packaged.map { try #require(ParsedFragment($0.audio[1].data)) }
        expectContinuous(surround)
        #expect(surround.allSatisfy { $0.samples.allSatisfy { $0.duration == 1_536 && $0.size == 1_536 } })
        let initialization = try #require(packager.audioInitialization(rendition: 1, number: 1))
        let entry = try #require(sampleEntry(of: [UInt8](initialization)[...]))
        #expect(entry.type == "ec-3")
        let mdhd = try #require(MP4Box.parse([UInt8](initialization)[...])?.last?.child("trak")?.child("mdia")?.child("mdhd"))
        #expect(readU16(mdhd.body, 20) == 0x1A41)
    }

    @Test("E-AC-3 syncframes of fewer blocks and dependent substreams join their 1536-sample access unit")
    func eac3AccessUnits() throws {
        for (blocks, dependent) in [(1, false), (3, false), (6, true)] {
            var stream = hevcStream()
            stream.includeAudio = false
            stream.surroundTracks = [(pid: 0x102, language: "eng")]
            stream.surroundBlocks = blocks
            stream.surroundDependent = dependent
            let packager = FragmentedPackager()
            let packaged = segments(&stream, seconds: 4).compactMap { packager.package($0) }
            let fragments = try packaged.map { try #require($0.audio.first.flatMap { ParsedFragment($0.data) }) }
            let samples = fragments.flatMap(\.samples)
            #expect(samples.count > 100, "\(blocks) blocks")
            #expect(samples.allSatisfy { $0.duration == 1_536 && $0.size == 1_536 * (dependent ? 2 : 1) }, "\(blocks) blocks")
            expectContinuous(fragments)
        }
    }

    @Test("H.264 is packaged with an avc1 entry, and its parameter sets and delimiters leave the samples")
    func h264Segments() throws {
        var stream = SyntheticTransportStream()
        stream.parameterSets = [EncoderSamples.avcHighSPS, EncoderSamples.avcHighPPS]
        let packager = FragmentedPackager()
        let packaged = segments(&stream, seconds: 6).compactMap { packager.package($0) }
        #expect(packaged.count >= 2)
        #expect(packager.videoFormat?.codecString == "avc1.640020")
        #expect(packager.videoFormat?.videoRange == "SDR")
        let entry = try #require(packager.videoInitialization(1).flatMap { sampleEntry(of: [UInt8]($0)[...]) })
        #expect(entry.type == "avc1")
        #expect(entry.children(skipping: 78).map(\.type) == ["avcC", "colr", "pasp"])
        let fragments = try packaged.map { try #require(ParsedFragment($0.data)) }
        expectContinuous(fragments)
        let types = Set(fragments.flatMap { $0.sampleData.flatMap { lengthPrefixedUnits($0).map { AVCParameterSets.nalType($0.first ?? 0) } } })
        #expect(types == [1, 5])
    }

    @Test("Native output: every picture once as a sample, parameter sets in the format, AAC frames with their ES descriptor")
    func nativeSamples() throws {
        var stream = SyntheticTransportStream()
        stream.parameterSets = [EncoderSamples.avcHighSPS, EncoderSamples.avcHighPPS]
        stream.audioLanguage = "eng"
        let source = segments(&stream, seconds: 6)
        let packager = FragmentedPackager(writesFragments: false, collectsSamples: true)
        let packaged = source.compactMap { packager.package($0) }
        #expect(packaged.count == source.count && source.count >= 3)
        // No fMP4 is written for a native renderer.
        #expect(packaged.allSatisfy { $0.data.isEmpty && $0.audio.allSatisfy(\.data.isEmpty) })
        let natives = try packaged.map { try #require($0.native) }

        let video = natives.compactMap(\.video)
        #expect(video.count == natives.count)
        let format = try #require(video.first?.format)
        #expect(format.codec == .h264 && format.codecString == "avc1.640020")
        #expect(format.parameterSets == [EncoderSamples.avcHighSPS, EncoderSamples.avcHighPPS])
        #expect(video.allSatisfy { $0.formatNumber == 1 })
        let samples = video.flatMap(\.samples)
        // Every picture once and in order, decode times one picture apart across segments.
        let frames = samples.compactMap { SyntheticTransportStream.picture(inSample: [UInt8]($0.data)[...])?.frame }
        #expect(frames == Array(0..<frames.count) && frames.count >= 145)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $1.decodeTime == $0.decodeTime + $0.duration })
        #expect(samples.allSatisfy { $0.duration == 3_600 && $0.compositionOffset == 3_600 })
        // Each segment starts with a sync sample, and only keyframes are.
        #expect(video.allSatisfy { $0.samples.first?.isSync == true })
        let syncFrames = samples.filter(\.isSync).compactMap { SyntheticTransportStream.picture(inSample: [UInt8]($0.data)[...])?.frame }
        #expect(syncFrames == Array(stride(from: 0, to: frames.count, by: 50)))
        // Parameter sets and delimiters are in the format, not the samples.
        let types = Set(samples.flatMap { lengthPrefixedUnits([UInt8]($0.data)[...]).map { AVCParameterSets.nalType($0.first ?? 0) } })
        #expect(types == [1, 5])
        // Each segment's start, on the samples' clock, is its first picture's decode time.
        for native in natives {
            let first = try #require(native.video?.samples.first)
            #expect(abs(native.timelineStart - Double(first.decodeTime) / 90_000) < 0.001)
        }

        // Audio: one track whose frames run on unbroken, starting with the pictures, and the ES
        // descriptor (tag 3, holding the AudioSpecificConfig) for the decoder.
        let audio = natives.compactMap { $0.audio.first }
        #expect(audio.count == natives.count)
        let track = try #require(audio.first)
        #expect(track.format.codec == .aac && track.language == "eng" && track.rendition == 0)
        let cookie = try #require(track.magicCookie)
        #expect(cookie.first == 0x03)
        #expect(cookie.suffix(track.format.configuration.count + 3).prefix(track.format.configuration.count) == track.format.configuration[...])
        let audioSamples = audio.flatMap(\.samples)
        #expect(zip(audioSamples, audioSamples.dropFirst()).allSatisfy { $1.decodeTime == $0.decodeTime + $0.duration })
        #expect(audioSamples.allSatisfy { $0.duration == 1_024 && $0.isSync })
        let pictureStart = Double(samples[0].presentationTime) / 90_000
        let audioStart = Double(audioSamples[0].decodeTime) / Double(track.format.sampleRate)
        #expect(abs(audioStart - pictureStart) < 0.1)
    }

    @Test("Native output: new parameter sets start a new format even when the picture format stays the same")
    func nativeParameterSetChange() throws {
        var stream = SyntheticTransportStream()
        stream.parameterSets = [EncoderSamples.avcHighSPS, EncoderSamples.avcHighPPS]
        let packager = FragmentedPackager(writesFragments: false, collectsSamples: true)
        let first = try #require(packager.package(segment(&stream, sequence: 0, frames: 0..<50)))
        // The same SPS with another PPS: same codec, size and colour, but the decoder needs the new set.
        var otherPPS = EncoderSamples.avcHighPPS
        otherPPS[otherPPS.count - 1] ^= 0x02
        stream.parameterSets = [EncoderSamples.avcHighSPS, otherPPS]
        let second = try #require(packager.package(segment(&stream, sequence: 1, frames: 50..<100)))
        #expect(first.native?.video?.formatNumber == 1)
        #expect(second.native?.video?.formatNumber == 2)
        #expect(second.native?.video?.format.parameterSets == [EncoderSamples.avcHighSPS, otherPPS])
        // An fMP4 packager keeps those in the samples instead, under the same initialization section.
        let fmp4 = FragmentedPackager()
        stream.parameterSets = [EncoderSamples.avcHighSPS, EncoderSamples.avcHighPPS]
        _ = fmp4.package(segment(&stream, sequence: 0, frames: 0..<50))
        stream.parameterSets = [EncoderSamples.avcHighSPS, otherPPS]
        #expect(fmp4.package(segment(&stream, sequence: 1, frames: 50..<100))?.initialization == 1)
    }

    /// Frames `frames` as one segment whose last picture lasts until the next frame's decode time.
    private func segment(_ stream: inout SyntheticTransportStream, sequence: Int, frames: Range<Int>,
                         isDiscontinuity: Bool = false) -> MediaSegment {
        let seconds = Double(frames.count) * Double(stream.frameTicks) / 90_000
        let bytes = stream.bytes(seconds: seconds, firstFrame: frames.lowerBound)
        return MediaSegment(sequence: sequence, data: Data(bytes), duration: seconds,
                            programmeStart: Double(frames.lowerBound) * Double(stream.frameTicks) / 90_000,
                            startsWithKeyframe: true, isDiscontinuity: isDiscontinuity,
                            startTime: MPEGTS.wrap(stream.pts(frame: frames.lowerBound) - stream.frameTicks),
                            endTime: MPEGTS.wrap(stream.pts(frame: frames.upperBound) - stream.frameTicks))
    }
}

/// Each fragment's decode time continues exactly where the previous one ended.
func expectContinuous(_ fragments: [ParsedFragment], sourceLocation: SourceLocation = #_sourceLocation) {
    for (index, pair) in zip(fragments, fragments.dropFirst()).enumerated() where pair.1.baseDecodeTime != pair.0.baseDecodeTime + pair.0.duration {
        Issue.record("fragment \(index + 1) starts at \(pair.1.baseDecodeTime), not \(pair.0.baseDecodeTime + pair.0.duration)",
                     sourceLocation: sourceLocation)
        return
    }
}

// MARK: - Reading ISO-BMFF

/// One box: its type and its content after the header.
struct MP4Box {
    let type: String
    let body: ArraySlice<UInt8>

    /// The boxes that fill `bytes` exactly, or nil if they don't.
    static func parse(_ bytes: ArraySlice<UInt8>) -> [MP4Box]? {
        var boxes: [MP4Box] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard bytes.endIndex - index >= 8 else { return nil }
            let size = Int(readU32(bytes, index - bytes.startIndex))
            guard size >= 8, index + size <= bytes.endIndex else { return nil }
            boxes.append(MP4Box(type: fourCC(bytes, index - bytes.startIndex + 4), body: bytes[(index + 8)..<(index + size)]))
            index += size
        }
        return boxes
    }

    /// The boxes inside, after `skipping` bytes of the box's own fields.
    func children(skipping skip: Int = 0) -> [MP4Box] { MP4Box.parse(body.dropFirst(skip)) ?? [] }

    func child(_ type: String, skipping skip: Int = 0) -> MP4Box? { children(skipping: skip).first { $0.type == type } }
}

/// The sample entry of an initialization section's only track.
func sampleEntry(of section: ArraySlice<UInt8>) -> MP4Box? {
    guard let stsd = MP4Box.parse(section)?.first(where: { $0.type == "moov" })?.child("trak")?.child("mdia")?
        .child("minf")?.child("stbl")?.child("stsd") else { return nil }
    return MP4Box.parse(stsd.body.dropFirst(8))?.first
}

/// The NAL units of an hvcC record's arrays, in order.
func configurationUnits(_ record: [UInt8]) -> [[UInt8]] {
    guard record.count >= 23 else { return [] }
    var units: [[UInt8]] = []
    var index = 23
    for _ in 0..<Int(record[22]) {
        guard index + 3 <= record.count else { break }
        let count = Int(record[index + 1]) << 8 | Int(record[index + 2])
        index += 3
        for _ in 0..<count {
            guard index + 2 <= record.count else { break }
            let length = Int(record[index]) << 8 | Int(record[index + 1])
            units.append(Array(record[(index + 2)..<min(record.count, index + 2 + length)]))
            index += 2 + length
        }
    }
    return units
}

/// The NAL units of an MP4 sample, each preceded by its 4-byte length.
func lengthPrefixedUnits(_ sample: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
    var units: [ArraySlice<UInt8>] = []
    var index = sample.startIndex
    while index + 4 <= sample.endIndex {
        let length = Int(readU32(sample, index - sample.startIndex))
        let end = min(sample.endIndex, index + 4 + length)
        units.append(sample[(index + 4)..<end])
        index = end
    }
    return units
}

/// A movie fragment read back: moof (mfhd, traf with tfhd, tfdt, trun) then mdat, the samples'
/// data where trun's data offset says. Nil when the layout isn't the one the packager promises.
struct ParsedFragment {
    let sequence: UInt32
    let baseDecodeTime: UInt64
    let trunVersion: UInt8
    let samples: [FragmentedMP4.Sample]
    let sampleData: [ArraySlice<UInt8>]

    var duration: UInt64 { samples.reduce(0) { $0 + UInt64($1.duration) } }

    init?(_ data: Data) {
        let bytes = [UInt8](data)[...]
        guard let top = MP4Box.parse(bytes), top.map(\.type) == ["moof", "mdat"],
              let mfhd = top[0].child("mfhd"), let traf = top[0].child("traf"),
              traf.children().map(\.type) == ["tfhd", "tfdt", "trun"],
              let tfhd = traf.child("tfhd"), let tfdt = traf.child("tfdt"), let trun = traf.child("trun") else { return nil }
        // Default base is the moof; one track, ID 1.
        guard readU32(tfhd.body, 0) & 0xFF_FFFF == 0x02_0000, readU32(tfhd.body, 4) == 1 else { return nil }
        sequence = readU32(mfhd.body, 4)
        baseDecodeTime = tfdt.body.first == 1 ? readU64(tfdt.body, 4) : UInt64(readU32(tfdt.body, 4))
        trunVersion = trun.body.first ?? 0
        let flags = readU32(trun.body, 0) & 0xFF_FFFF
        let count = Int(readU32(trun.body, 4))
        guard flags & 0x0701 == 0x0701, flags & 0x0004 == 0 else { return nil }
        let dataOffset = Int(Int32(bitPattern: readU32(trun.body, 8)))
        let moofSize = top[0].body.count + 8
        guard dataOffset == moofSize + 8 else { return nil }
        let fieldSize = flags & 0x0800 != 0 ? 16 : 12
        guard trun.body.count == 12 + count * fieldSize else { return nil }
        var samples: [FragmentedMP4.Sample] = []
        var sampleData: [ArraySlice<UInt8>] = []
        var position = bytes.startIndex + dataOffset
        for index in 0..<count {
            let offset = 12 + index * fieldSize
            let size = Int(readU32(trun.body, offset + 4))
            let composition = fieldSize == 16 ? Int32(bitPattern: readU32(trun.body, offset + 12)) : 0
            samples.append(FragmentedMP4.Sample(size: size, duration: readU32(trun.body, offset), flags: readU32(trun.body, offset + 8),
                                                compositionOffset: composition))
            guard position + size <= bytes.endIndex else { return nil }
            sampleData.append(bytes[position..<(position + size)])
            position += size
        }
        // The mdat holds exactly the samples.
        guard top[1].body.count == samples.reduce(0, { $0 + $1.size }) else { return nil }
        self.samples = samples
        self.sampleData = sampleData
    }
}

func readU16(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt16 {
    let index = bytes.startIndex + offset
    guard index + 2 <= bytes.endIndex else { return 0 }
    return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
}

func readU32(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt32 {
    let index = bytes.startIndex + offset
    guard index + 4 <= bytes.endIndex else { return 0 }
    return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
}

func readU64(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> UInt64 {
    UInt64(readU32(bytes, offset)) << 32 | UInt64(readU32(bytes, offset + 4))
}

func fourCC(_ bytes: ArraySlice<UInt8>, _ offset: Int) -> String {
    let index = bytes.startIndex + offset
    guard index + 4 <= bytes.endIndex else { return "" }
    return String(decoding: bytes[index..<(index + 4)], as: UTF8.self)
}

extension SyntheticTransportStream {
    /// The frame number and encoder identity in a fragmented-MP4 sample's slice.
    static func picture(inSample sample: ArraySlice<UInt8>) -> Picture? {
        for unit in lengthPrefixedUnits(sample) where unit.count >= 7 {
            let first = unit.first ?? 0
            let h264Slice = first == 0x65 || first == 0x41
            let hevcSlice = [0x26, 0x2A, 0x02].contains(first) && unit[unit.startIndex + 1] == 0x01
            guard h264Slice || hevcSlice else { continue }
            let digits = unit[(unit.startIndex + 2)..<(unit.startIndex + 7)].map { Int($0 & 0x7F) }
            return Picture(frame: digits[0] << 21 | digits[1] << 14 | digits[2] << 7 | digits[3], content: digits[4])
        }
        return nil
    }
}
