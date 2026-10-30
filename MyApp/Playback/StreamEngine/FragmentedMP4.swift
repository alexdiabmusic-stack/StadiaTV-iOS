import Foundation

/// Fragmented MP4 for HLS: an initialization section (ftyp + moov) per track, and one movie
/// fragment (moof + mdat) per track per media segment. Every rendition carries a single track.
nonisolated enum FragmentedMP4 {
    struct Sample: Equatable {
        var size: Int
        var duration: UInt32
        var flags: UInt32
        var compositionOffset: Int32 = 0
    }

    /// sample_depends_on = 2: decodable on its own.
    static let syncFlags: UInt32 = 0x0200_0000
    /// sample_depends_on = 1, sample_is_non_sync_sample = 1.
    static let dependentFlags: UInt32 = 0x0101_0000
    /// is_leading = 1: a RASL picture, which can't be decoded when playback starts at its CRA.
    static let undecodableLeadingFlags: UInt32 = 0x0501_0000
    /// is_leading = 3: a RADL picture, decodable from the keyframe before it.
    static let decodableLeadingFlags: UInt32 = 0x0D01_0000

    enum Track: Equatable, Sendable {
        case video(VideoTrackFormat)
        /// `language` is ISO 639-2 (three letters) or "und".
        case audio(AudioTrackFormat, language: String)

        var timescale: UInt32 {
            switch self {
            case .video: return UInt32(MPEGTS.clockRate)
            case .audio(let format, _): return UInt32(format.sampleRate)
            }
        }
    }

    static let trackID: UInt32 = 1

    // MARK: - Initialization section

    static func initializationSection(for track: Track) -> Data {
        var ftyp = ByteWriter()
        ftyp.fourCC("iso5")
        ftyp.u32(512)
        for brand in ["iso5", "iso6", "mp41"] { ftyp.fourCC(brand) }
        var trex = ByteWriter()
        trex.u32(trackID)
        trex.u32(1)
        trex.u32(0)
        trex.u32(0)
        trex.u32(0)
        let moov = box("moov", movieHeader() + trackBox(track) + box("mvex", fullBox("trex", version: 0, flags: 0, trex.bytes)))
        return Data(box("ftyp", ftyp.bytes) + moov)
    }

    private static func movieHeader() -> [UInt8] {
        var mvhd = ByteWriter()
        mvhd.u32(0)
        mvhd.u32(0)
        mvhd.u32(1000)
        mvhd.u32(0)
        mvhd.u32(0x0001_0000)
        mvhd.u16(0x0100)
        mvhd.zeros(10)
        mvhd.matrix()
        mvhd.zeros(24)
        mvhd.u32(trackID + 1)
        return fullBox("mvhd", version: 0, flags: 0, mvhd.bytes)
    }

    private static func trackBox(_ track: Track) -> [UInt8] {
        var width = 0
        var height = 0
        var isAudio = false
        var language = "und"
        switch track {
        case .video(let format):
            width = format.width
            height = format.height
        case .audio(_, let code):
            isAudio = true
            language = code
        }
        var tkhd = ByteWriter()
        tkhd.u32(0)
        tkhd.u32(0)
        tkhd.u32(trackID)
        tkhd.u32(0)
        tkhd.u32(0)
        tkhd.zeros(8)
        tkhd.u16(0)
        tkhd.u16(0)
        tkhd.u16(isAudio ? 0x0100 : 0)
        tkhd.u16(0)
        tkhd.matrix()
        tkhd.u32(UInt32(width) << 16)
        tkhd.u32(UInt32(height) << 16)

        var mdhd = ByteWriter()
        mdhd.u32(0)
        mdhd.u32(0)
        mdhd.u32(track.timescale)
        mdhd.u32(0)
        mdhd.u16(packedLanguage(language))
        mdhd.u16(0)

        var hdlr = ByteWriter()
        hdlr.u32(0)
        hdlr.fourCC(isAudio ? "soun" : "vide")
        hdlr.zeros(12)
        hdlr.bytes += Array((isAudio ? "SoundHandler" : "VideoHandler").utf8) + [0]

        var vmhd = ByteWriter()
        vmhd.zeros(8)
        var smhd = ByteWriter()
        smhd.zeros(4)
        let mediaHeader = isAudio ? fullBox("smhd", version: 0, flags: 0, smhd.bytes) : fullBox("vmhd", version: 0, flags: 1, vmhd.bytes)

        var dref = ByteWriter()
        dref.u32(1)
        dref.bytes += fullBox("url ", version: 0, flags: 1, [])

        var stsd = ByteWriter()
        stsd.u32(1)
        stsd.bytes += sampleEntry(track)
        var emptyTable = ByteWriter()
        emptyTable.u32(0)
        var stsz = ByteWriter()
        stsz.u32(0)
        stsz.u32(0)
        let stbl = box("stbl", fullBox("stsd", version: 0, flags: 0, stsd.bytes)
                       + fullBox("stts", version: 0, flags: 0, emptyTable.bytes)
                       + fullBox("stsc", version: 0, flags: 0, emptyTable.bytes)
                       + fullBox("stsz", version: 0, flags: 0, stsz.bytes)
                       + fullBox("stco", version: 0, flags: 0, emptyTable.bytes))
        let minf = box("minf", mediaHeader + box("dinf", fullBox("dref", version: 0, flags: 0, dref.bytes)) + stbl)
        let mdia = box("mdia", fullBox("mdhd", version: 0, flags: 0, mdhd.bytes) + fullBox("hdlr", version: 0, flags: 0, hdlr.bytes) + minf)
        return box("trak", fullBox("tkhd", version: 0, flags: 3, tkhd.bytes) + mdia)
    }

    private static func sampleEntry(_ track: Track) -> [UInt8] {
        var entry = ByteWriter()
        entry.zeros(6)
        entry.u16(1)
        switch track {
        case .video(let format):
            entry.zeros(16)
            entry.u16(UInt16(clamping: format.width))
            entry.u16(UInt16(clamping: format.height))
            entry.u32(0x0048_0000)
            entry.u32(0x0048_0000)
            entry.u32(0)
            entry.u16(1)
            entry.zeros(32)
            entry.u16(0x0018)
            entry.u16(0xFFFF)
            entry.bytes += box(format.configurationBoxType, format.configuration)
            if let colour = format.colour {
                var colr = ByteWriter()
                colr.fourCC("nclx")
                colr.u16(UInt16(colour.primaries))
                colr.u16(UInt16(colour.transfer))
                colr.u16(UInt16(colour.matrix))
                colr.bytes.append(colour.fullRange ? 0x80 : 0)
                entry.bytes += box("colr", colr.bytes)
            }
            var pasp = ByteWriter()
            pasp.u32(1)
            pasp.u32(1)
            entry.bytes += box("pasp", pasp.bytes)
            return box(format.sampleEntryType, entry.bytes)
        case .audio(let format, _):
            entry.zeros(8)
            entry.u16(UInt16(clamping: format.channelCount))
            entry.u16(16)
            entry.u16(0)
            entry.u16(0)
            entry.u32(format.sampleRate <= 0xFFFF ? UInt32(format.sampleRate) << 16 : 0)
            switch format.codec {
            case .aac: entry.bytes += fullBox("esds", version: 0, flags: 0, elementaryStreamDescriptor(format))
            case .ac3: entry.bytes += box("dac3", format.configuration)
            case .eac3: entry.bytes += box("dec3", format.configuration)
            }
            return box(format.sampleEntryType, entry.bytes)
        }
    }

    /// ES_Descriptor with the AudioSpecificConfig (ISO/IEC 14496-1 and -14).
    static func elementaryStreamDescriptor(_ format: AudioTrackFormat) -> [UInt8] {
        var decoderConfig = ByteWriter()
        decoderConfig.bytes += [0x40, 0x15]
        let bufferSize = UInt32(768 * max(1, format.channelCount))
        decoderConfig.bytes += [UInt8(bufferSize >> 16), UInt8((bufferSize >> 8) & 0xFF), UInt8(bufferSize & 0xFF)]
        decoderConfig.u32(0)
        decoderConfig.u32(0)
        decoderConfig.bytes += descriptor(0x05, format.configuration)
        var es = ByteWriter()
        es.u16(UInt16(trackID))
        es.bytes.append(0)
        es.bytes += descriptor(0x04, decoderConfig.bytes) + descriptor(0x06, [0x02])
        return descriptor(0x03, es.bytes)
    }

    private static func descriptor(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag, UInt8(min(content.count, 0x7F))] + content
    }

    private static func packedLanguage(_ code: String) -> UInt16 {
        let letters = Array(code.utf8)
        guard letters.count == 3, letters.allSatisfy({ (0x61...0x7A).contains($0) }) else { return 0x55C4 }
        return letters.reduce(0) { $0 << 5 | UInt16($1 - 0x60) }
    }

    // MARK: - Fragments

    /// One movie fragment: moof (mfhd, traf with tfhd, tfdt and trun) then mdat. `payload` is the
    /// samples' bytes back to back, in the order of `samples`.
    static func fragment(sequence: UInt32, baseDecodeTime: UInt64, samples: [Sample], payload: Data,
                         compositionOffsets: Bool) -> Data {
        func movieFragment(dataOffset: Int32) -> [UInt8] {
            var mfhd = ByteWriter()
            mfhd.u32(sequence)
            var tfhd = ByteWriter()
            tfhd.u32(trackID)
            var tfdt = ByteWriter()
            tfdt.u64(baseDecodeTime)
            // Offsets are signed in version 1; a picture presented before it's decoded would need it.
            let signedOffsets = samples.contains { $0.compositionOffset < 0 }
            var trun = ByteWriter()
            trun.u32(UInt32(samples.count))
            trun.u32(UInt32(bitPattern: dataOffset))
            for sample in samples {
                trun.u32(sample.duration)
                trun.u32(UInt32(sample.size))
                trun.u32(sample.flags)
                if compositionOffsets { trun.u32(UInt32(bitPattern: sample.compositionOffset)) }
            }
            let traf = box("traf", fullBox("tfhd", version: 0, flags: 0x02_0000, tfhd.bytes)
                           + fullBox("tfdt", version: 1, flags: 0, tfdt.bytes)
                           + fullBox("trun", version: signedOffsets ? 1 : 0, flags: compositionOffsets ? 0x0F01 : 0x0701, trun.bytes))
            return box("moof", fullBox("mfhd", version: 0, flags: 0, mfhd.bytes) + traf)
        }
        let size = movieFragment(dataOffset: 0).count
        var data = Data(movieFragment(dataOffset: Int32(size + 8)))
        var mdat = ByteWriter()
        mdat.u32(UInt32(8 + payload.count))
        mdat.fourCC("mdat")
        data.append(contentsOf: mdat.bytes)
        data.append(payload)
        return data
    }

    // MARK: - Boxes

    static func box(_ type: String, _ content: [UInt8]) -> [UInt8] {
        var writer = ByteWriter()
        writer.u32(UInt32(8 + content.count))
        writer.fourCC(type)
        return writer.bytes + content
    }

    static func fullBox(_ type: String, version: UInt8, flags: UInt32, _ content: [UInt8]) -> [UInt8] {
        box(type, [version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)] + content)
    }
}

/// Big-endian integers for box payloads.
nonisolated struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u16(_ value: UInt16) { bytes += [UInt8(value >> 8), UInt8(value & 0xFF)] }
    mutating func u32(_ value: UInt32) {
        bytes += [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    mutating func u64(_ value: UInt64) {
        u32(UInt32(value >> 32))
        u32(UInt32(value & 0xFFFF_FFFF))
    }
    mutating func fourCC(_ code: String) { bytes += Array(code.utf8.prefix(4)) }
    mutating func zeros(_ count: Int) { bytes += [UInt8](repeating: 0, count: count) }
    /// The unity transformation matrix of mvhd and tkhd.
    mutating func matrix() {
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] { u32(value) }
    }
}
