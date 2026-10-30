import Foundation

/// Repackages the engine's MPEG-TS media segments as fragmented MP4.
///
/// AVPlayer plays HEVC only from fMP4, so HEVC sessions are published as a video rendition plus
/// one audio rendition per audio track: Apple requires multichannel audio as a separate stream,
/// and no media segment may carry two audio streams. Parameter sets go in the initialization
/// section ('hvc1'); when the picture format or an audio format changes, a new initialization
/// section starts behind a discontinuity. Decode times run on unbroken from segment to segment,
/// as the splicer keeps the output timeline continuous.
nonisolated final class FragmentedPackager {
    struct AudioRendition: Equatable, Sendable {
        /// Position among the program's audio streams the packager carries.
        let index: Int
        /// ISO 639-2 code from the PMT, or "und".
        let language: String
        var format: AudioTrackFormat
    }

    private struct AudioState {
        let index: Int
        let codec: TSProgram.AudioCodec
        let language: String
        var format: AudioTrackFormat?
        var initialization = 0
        var nextDecodeTime: Int64?
        var clock: Int64?
        /// An incomplete frame left at the end of the previous PES, and the time it starts at.
        var carry: [UInt8] = []
        var carryTime: Int64 = 0
    }

    /// Fragmented MP4 for AVPlayer; decodable samples for the app's own renderer (`MediaSegment.native`).
    private let writesFragments: Bool
    private let collectsSamples: Bool

    private(set) var videoFormat: VideoTrackFormat?
    /// The initialization section's parameter sets: identical copies in the samples are dropped.
    private var parameterSets: Set<[UInt8]> = []
    private var nativeVideoFormat: NativeVideoFormat?
    private var videoInitialization = 0
    private var videoClock: Int64?
    /// Where the previous video fragment's decode times ended.
    private var videoNextDecodeTime: Int64?
    private var videoInitializations: [Int: Data] = [:]
    private var audioStates: [AudioState] = []
    private var audioInitializations: [Int: [Int: Data]] = [:]
    private var fragmentSequence: UInt32 = 0
    private var frameDurations: [Int64] = []

    init(writesFragments: Bool = true, collectsSamples: Bool = false) {
        self.writesFragments = writesFragments
        self.collectsSamples = collectsSamples
    }

    /// Audio renditions whose format is known, in PMT order.
    var audioRenditions: [AudioRendition] {
        audioStates.compactMap { state in state.format.map { AudioRendition(index: state.index, language: state.language, format: $0) } }
    }

    /// Frames per second, from the pictures seen so far.
    var frameRate: Double? {
        guard !frameDurations.isEmpty else { return nil }
        let sorted = frameDurations.sorted()
        return Double(MPEGTS.clockRate) / Double(sorted[sorted.count / 2])
    }

    func videoInitialization(_ number: Int) -> Data? { videoInitializations[number] }
    func audioInitialization(rendition: Int, number: Int) -> Data? { audioInitializations[rendition]?[number] }

    /// The fMP4 version of `segment`, or nil when it can't be played yet (no parameter sets so far).
    func package(_ segment: MediaSegment) -> MediaSegment? {
        let demuxed = Self.demux(segment.data)
        guard let program = demuxed.program else { return nil }
        if audioStates.isEmpty {
            audioStates = program.audio.enumerated().compactMap { index, stream in
                guard case .audio(let audioCodec) = stream.kind, [.aac, .ac3, .eac3].contains(audioCodec) else { return nil }
                return AudioState(index: index, codec: audioCodec, language: Self.language(stream.descriptors) ?? "und")
            }
            if audioStates.count > 4 { audioStates.removeLast(audioStates.count - 4) }
        }
        guard let videoStream = program.video else {
            return collectsSamples ? packageAudioOnly(segment, demuxed: demuxed, program: program) : nil
        }
        guard case .video(let codec) = videoStream.kind, codec == .hevc || codec == .h264 else { return nil }
        var discontinuity = segment.isDiscontinuity

        // Pictures, in decode order.
        var pictures: [(dts: Int64, pts: Int64, es: [UInt8], nals: [Range<Int>])] = []
        for unit in demuxed.units[videoStream.pid] ?? [] {
            guard let header = unit.parseHeader(), let rawPTS = header.pts else { continue }
            var es: [UInt8] = []
            es.reserveCapacity(unit.byteCount)
            unit.forEachDataChunk(from: header.dataOffset) { chunk in
                es.append(contentsOf: chunk)
                return true
            }
            let dts = unwrap(header.dts ?? rawPTS, clock: &videoClock)
            pictures.append((dts, dts + MPEGTS.signedDelta(rawPTS, header.dts ?? rawPTS), es, AnnexB.nalUnits(es)))
        }
        guard let first = pictures.first else { return nil }

        // A new picture format, or the first one, starts an initialization section. Parameter sets
        // that change without changing the format stay in the samples, where the decoder finds them;
        // a native renderer's format description holds them instead, so for it any change is a new format.
        if let format = videoFormat(codec: codec, es: first.es, nals: first.nals),
           videoFormat.map({ !Self.sameFormat($0, format.format) }) ?? true
            || (collectsSamples && nativeVideoFormat?.parameterSets != format.ordered) {
            if videoFormat != nil { discontinuity = true }
            videoFormat = format.format
            parameterSets = format.parameterSets
            nativeVideoFormat = NativeVideoFormat(codec: format.format.codec, parameterSets: format.ordered,
                                                  width: format.format.width, height: format.format.height,
                                                  colour: format.format.colour, codecString: format.format.codecString)
            videoInitialization += 1
            videoInitializations[videoInitialization] = FragmentedMP4.initializationSection(for: .video(format.format))
            videoInitializations = videoInitializations.filter { $0.key > videoInitialization - 16 }
        }
        guard videoFormat != nil else { return nil }

        var samples: [FragmentedMP4.Sample] = []
        var payload = Data()
        payload.reserveCapacity(segment.data.count)
        let end = segment.endTime.map { first.dts + MPEGTS.signedDelta($0, MPEGTS.wrap(first.dts)) }
        for (index, picture) in pictures.enumerated() {
            let next = index + 1 < pictures.count ? pictures[index + 1].dts : end
            let duration = next.map { max(1, $0 - picture.dts) } ?? (frameDurations.last ?? 3_600)
            if index + 1 < pictures.count, frameDurations.count < 64 { frameDurations.append(duration) }
            let start = payload.count
            var flags = FragmentedMP4.dependentFlags
            var sawSlice = false
            for range in picture.nals {
                let type = codec == .hevc ? HEVCParameterSets.nalType(picture.es[range.lowerBound])
                                          : AVCParameterSets.nalType(picture.es[range.lowerBound])
                if Self.dropsFromSample(type, codec: codec) { continue }
                if Self.isParameterSet(type, codec: codec), parameterSets.contains(Array(picture.es[range])) { continue }
                if !sawSlice, let sliceFlags = Self.sampleFlags(type, codec: codec) {
                    flags = sliceFlags
                    sawSlice = true
                }
                var length = ByteWriter()
                length.u32(UInt32(range.count))
                payload.append(contentsOf: length.bytes)
                payload.append(contentsOf: picture.es[range])
            }
            samples.append(FragmentedMP4.Sample(size: payload.count - start, duration: UInt32(clamping: duration), flags: flags,
                                                compositionOffset: Int32(clamping: picture.pts - picture.dts)))
        }
        // A splice that skipped re-sent programme can start a few frames late in decode order, so
        // nothing presents out of order. Decode times must still run on unbroken (HLS authoring
        // rule 7.3): the first picture is decoded that much earlier, presented at the same time.
        var base = first.dts
        if let expected = videoNextDecodeTime, !discontinuity, base > expected, base - expected <= MPEGTS.clockRate / 2,
           !samples.isEmpty {
            let jump = base - expected
            samples[0].duration = UInt32(clamping: Int64(samples[0].duration) + jump)
            samples[0].compositionOffset = Int32(clamping: Int64(samples[0].compositionOffset) + jump)
            base = expected
        }
        videoNextDecodeTime = base + samples.reduce(0) { $0 + Int64($1.duration) }
        fragmentSequence += 1
        let video = writesFragments ? FragmentedMP4.fragment(sequence: fragmentSequence, baseDecodeTime: UInt64(max(0, base)),
                                                              samples: samples, payload: payload, compositionOffsets: true) : Data()
        let nativeVideo = collectsSamples ? nativeVideoFormat.map {
            NativeVideoTrack(formatNumber: videoInitialization, format: $0,
                             samples: Self.nativeSamples(samples, payload: payload, baseDecodeTime: base))
        } : nil

        // Audio renditions: the audio that arrived with these pictures.
        var fragments: [AudioFragment] = []
        var nativeAudio: [NativeAudioTrack] = []
        for slot in audioStates.indices {
            let stream = program.audio.indices.contains(audioStates[slot].index) ? program.audio[audioStates[slot].index] : nil
            let units = stream.map { demuxed.units[$0.pid] ?? [] } ?? []
            let built = audioFragment(slot: slot, units: units, segment: segment, videoStart: first.dts, continues: !discontinuity)
            if built.formatChanged { discontinuity = true }
            if let fragment = built.fragment { fragments.append(fragment) }
            if let track = built.native { nativeAudio.append(track) }
        }

        var packaged = MediaSegment(sequence: segment.sequence, data: video, duration: segment.duration,
                                    programmeStart: segment.programmeStart, startsWithKeyframe: segment.startsWithKeyframe,
                                    isDiscontinuity: discontinuity, startTime: segment.startTime, endTime: segment.endTime)
        packaged.initialization = videoInitialization
        packaged.audio = fragments
        if collectsSamples {
            // The segment's start, on the same unwrapped clock as the samples.
            let start = segment.startTime.map { first.dts + MPEGTS.signedDelta($0, MPEGTS.wrap(first.dts)) } ?? first.dts
            packaged.native = NativeSamples(timelineStart: Double(start) / Double(MPEGTS.clockRate), video: nativeVideo, audio: nativeAudio)
        }
        return packaged
    }

    /// Native output of a radio channel: its audio alone, timed from the segment's start.
    private func packageAudioOnly(_ segment: MediaSegment, demuxed: Demuxed, program: TSProgram) -> MediaSegment? {
        guard let startTime = segment.startTime else { return nil }
        let start = unwrap(startTime, clock: &videoClock)
        var nativeAudio: [NativeAudioTrack] = []
        for slot in audioStates.indices {
            let stream = program.audio.indices.contains(audioStates[slot].index) ? program.audio[audioStates[slot].index] : nil
            let units = stream.map { demuxed.units[$0.pid] ?? [] } ?? []
            if let track = audioFragment(slot: slot, units: units, segment: segment, videoStart: start,
                                         continues: !segment.isDiscontinuity).native {
                nativeAudio.append(track)
            }
        }
        guard !nativeAudio.isEmpty else { return nil }
        var packaged = MediaSegment(sequence: segment.sequence, data: Data(), duration: segment.duration,
                                    programmeStart: segment.programmeStart, startsWithKeyframe: segment.startsWithKeyframe,
                                    isDiscontinuity: segment.isDiscontinuity, startTime: segment.startTime, endTime: segment.endTime)
        packaged.native = NativeSamples(timelineStart: Double(start) / Double(MPEGTS.clockRate), video: nil, audio: nativeAudio)
        return packaged
    }

    /// A fragment's samples as separate access units, decode times running on from `baseDecodeTime`.
    private static func nativeSamples(_ samples: [FragmentedMP4.Sample], payload: Data, baseDecodeTime: Int64) -> [NativeSample] {
        var output: [NativeSample] = []
        output.reserveCapacity(samples.count)
        var offset = payload.startIndex
        var time = baseDecodeTime
        for sample in samples {
            let end = offset + sample.size
            output.append(NativeSample(data: payload.subdata(in: offset..<end), decodeTime: time, duration: Int64(sample.duration),
                                       compositionOffset: Int64(sample.compositionOffset),
                                       isSync: sample.flags == FragmentedMP4.syncFlags))
            offset = end
            time += Int64(sample.duration)
        }
        return output
    }

    // MARK: - Video

    private func videoFormat(codec: TSProgram.VideoCodec, es: [UInt8], nals: [Range<Int>])
        -> (format: VideoTrackFormat, parameterSets: Set<[UInt8]>, ordered: [[UInt8]])? {
        func units(_ wanted: UInt8) -> [[UInt8]] {
            var seen: Set<[UInt8]> = []
            return nals.compactMap { range in
                let type = codec == .hevc ? HEVCParameterSets.nalType(es[range.lowerBound]) : AVCParameterSets.nalType(es[range.lowerBound])
                let unit = Array(es[range])
                return type == wanted && seen.insert(unit).inserted ? unit : nil
            }
        }
        switch codec {
        case .hevc:
            let vps = units(32), sps = units(33), pps = units(34)
            guard let first = sps.first, !vps.isEmpty, !pps.isEmpty, var info = HEVCParameterSets.parseSPS(first) else { return nil }
            let sei = units(39)
            // HLG sent backward-compatibly: BT.2020 SDR in the VUI, HLG in an SEI.
            if let preferred = HEVCParameterSets.preferredTransfer(sei), preferred == 16 || preferred == 18, var colour = info.colour {
                colour.transfer = preferred
                info.colour = colour
            }
            let metadata = HEVCParameterSets.staticHDRMetadata(sei).map { [$0] } ?? []
            let configuration = HEVCParameterSets.decoderConfiguration(info: info, vps: vps, sps: sps, pps: pps, sei: metadata)
            let format = VideoTrackFormat(codec: .hevc, configuration: configuration, codecString: HEVCParameterSets.codecString(info),
                                          width: info.width, height: info.height, colour: info.colour)
            return (format, Set(vps + sps + pps), vps + sps + pps)
        case .h264:
            let sps = units(7), pps = units(8)
            guard let first = sps.first, !pps.isEmpty, let info = AVCParameterSets.parseSPS(first) else { return nil }
            let format = VideoTrackFormat(codec: .h264, configuration: AVCParameterSets.decoderConfiguration(info: info, sps: sps, pps: pps),
                                          codecString: AVCParameterSets.codecString(sps: first),
                                          width: info.width, height: info.height, colour: info.colour)
            return (format, Set(sps + pps), sps + pps)
        case .mpeg2, .mpeg1:
            return nil
        }
    }

    /// Formats a decoder can't switch between without being told: a different codec, profile, level,
    /// size or colour.
    private static func sameFormat(_ a: VideoTrackFormat, _ b: VideoTrackFormat) -> Bool {
        a.codec == b.codec && a.codecString == b.codecString && a.width == b.width && a.height == b.height && a.colour == b.colour
    }

    /// Access unit delimiters, end of sequence/stream and filler data have no place in MP4 samples.
    private static func dropsFromSample(_ type: UInt8, codec: TSProgram.VideoCodec) -> Bool {
        codec == .hevc ? (35...38).contains(type) : [9, 10, 11, 12].contains(type)
    }

    private static func isParameterSet(_ type: UInt8, codec: TSProgram.VideoCodec) -> Bool {
        codec == .hevc ? (32...34).contains(type) : type == 7 || type == 8
    }

    /// Sample flags from a picture's first slice, or nil for a non-slice NAL unit.
    private static func sampleFlags(_ type: UInt8, codec: TSProgram.VideoCodec) -> UInt32? {
        if codec == .h264 {
            switch type {
            case 5: return FragmentedMP4.syncFlags
            case 1...4: return FragmentedMP4.dependentFlags
            default: return nil
            }
        }
        switch type {
        case 16...23: return FragmentedMP4.syncFlags
        case 8, 9: return FragmentedMP4.undecodableLeadingFlags
        case 6, 7: return FragmentedMP4.decodableLeadingFlags
        case 0...5, 10...15: return FragmentedMP4.dependentFlags
        default: return nil
        }
    }

    // MARK: - Audio

    /// `continues`: the timeline runs on from the previous segment, so decode times must too.
    private func audioFragment(slot: Int, units: [PESUnit], segment: MediaSegment, videoStart: Int64, continues: Bool)
        -> (fragment: AudioFragment?, native: NativeAudioTrack?, formatChanged: Bool) {
        var state = audioStates[slot]
        defer { audioStates[slot] = state }
        // Access units: time (90 kHz) and bytes.
        var accessUnits: [(time: Int64, bytes: [UInt8])] = []
        var blocks = 6
        var formatChanged = false
        for unit in units {
            guard let header = unit.parseHeader(), let rawPTS = header.pts else { continue }
            let pts = unwrap(rawPTS, clock: &state.clock)
            var bytes = state.carry
            let carried = bytes.count
            unit.forEachDataChunk(from: header.dataOffset) { chunk in
                bytes.append(contentsOf: chunk)
                return true
            }
            let split = AudioFrames.split(bytes, codec: state.codec)
            var time = carried > 0 ? state.carryTime : pts
            var inPES = carried == 0
            for frame in split.frames {
                if !inPES, frame.range.lowerBound >= carried {
                    time = pts
                    inPES = true
                }
                if state.format == nil || accessUnits.isEmpty,
                   let format = AudioFrames.format(of: bytes[frame.range], codec: state.codec), format != state.format {
                    if state.format != nil { formatChanged = true }
                    state.format = format
                    state.initialization += 1
                    let section = FragmentedMP4.initializationSection(for: .audio(format, language: state.language))
                    audioInitializations[state.index, default: [:]][state.initialization] = section
                    audioInitializations[state.index] = audioInitializations[state.index]?.filter { $0.key > state.initialization - 16 }
                }
                guard let format = state.format else { continue }
                var frameSamples = format.samplesPerFrame
                if state.codec == .eac3, let info = AudioFrames.eac3Frame(bytes[frame.range]) {
                    // An access unit is 1536 samples of the main substream: frames of fewer blocks,
                    // dependent substreams and further independent substreams join the one they belong to.
                    let main = info.independent && info.substream == 0
                    frameSamples = main ? info.blocks * 256 : 0
                    if !accessUnits.isEmpty, !main || blocks < 6 {
                        accessUnits[accessUnits.count - 1].bytes += bytes[frame.payload]
                        if main { blocks += info.blocks }
                        time += Int64(frameSamples) * MPEGTS.clockRate / Int64(format.sampleRate)
                        continue
                    }
                    blocks = info.blocks
                }
                accessUnits.append((time, Array(bytes[frame.payload])))
                time += Int64(frameSamples) * MPEGTS.clockRate / Int64(format.sampleRate)
            }
            state.carry = split.consumed < bytes.count && bytes.count - split.consumed < 16_384 ? Array(bytes[split.consumed...]) : []
            state.carryTime = time
        }
        guard let format = state.format else { return (nil, nil, formatChanged) }

        let rate = Int64(format.sampleRate)
        let step = Int64(format.samplesPerFrame)
        func timescaled(_ ticks: Int64) -> Int64 { (ticks * rate + MPEGTS.clockRate / 2) / MPEGTS.clockRate }
        var samples: [FragmentedMP4.Sample] = []
        var payload = Data()
        var base: Int64?
        var running: Int64 = 0
        for unit in accessUnits {
            var time = timescaled(unit.time)
            var lead: Int64 = 0
            if base == nil {
                // Carry on exactly from the previous fragment; audio overlapping what was already
                // delivered is dropped. Decode times run on unbroken (HLS authoring rules), so a hole the
                // source left before this frame becomes part of it, the way one inside a fragment
                // lengthens the frame before; only a discontinuity lets them jump.
                if let next = state.nextDecodeTime {
                    if next - time > step / 2 { continue }
                    if abs(time - next) <= step / 2 || (continues && !formatChanged) {
                        lead = time - next
                        time = next
                    }
                }
                base = time
                running = time
            } else if time - running > step / 2, let last = samples.indices.last {
                // A gap: the previous frame lasts until this one.
                samples[last].duration = UInt32(clamping: time - running + Int64(samples[last].duration))
                running = time
            } else if running - time > step / 2 {
                continue
            }
            let duration = step + max(0, lead)
            samples.append(FragmentedMP4.Sample(size: unit.bytes.count, duration: UInt32(clamping: duration), flags: FragmentedMP4.syncFlags))
            payload.append(contentsOf: unit.bytes)
            running += duration
        }
        let start = base ?? state.nextDecodeTime ?? timescaled(videoStart)
        state.nextDecodeTime = base == nil ? state.nextDecodeTime : running
        fragmentSequence += 1
        let data = writesFragments ? FragmentedMP4.fragment(sequence: fragmentSequence, baseDecodeTime: UInt64(max(0, start)), samples: samples,
                                                             payload: payload, compositionOffsets: false) : Data()
        let offset = base.map { Double($0) / Double(rate) - Double(videoStart) / Double(MPEGTS.clockRate) } ?? 0
        let duration = base.map { Double(running - $0) / Double(rate) } ?? segment.duration
        var native: NativeAudioTrack?
        if collectsSamples, let base {
            native = NativeAudioTrack(rendition: state.index, language: state.language, formatNumber: state.initialization, format: format,
                                      magicCookie: format.codec == .aac ? FragmentedMP4.elementaryStreamDescriptor(format) : nil,
                                      samples: Self.nativeSamples(samples, payload: payload, baseDecodeTime: base))
        }
        return (AudioFragment(rendition: state.index, data: data, initialization: state.initialization,
                              programmeStart: segment.programmeStart + offset, duration: duration), native, formatChanged)
    }

    // MARK: - Helpers

    /// Whether a self-contained MPEG-TS segment's program has HEVC video.
    static func carriesHEVC(_ segment: MediaSegment) -> Bool {
        guard case .video(.hevc)? = demux(segment.data, programOnly: true).program?.video?.kind else { return false }
        return true
    }

    /// 33-bit stream time to a monotonic 64-bit one.
    private func unwrap(_ value: Int64, clock: inout Int64?) -> Int64 {
        guard let last = clock else {
            clock = value
            return value
        }
        let unwrapped = last + MPEGTS.signedDelta(value, MPEGTS.wrap(last))
        clock = unwrapped
        return unwrapped
    }

    /// The ISO 639 language descriptor's code.
    private static func language(_ descriptors: [UInt8]) -> String? {
        var index = 0
        while index + 2 <= descriptors.count {
            let tag = descriptors[index]
            let length = Int(descriptors[index + 1])
            if tag == 0x0A, length >= 3, index + 5 <= descriptors.count {
                let code = String(decoding: descriptors[(index + 2)..<(index + 5)], as: UTF8.self).lowercased()
                return code.allSatisfy({ $0.isLetter && $0.isASCII }) ? code : nil
            }
            index += 2 + length
        }
        return nil
    }

    private struct Demuxed {
        var program: TSProgram?
        var units: [UInt16: [PESUnit]] = [:]
    }

    /// The program and the PES packets of one self-contained segment, by PID, in order.
    private static func demux(_ data: Data, programOnly: Bool = false) -> Demuxed {
        var result = Demuxed()
        var patAssembler = PSISectionAssembler()
        var pmtAssembler = PSISectionAssembler()
        var pmtPID: UInt16?
        var pending: [UInt16: [TSPacket]] = [:]
        let bytes = [UInt8](data)
        var offset = 0
        while offset + MPEGTS.packetSize <= bytes.count {
            guard bytes[offset] == 0x47 else {
                offset += 1
                continue
            }
            let packet = TSPacket(bytes: Array(bytes[offset..<(offset + MPEGTS.packetSize)]))
            offset += MPEGTS.packetSize
            let pid = packet.pid
            if pid == MPEGTS.patPID {
                for section in patAssembler.push(packet) {
                    if let entry = PSITables.parsePAT(section)?.first { pmtPID = entry.pmtPID }
                }
                continue
            }
            if pid == pmtPID {
                for section in pmtAssembler.push(packet) where result.program == nil {
                    result.program = PSITables.parsePMT(section, pmtPID: pid)
                }
                if programOnly, result.program != nil { return result }
                continue
            }
            guard packet.hasPayload else { continue }
            if packet.payloadUnitStart {
                if let previous = pending[pid], !previous.isEmpty {
                    result.units[pid, default: []].append(PESUnit(sourcePID: pid, packets: previous))
                }
                pending[pid] = [packet]
            } else if pending[pid] != nil {
                pending[pid]?.append(packet)
            }
        }
        for (pid, packets) in pending where !packets.isEmpty {
            result.units[pid, default: []].append(PESUnit(sourcePID: pid, packets: packets))
        }
        return result
    }
}
