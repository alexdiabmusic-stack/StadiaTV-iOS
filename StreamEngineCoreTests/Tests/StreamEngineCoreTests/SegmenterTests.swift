import Foundation
import Testing
@testable import StreamEngineCore

@Suite("Segments, reserve and playlists")
struct SegmenterTests {
    private func segment(_ sequence: Int, keyframe: Bool = true, bytes: Int = 1_000) -> MediaSegment {
        MediaSegment(sequence: sequence, data: Data(count: bytes), duration: 2, programmeStart: Double(sequence) * 2,
                     startsWithKeyframe: keyframe, isDiscontinuity: false)
    }

    // MARK: - Segmenter

    @Test("Segments open with PAT and PMT, start on keyframes and tile the programme")
    func segmentLayout() throws {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 6))
        harness.finish()

        let segments = harness.segments
        #expect(segments.map(\.sequence) == [0, 1, 2])
        #expect(segments.map { ($0.duration * 1_000).rounded() } == [2_000, 2_000, 1_960])
        #expect(segments.allSatisfy { $0.startsWithKeyframe })
        #expect(!segments.contains { $0.isDiscontinuity })
        for (previous, next) in zip(segments, segments.dropFirst()) {
            #expect(abs(previous.programmeEnd - next.programmeStart) < 0.000_001)
        }
        for segment in segments {
            let bytes = [UInt8](segment.data)
            #expect(bytes.count % 188 == 0)
            let packets = transportPackets(bytes)
            #expect(packets[0].pid == 0)
            #expect(packets[1].pid == 0x1000)
            var assembler = PSISectionAssembler()
            let pmt = try #require(assembler.push(packets[1]).first)
            #expect(PSITables.parsePMT(pmt, pmtPID: 0x1000)?.video?.kind == .video(.h264))
            let firstPicture = try #require(pesUnits(in: bytes, pid: 0x100).first)
            let header = try #require(firstPicture.parseHeader())
            #expect(AccessUnitInspector.inspect(firstPicture, dataOffset: header.dataOffset, codec: .h264).isInstantRefresh)
        }
    }

    @Test("A long-GOP source is cut at the maximum length, and still at its keyframes")
    func longGOP() {
        var stream = SyntheticTransportStream()
        stream.gop = 300
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 16))
        harness.finish()

        let configuration = HLSSegmenter.Configuration()
        // EXTINF rounded to the nearest second may not exceed the target duration.
        #expect(harness.segments.allSatisfy { $0.duration.rounded() <= Double(configuration.playlistTargetDuration) })
        #expect(harness.segments.allSatisfy { $0.duration <= configuration.maximumDuration + 0.05 })
        // The 12 s GOP's keyframes (0 and 12 s) each begin a segment, and nothing else is taken for one.
        #expect(harness.segments.filter(\.startsWithKeyframe).map { $0.programmeStart.rounded() } == [0, 12])
        #expect(abs(harness.segments.reduce(0) { $0 + $1.duration } - 16) < 0.05)
    }

    @Test("A keyframe every 4 s, common on IPTV encoders, is cut once inside each GOP and again at its keyframe")
    func fourSecondGOP() {
        var stream = SyntheticTransportStream()
        stream.gop = 100
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 12))
        harness.finish()

        let configuration = HLSSegmenter.Configuration()
        #expect(harness.segments.count == 6)
        #expect(harness.segments.allSatisfy { $0.duration.rounded() <= Double(configuration.playlistTargetDuration) })
        #expect(harness.segments.map(\.startsWithKeyframe) == [true, false, true, false, true, false])
        #expect(harness.segments.filter(\.startsWithKeyframe).map { $0.programmeStart.rounded() } == [0, 4, 8])
    }

    @Test("Short GOPs give short startup segments, then the target length")
    func startupSegments() {
        var stream = SyntheticTransportStream()
        stream.gop = 25
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 8))
        harness.finish()

        #expect(harness.segments.map { ($0.duration * 1_000).rounded() } == [1_000, 1_000, 2_000, 2_000, 1_960])
    }

    @Test("Flushing cuts the open segment where its programme ends")
    func flush() {
        var stream = SyntheticTransportStream()
        var harness = PipelineHarness()
        harness.connection(stream.bytes(seconds: 3))
        #expect(harness.segments.count == 1)
        #expect(abs(harness.segmenter.openDuration - 0.96) < 0.001)
        harness.finish()
        #expect(harness.segments.map { ($0.duration * 1_000).rounded() } == [2_000, 960])
        #expect(harness.segmenter.flush() == nil)
    }

    // MARK: - Reserve

    @Test("The reserve publishes ahead of the playhead and keeps a back buffer behind it")
    func reservePublishing() {
        var reserve = SegmentReserve(configuration: .init(backBufferSeconds: 10, maximumBytes: 1_000_000))
        for sequence in 0..<10 { reserve.append(segment(sequence, keyframe: sequence % 2 == 0)) }
        #expect(reserve.reserveSeconds == 20)
        #expect(reserve.publishNext()?.sequence == 0)
        #expect(reserve.publish(before: 5) == 2)
        #expect(reserve.published.map(\.sequence) == [0, 1, 2])
        #expect(reserve.reserveSeconds == 14)
        #expect(reserve.publishedEnd == 6)
        #expect(reserve.ingestEnd == 20)
        #expect(reserve.segment(sequence: 2) != nil)
        #expect(reserve.segment(sequence: 3) == nil)
        #expect(reserve.joinPoint(atOrBefore: 5)?.sequence == 2)
        #expect(reserve.joinPoint(atOrBefore: 3.9)?.sequence == 0)

        reserve.publish(before: 19)
        reserve.evict(playhead: 17)
        #expect(reserve.published.first?.sequence == 3)
        #expect(reserve.byteCount == 7_000)
        #expect(reserve.segment(sequence: 2) == nil)
        reserve.publishAll()
        #expect(reserve.reserveSeconds == 0)
    }

    @Test("At its byte ceiling the reserve drops rewind history first, then the oldest unplayed programme")
    func reserveCeiling() {
        var reserve = SegmentReserve(configuration: .init(backBufferSeconds: 30, maximumBytes: 5_000))
        for sequence in 0..<3 { reserve.append(segment(sequence)) }
        reserve.publish(before: 3)
        for sequence in 3..<5 { reserve.append(segment(sequence)) }
        #expect(reserve.segments.count == 5)

        reserve.append(segment(5))
        #expect(reserve.segments.first?.sequence == 1)
        #expect(reserve.discardedSeconds == 0)

        reserve.append(segment(6))
        #expect(reserve.published.map(\.sequence) == [1])
        #expect(reserve.unpublished.map(\.sequence) == [3, 4, 5, 6])
        #expect(reserve.discardedSeconds == 2)
        // Where programme was skipped, the decoder is told.
        #expect(reserve.unpublished.first?.isDiscontinuity == true)
        #expect(reserve.byteCount <= 5_000)
    }

    @Test("Discontinuities that scroll out of the window advance the discontinuity sequence")
    func evictedDiscontinuities() {
        var reserve = SegmentReserve(configuration: .init(backBufferSeconds: 2, maximumBytes: 1_000_000))
        for sequence in 0..<6 {
            var next = segment(sequence)
            next.isDiscontinuity = sequence == 1
            reserve.append(next)
        }
        reserve.publishAll()
        reserve.evict(playhead: 9)
        #expect(reserve.published.first?.sequence == 3)
        #expect(reserve.evictedDiscontinuities == 1)
    }

    // MARK: - Local playlist

    @Test("The local playlist carries sequence, discontinuities, programme dates and the join offset")
    func playlistWriter() {
        var later = segment(6)
        later.isDiscontinuity = true
        let text = HLSPlaylistWriter.mediaPlaylist(segments: [segment(5), later][...], targetDuration: 4, discontinuitySequence: 3,
                                                   epoch: Date(timeIntervalSince1970: 1_700_000_000 - 10), startOffset: 2)
        #expect(text == """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:5
        #EXT-X-DISCONTINUITY-SEQUENCE:3
        #EXT-X-START:TIME-OFFSET=2.000,PRECISE=NO
        #EXT-X-PROGRAM-DATE-TIME:2023-11-14T22:13:20.000Z
        #EXTINF:2.000,
        s5.ts
        #EXT-X-DISCONTINUITY
        #EXT-X-PROGRAM-DATE-TIME:2023-11-14T22:13:22.000Z
        #EXTINF:2.000,
        s6.ts

        """)
    }

    @Test("fMP4 playlists name the initialization section after every discontinuity and claim independent segments only when true")
    func fragmentedPlaylistWriter() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000 - 10)
        var entries: [HLSPlaylistWriter.FragmentEntry] = [
            .init(uri: "v5.m4s", map: "v1.mp4", duration: 2, programmeStart: 10, isDiscontinuity: false),
            .init(uri: "v6.m4s", map: "v1.mp4", duration: 2, programmeStart: 12, isDiscontinuity: false),
            .init(uri: "v7.m4s", map: "v2.mp4", duration: 2, programmeStart: 14, isDiscontinuity: true)
        ]
        func render() -> String {
            HLSPlaylistWriter.fragmentedMediaPlaylist(entries: entries, mediaSequence: 5, targetDuration: 4,
                                                      discontinuitySequence: 1, epoch: epoch, startOffset: 2)
        }
        #expect(render() == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:5
        #EXT-X-DISCONTINUITY-SEQUENCE:1
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-START:TIME-OFFSET=2.000,PRECISE=NO
        #EXT-X-MAP:URI="v1.mp4"
        #EXT-X-PROGRAM-DATE-TIME:2023-11-14T22:13:20.000Z
        #EXTINF:2.000,
        v5.m4s
        #EXT-X-PROGRAM-DATE-TIME:2023-11-14T22:13:22.000Z
        #EXTINF:2.000,
        v6.m4s
        #EXT-X-DISCONTINUITY
        #EXT-X-MAP:URI="v2.mp4"
        #EXT-X-PROGRAM-DATE-TIME:2023-11-14T22:13:24.000Z
        #EXTINF:2.000,
        v7.m4s

        """)
        // A player may reset its demuxer at a discontinuity, so an unchanged section is named again.
        entries[2].map = "v1.mp4"
        #expect(render().components(separatedBy: "#EXT-X-MAP:URI=\"v1.mp4\"").count == 3)
        // A long GOP cut short leaves a segment that doesn't start with a keyframe.
        entries[1].isIndependent = false
        #expect(!render().contains("#EXT-X-INDEPENDENT-SEGMENTS"))

        let multivariant = HLSPlaylistWriter.multivariantPlaylist(
            videoURI: "video.m3u8", bandwidth: 18_000_000, averageBandwidth: 15_000_000, codecs: ["hvc1.2.4.L153.B0", "ec-3"],
            width: 3840, height: 2160, frameRate: 50, videoRange: "PQ",
            audio: [.init(uri: "audio0.m3u8", name: "English", language: "en", channels: 6, isDefault: true),
                    .init(uri: "audio1.m3u8", name: "French", language: "fr", channels: 2, isDefault: false)])
        #expect(multivariant == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="6",URI="audio0.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="French",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio1.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=18000000,AVERAGE-BANDWIDTH=15000000,CODECS="hvc1.2.4.L153.B0,ec-3",RESOLUTION=3840x2160,FRAME-RATE=50.000,VIDEO-RANGE=PQ,AUDIO="audio"
        video.m3u8

        """)
    }

    @Test("Programme dates are ISO 8601 in UTC with milliseconds", arguments: [
        (0.0, "1970-01-01T00:00:00.000Z"),
        (951_782_400.5, "2000-02-29T00:00:00.500Z"),
        (1_700_000_000.123, "2023-11-14T22:13:20.123Z"),
        (4_102_444_799.999, "2099-12-31T23:59:59.999Z")
    ])
    func timestamps(seconds: Double, expected: String) {
        #expect(HLSPlaylistWriter.timestamp(Date(timeIntervalSince1970: seconds)) == expected)
    }

    // MARK: - Provider playlists

    @Test("A live provider playlist yields its segments with absolute URLs and discontinuities")
    func providerMediaPlaylist() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:1041
        #EXTINF:6.006,
        seg-1041.ts
        #EXTINF:5.005,live
        /hls/seg-1042.ts?token=abc
        #EXT-X-DISCONTINUITY
        #EXTINF:6,
        https://cdn.example.com/other/seg-1043.ts
        """
        let base = try #require(URL(string: "http://provider.example:8080/live/user/pass/7.m3u8"))
        guard case .media(let playlist) = HLSPlaylistParser.parse(text, baseURL: base) else {
            Issue.record("not read as a media playlist")
            return
        }
        #expect(playlist.targetDuration == 6)
        #expect(playlist.mediaSequence == 1041)
        #expect(!playlist.isEnded)
        #expect(playlist.unsupportedReason == nil)
        #expect(playlist.segments.map(\.url.absoluteString) == [
            "http://provider.example:8080/live/user/pass/seg-1041.ts",
            "http://provider.example:8080/hls/seg-1042.ts?token=abc",
            "https://cdn.example.com/other/seg-1043.ts"
        ])
        #expect(playlist.segments.map(\.sequence) == [1041, 1042, 1043])
        #expect(playlist.segments.map(\.duration) == [6.006, 5.005, 6])
        #expect(playlist.segments.map(\.discontinuity) == [false, false, true])
    }

    @Test("A master playlist lists its variants")
    func providerMasterPlaylist() throws {
        let line = #"#EXT-X-STREAM-INF:BANDWIDTH=2560000,CODECS="avc1.4d401f,mp4a.40.2",RESOLUTION=1280x720"#
        let text = "#EXTM3U\n\(line)\n720/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nhttps://cdn.example.com/480/index.m3u8\n"
        let base = try #require(URL(string: "http://provider.example/hls/master.m3u8"))
        guard case .master(let variants) = HLSPlaylistParser.parse(text, baseURL: base) else {
            Issue.record("not read as a master playlist")
            return
        }
        #expect(variants.map(\.url.absoluteString) == ["http://provider.example/hls/720/index.m3u8",
                                                       "https://cdn.example.com/480/index.m3u8"])
        #expect(variants.map(\.bandwidth) == [2_560_000, 800_000])
        #expect(HLSPlaylistParser.attribute("CODECS", in: line) == "avc1.4d401f,mp4a.40.2")
        #expect(HLSPlaylistParser.attribute("resolution", in: line) == "1280x720")
        #expect(HLSPlaylistParser.attribute("FRAME-RATE", in: line) == nil)
    }

    @Test("Playlists the engine can't ingest say why", arguments: [
        (#"#EXT-X-KEY:METHOD=AES-128,URI="key.bin""#, "encrypted"),
        (#"#EXT-X-MAP:URI="init.mp4""#, "fragmented MP4"),
        ("#EXT-X-BYTERANGE:1000@0", "byte-range segments"),
        ("#EXT-X-ENDLIST", "on-demand"),
        ("#EXT-X-PLAYLIST-TYPE:VOD", "on-demand")
    ])
    func unsupportedPlaylists(tag: String, reason: String) throws {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n\(tag)\n#EXTINF:4,\nseg1.ts\n"
        let base = try #require(URL(string: "http://provider.example/a.m3u8"))
        guard case .media(let playlist) = HLSPlaylistParser.parse(text, baseURL: base) else {
            Issue.record("not read as a media playlist")
            return
        }
        #expect(playlist.unsupportedReason == reason)
    }

    @Test("Clear keys, audio-only renditions and non-playlists")
    func otherPlaylists() throws {
        let base = try #require(URL(string: "http://provider.example/a.m3u8"))
        let clear = HLSPlaylistParser.parse("#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:4,\nseg1.ts\n", baseURL: base)
        guard case .media(let playlist) = clear else {
            Issue.record("not read as a media playlist")
            return
        }
        #expect(playlist.unsupportedReason == nil)
        #expect(playlist.targetDuration == 6)
        if case .media(let audio) = HLSPlaylistParser.parse("#EXTM3U\n#EXTINF:4,\nchunk1.aac\n", baseURL: base) {
            #expect(audio.unsupportedReason == "aac segments")
        } else {
            Issue.record("not read as a media playlist")
        }
        #expect(HLSPlaylistParser.parse("<html>Forbidden</html>", baseURL: base) == .invalid)
        #expect(HLSPlaylistParser.parse("\u{FEFF}#EXTM3U\n#EXTINF:4,\nseg1.ts\n", baseURL: base) != .invalid)
    }
}
