import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import StreamEngineCore

@Suite("Engine plumbing")
struct EnginePlumbingTests {
    @Test("Xtream live URLs get the raw transport stream first and the panel's HLS output as backup")
    func xtreamRoutes() throws {
        let cases: [(String, [String])] = [
            ("http://host.example:8080/user/pass/1234",
             ["http://host.example:8080/user/pass/1234", "http://host.example:8080/live/user/pass/1234.m3u8"]),
            ("http://host.example/live/user/pass/1234.ts",
             ["http://host.example/live/user/pass/1234.ts", "http://host.example/live/user/pass/1234.m3u8"]),
            ("http://host.example/live/user/pass/1234.m3u8?token=abc",
             ["http://host.example/live/user/pass/1234.ts?token=abc", "http://host.example/live/user/pass/1234.m3u8?token=abc"])
        ]
        for (input, expected) in cases {
            let url = try #require(URL(string: input))
            let routes = try #require(StreamEnginePlanner.routes(for: url))
            #expect(routes.map(\.url.absoluteString) == expected)
            #expect(routes.map(\.label) == ["MPEG-TS", "HLS"])
        }
    }

    @Test("Other live URLs get one route; on-demand and non-HTTP URLs stay with AVPlayer")
    func otherRoutes() throws {
        let hlsURL = try #require(URL(string: "https://cdn.example.com/channel/index.m3u8"))
        let hls = try #require(StreamEnginePlanner.routes(for: hlsURL))
        #expect(hls.map(\.label) == ["HLS"])
        let tsURL = try #require(URL(string: "http://host.example/live/user/pass/abc.ts"))
        let ts = try #require(StreamEnginePlanner.routes(for: tsURL))
        #expect(ts.map(\.label) == ["MPEG-TS"])
        let direct = [
            "http://host.example/movie/user/pass/55.mp4",
            "http://host.example/series/user/pass/77.mkv",
            "http://host.example/timeshift/user/pass/60/2024-01-01:10-00/123.ts",
            "http://host.example/streaming/index.m3u8?utc=1700000000&lutc=1700003600",
            "http://host.example/hls/index-1700000000-3600.m3u8",
            "http://host.example/manifest.mpd",
            "rtmp://host.example/live/stream",
            "file:///tmp/clip.ts"
        ]
        for text in direct {
            let url = try #require(URL(string: text))
            let routes = StreamEnginePlanner.routes(for: url)
            #expect(routes == nil, "\(text)")
        }
    }

    @Test("Request heads and byte ranges are read the way AVPlayer sends them")
    func requestParsing() throws {
        let head = "GET /token/session/live.m3u8?_HLS_msn=4 HTTP/1.1\r\nHost: 127.0.0.1:52000\r\nRange: bytes=0-1\r\n"
            + "X-Playback-Session-Id: ABC\r\nConnection: keep-alive"
        let request = try #require(LoopbackHTTPServer.parseRequest(Array(head.utf8)))
        #expect(request.method == "GET")
        #expect(request.path == "/token/session/live.m3u8")
        #expect(request.headers["range"] == "bytes=0-1")
        #expect(request.headers["x-playback-session-id"] == "ABC")
        #expect(request.headers["host"] == "127.0.0.1:52000")
        #expect(LoopbackHTTPServer.parseRequest(Array("garbage".utf8)) == nil)
        #expect(LoopbackHTTPServer.headerTerminator(in: Array("GET / HTTP/1.1\r\nHost: a\r\n\r\nrest".utf8)) == 23)
        #expect(LoopbackHTTPServer.headerTerminator(in: Array("GET / HTTP/1.1\r\n".utf8)) == nil)

        #expect(LoopbackHTTPServer.byteRange("bytes=0-99", length: 1_000) == 0..<100)
        #expect(LoopbackHTTPServer.byteRange("bytes=900-", length: 1_000) == 900..<1_000)
        #expect(LoopbackHTTPServer.byteRange("bytes=-100", length: 1_000) == 900..<1_000)
        #expect(LoopbackHTTPServer.byteRange("bytes=0-5000", length: 1_000) == 0..<1_000)
        #expect(LoopbackHTTPServer.byteRange("bytes=1000-", length: 1_000) == nil)
        #expect(LoopbackHTTPServer.byteRange("bytes=5-2", length: 1_000) == nil)
        #expect(LoopbackHTTPServer.byteRange("items=0-1", length: 1_000) == nil)
        #expect(LoopbackHTTPServer.byteRange("bytes=0-1", length: 0) == nil)
    }

    @Test("The loopback server answers whole and ranged requests and refuses unknown paths")
    func loopbackServer() async throws {
        let body = Data((0..<1_000).map { UInt8($0 % 251) })
        let server = LoopbackHTTPServer { request in
            request.path == "/token/s1.ts" ? .init(status: 200, contentType: "video/mp2t", body: body) : .notFound()
        }
        let port = try server.start()
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/token/s1.ts"))

        let whole = await fetch(url)
        #expect(whole.status == 200)
        #expect(whole.body == body)
        #expect(whole.headers["content-type"] == "video/mp2t")
        let ranged = await fetch(url, headers: ["Range": "bytes=100-199"])
        #expect(ranged.status == 206)
        #expect(ranged.body == body.subdata(in: 100..<200))
        #expect(ranged.headers["content-range"] == "bytes 100-199/1000")
        let missingURL = try #require(URL(string: "http://127.0.0.1:\(port)/token/s2.ts?x=1"))
        let missing = await fetch(missingURL)
        #expect(missing.status == 404)
    }

    @Test("The first bytes tell a transport stream from a playlist or an error page")
    func sniffing() {
        var stream = SyntheticTransportStream()
        let ts = Data(stream.bytes(seconds: 0.2))
        #expect(TSStreamConnection.containsTransportSync(ts))
        #expect(TSStreamConnection.containsTransportSync(Data([0x00, 0x12, 0x47]) + ts))
        #expect(!TSStreamConnection.looksLikePlaylist(ts))
        #expect(TSStreamConnection.looksLikePlaylist(Data("\u{FEFF}#EXTM3U\n#EXT-X-VERSION:3".utf8)))
        #expect(TSStreamConnection.looksLikePlaylist(Data("\r\n  #EXTM3U".utf8)))
        let html = Data("<html><body>Max connections reached</body></html>".utf8)
        #expect(!TSStreamConnection.looksLikePlaylist(html))
        #expect(!TSStreamConnection.containsTransportSync(html))
    }

    @Test("Provider answers map onto the referee's failure kinds, and requests look like AVPlayer's")
    func providerAnswers() throws {
        #expect(EngineHTTPClient.failure(forStatus: 403) == .accountRejected(403))
        #expect(EngineHTTPClient.failure(forStatus: 458) == .accountRejected(458))
        #expect(EngineHTTPClient.failure(forStatus: 404) == .notFound(404))
        #expect(EngineHTTPClient.failure(forStatus: 502) == .server(502))
        let url = try #require(URL(string: "http://provider.example/live/a/b/1.ts"))
        let plain = EngineHTTPClient.request(url: url, headers: ["Referer": "http://provider.example/"])
        #expect(plain.value(forHTTPHeaderField: "User-Agent") == EngineHTTPClient.defaultUserAgent)
        #expect(plain.value(forHTTPHeaderField: "Referer") == "http://provider.example/")
        #expect(plain.value(forHTTPHeaderField: "Accept") == "*/*")
        let custom = EngineHTTPClient.request(url: url, headers: ["user-agent": "VLC/3.0.20"])
        #expect(custom.value(forHTTPHeaderField: "User-Agent") == "VLC/3.0.20")
    }
}

/// The whole engine, in real time, against providers that misbehave the way IPTV panels do.
@Suite("Engine end to end", .timeLimit(.minutes(1)))
struct EngineEndToEndTests {
    @Test("A provider cut mid-packet is bridged from the reserve: no freeze, nothing missed or repeated")
    func transportStreamCut() async throws {
        // The panel holds 16 s of programme, bursts the last 12 s on connect, and drops the first
        // connection 3 s in, in the middle of a packet. The reconnect's burst re-sends the GOP the
        // drop cut short, so the engine takes over from its keyframe and nothing is skipped. The
        // player plays long enough to receive that GOP.
        let channel = try FakeTransportChannel(seconds: 60, lead: 16, burst: 12, cuts: [0: 3])
        defer { channel.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(channel.port)/play/1234.ts"))
        let run = try await play(routes: [.init(url: url, label: "MPEG-TS")], profile: .fast, seconds: 14)

        #expect(run.failure == nil)
        #expect(channel.connectionCount >= 2)
        #expect(run.startup < 3)
        #expect(run.player.freezes == 0)
        #expect(!run.player.sawDiscontinuity)
        let status = try #require(run.status)
        #expect(status.reconnects >= 1)
        #expect(status.overlapsRemoved >= 1)
        expectOneTimeline(run.player, maximumMissing: 0)
    }

    @Test("An Xtream channel without .ts output falls back to HLS and rides out an HLS outage")
    func hlsFallbackAndOutage() async throws {
        // The panel's playlist window holds 20 s; for five seconds every request to it fails.
        let channel = try FakeHLSChannel(seconds: 60, lead: 24, outage: 4..<9)
        defer { channel.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(channel.port)/live/user/pass/77.ts"))
        let routes = try #require(StreamEnginePlanner.routes(for: url))
        // The player plays on until it has received the programme where ingest resumed, which the
        // reserve held some 16 s ahead of the picture.
        let run = try await play(routes: routes, profile: .balanced, seconds: 22)

        #expect(run.failure == nil)
        #expect(channel.transportRequests >= 1)
        #expect(run.player.freezes == 0)
        #expect(!run.player.sawDiscontinuity)
        let status = try #require(run.status)
        #expect(status.route == "HLS")
        #expect(status.reconnects >= 1)
        // HLS ingest resumes after the last segment delivered, and segments arrive whole: nothing is lost.
        let before = try #require(channel.segmentRequests.last { $0.time < 4 }?.sequence)
        let resumed = try #require(channel.segmentRequests.first { $0.time >= 9 }?.sequence)
        #expect(resumed == before + 1)
        let frames = pesUnits(in: run.player.downloaded.flatMap { [UInt8]($0.data) }, pid: 0x100)
            .compactMap { SyntheticTransportStream.picture(in: $0)?.frame }
        #expect((frames.last ?? 0) >= (resumed + 1) * 50)
        expectOneTimeline(run.player, maximumMissing: 0)
    }

    @Test("A 4K HEVC channel is published as fMP4 renditions that play through a provider cut")
    func hevcChannel() async throws {
        var stream = SyntheticTransportStream()
        stream.videoStreamType = 0x24
        stream.parameterSets = EncoderSamples.pq
        stream.audioLanguage = "eng"
        stream.surroundTracks = [(pid: 0x102, language: "fra")]
        let channel = try FakeTransportChannel(seconds: 60, lead: 16, burst: 12, cuts: [0: 3], streams: [(0, stream)])
        defer { channel.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(channel.port)/play/1234.ts"))
        let run = try await play(routes: [.init(url: url, label: "MPEG-TS")], profile: .fast, seconds: 14)

        #expect(run.failure == nil)
        #expect(channel.connectionCount >= 2)
        #expect(run.startup < 3)
        #expect(run.player.freezes == 0)
        #expect(!run.player.sawDiscontinuity)
        #expect(run.replaced.isEmpty)
        let status = try #require(run.status)
        #expect(status.reconnects >= 1)

        // One video variant, described so AVPlayer can choose it and set up HDR before the first
        // picture, and each audio track as its own rendition.
        let lines = (run.multivariant ?? "").split(separator: "\n").map(String.init)
        let variant = try #require(lines.first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
        #expect(variant.contains("CODECS=\"hvc1.2.4.L153.90,mp4a.40.2,ec-3\""))
        #expect(variant.contains("RESOLUTION=3840x2160"))
        #expect(variant.contains("FRAME-RATE=25.000"))
        #expect(variant.contains("VIDEO-RANGE=PQ"))
        #expect(variant.contains("AUDIO=\"audio\""))
        let renditions = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO,") }
        #expect(renditions.count == 2)
        let english = renditions.first ?? ""
        let french = renditions.last ?? ""
        #expect(english.contains("LANGUAGE=\"en\"") && english.contains("DEFAULT=YES") && english.contains("CHANNELS=\"2\""))
        #expect(french.contains("LANGUAGE=\"fr\"") && french.contains("DEFAULT=NO") && french.contains("CHANNELS=\"6\""))
        // Every segment starts with a keyframe, which the video playlist itself says.
        #expect(run.lastPlaylist.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        #expect(run.lastPlaylist.contains("#EXT-X-MAP:URI=\"v1.mp4\""))

        // Video: an hvc1 track with the channel's parameter sets and HDR10 metadata, and one
        // picture timeline across the cut.
        let map = try #require(run.player.entries.values.first?.map)
        let section = try #require(run.initializations[map])
        let record = try #require(sampleEntry(of: [UInt8](section)[...])?.child("hvcC", skipping: 78))
        #expect(configurationUnits(Array(record.body))
                == [EncoderSamples.pqVPS, EncoderSamples.pqSPS, EncoderSamples.pps, EncoderSamples.combinedHDR10])
        let fragments = expectFragmentedTimeline(run.player, maximumMissing: 0)
        #expect(fragments.allSatisfy { $0.samples.allSatisfy { $0.duration == 3_600 } })

        // Audio: each rendition unbroken, starting with the pictures.
        let first = try #require(fragments.first?.samples.first)
        let pictureStart = Double(Int64(fragments[0].baseDecodeTime) + Int64(first.compositionOffset)) / 90_000
        #expect(run.audioPlayers.count == 2)
        for audio in run.audioPlayers {
            let parsed = audio.downloaded.compactMap { ParsedFragment($0.data) }
            #expect(parsed.count == audio.downloaded.count)
            #expect(parsed.count >= 5)
            expectContinuous(parsed)
            if let start = parsed.first {
                #expect(abs(Double(start.baseDecodeTime) / 48_000 - pictureStart) < 0.1)
            }
        }
    }

    @Test("A 4K HEVC Xtream channel moves to the panel's HLS output before it plays, and starts from its window")
    func hevcPrefersHLS() async throws {
        var stream = SyntheticTransportStream()
        stream.videoStreamType = 0x24
        stream.parameterSets = EncoderSamples.pq
        let transport = try FakeTransportChannel(seconds: 60, lead: 16, burst: 12, streams: [(0, stream)])
        defer { transport.stop() }
        let hls = try FakeHLSChannel(seconds: 60, lead: 16, segmentDelay: 0.2, stream: stream)
        defer { hls.stop() }
        let routes: [StreamEngineSession.Route] = [
            .init(url: try #require(URL(string: "http://127.0.0.1:\(transport.port)/live/user/pass/77.ts")), label: "MPEG-TS"),
            .init(url: try #require(URL(string: "http://127.0.0.1:\(hls.port)/live/user/pass/77.m3u8")), label: "HLS")
        ]
        let run = try await play(routes: routes, profile: .balanced, seconds: 14)

        #expect(run.failure == nil)
        #expect(run.startup < 5)
        let status = try #require(run.status)
        #expect(status.route == "HLS")
        #expect(status.routeSwitches == 1)
        #expect(run.player.freezes == 0)
        #expect(run.replaced.isEmpty)
        #expect(run.multivariant?.contains("CODECS=\"hvc1.2.4.L153.90,mp4a.40.2\"") == true)
        // Nothing from the MPEG-TS connection was published: the HLS window's deep join is the reserve.
        #expect(hls.segmentRequests.count >= 5)
        expectFragmentedTimeline(run.player, maximumMissing: 0)
    }

    @Test("An Xtream channel that's off the air is reported within seconds, not retried for the viewer to watch")
    func offAirChannel() async throws {
        // Panels answer 502 on both outputs of an event channel with no event on.
        let transport = try FakeTransportChannel(seconds: 20, lead: 16, burst: 8, answer: 502)
        defer { transport.stop() }
        let hls = try FakeHLSChannel(seconds: 20, lead: 16, answer: 502)
        defer { hls.stop() }
        let routes: [StreamEngineSession.Route] = [
            .init(url: try #require(URL(string: "http://127.0.0.1:\(transport.port)/live/user/pass/77.ts")), label: "MPEG-TS"),
            .init(url: try #require(URL(string: "http://127.0.0.1:\(hls.port)/live/user/pass/77.m3u8")), label: "HLS")
        ]
        let recorder = EngineEventRecorder()
        let session = try StreamEngine.shared.makeSession(routes: routes, headers: [:], configuration: .profile(.balanced),
                                                          isSingleConnectionAccount: false, onEvent: { recorder.record($0) })
        session.start()
        defer { session.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        while recorder.failure == nil, recorder.ready == nil, ProcessInfo.processInfo.systemUptime - started < 15 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(recorder.failure == .offAir)
        #expect(recorder.ready == nil)
        #expect(ProcessInfo.processInfo.systemUptime - started < 6)
        // AVPlayer would get the same answers, so the player shows the message instead of trying again.
        #expect(recorder.failure?.allowsDirectPlayback == false)
        #expect(transport.connectionCount >= 2)
        #expect(hls.playlistRequests >= 2)
    }

    @Test("A channel that answers and then sends nothing on both outputs is reported off the air after one wait per output")
    func silentChannel() async throws {
        let transport = try FakeTransportChannel(seconds: 20, lead: 16, burst: 8, silent: true)
        defer { transport.stop() }
        // A negative lead: the live playlist lists no segments for the whole test.
        let hls = try FakeHLSChannel(seconds: 20, lead: -100)
        defer { hls.stop() }
        let routes: [StreamEngineSession.Route] = [
            .init(url: try #require(URL(string: "http://127.0.0.1:\(transport.port)/live/user/pass/77.ts")), label: "MPEG-TS"),
            .init(url: try #require(URL(string: "http://127.0.0.1:\(hls.port)/live/user/pass/77.m3u8")), label: "HLS")
        ]
        // A short start-up timeout keeps the test quick; the rule is the same at 12 s.
        var configuration = StreamEngineConfiguration.profile(.balanced)
        configuration.startupTimeout = 3
        let recorder = EngineEventRecorder()
        let session = try StreamEngine.shared.makeSession(routes: routes, headers: [:], configuration: configuration,
                                                          isSingleConnectionAccount: false, onEvent: { recorder.record($0) })
        session.start()
        defer { session.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        while recorder.failure == nil, recorder.ready == nil, ProcessInfo.processInfo.systemUptime - started < 15 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // The HLS output lists no segments yet; the MPEG-TS output answered and stayed silent.
        #expect(recorder.failure == .offAir)
        #expect(ProcessInfo.processInfo.systemUptime - started < 9)
        #expect(transport.connectionCount == 1)
    }

    @Test("A channel the panel takes 7 s to start plays from its MPEG-TS output, without the engine giving up on it")
    func slowStartingChannel() async throws {
        // An on-demand source nobody else is watching: the panel answers once it has started it.
        let transport = try FakeTransportChannel(seconds: 60, lead: 16, burst: 8, startupDelay: 7)
        defer { transport.stop() }
        let hls = try FakeHLSChannel(seconds: 60, lead: 16)
        defer { hls.stop() }
        let routes: [StreamEngineSession.Route] = [
            .init(url: try #require(URL(string: "http://127.0.0.1:\(transport.port)/live/user/pass/77.ts")), label: "MPEG-TS"),
            .init(url: try #require(URL(string: "http://127.0.0.1:\(hls.port)/live/user/pass/77.m3u8")), label: "HLS")
        ]
        let run = try await play(routes: routes, profile: .balanced, seconds: 12, readyWithin: 20)

        #expect(run.failure == nil)
        #expect(run.startup >= 7)
        #expect(run.startup < 11)
        let status = try #require(run.status)
        #expect(status.route == "MPEG-TS")
        #expect(status.routeSwitches == 0)
        #expect(transport.connectionCount == 1)
        #expect(hls.playlistRequests == 0)
        #expect(run.player.freezes == 0)
    }

    @Test("A channel the panel can't start on its MPEG-TS output plays from HLS without waiting for the refusal")
    func refusedSlowStart() async throws {
        // The panel tries to start the source on MPEG-TS for 9 s and then answers 502; its HLS output works.
        let transport = try FakeTransportChannel(seconds: 60, lead: 16, burst: 8, answer: 502, startupDelay: 9)
        defer { transport.stop() }
        let hls = try FakeHLSChannel(seconds: 60, lead: 16)
        defer { hls.stop() }
        let routes: [StreamEngineSession.Route] = [
            .init(url: try #require(URL(string: "http://127.0.0.1:\(transport.port)/live/user/pass/77.ts")), label: "MPEG-TS"),
            .init(url: try #require(URL(string: "http://127.0.0.1:\(hls.port)/live/user/pass/77.m3u8")), label: "HLS")
        ]
        let run = try await play(routes: routes, profile: .balanced, seconds: 10, readyWithin: 20)

        #expect(run.failure == nil)
        #expect(run.startup >= 8)
        #expect(run.startup < 10)
        let status = try #require(run.status)
        #expect(status.route == "HLS")
        #expect(run.player.freezes == 0)
    }

    @Test("A player that's still starting sees the playlist keep growing: AVPlayer fails a live playlist that stops changing")
    func playlistGrowsBeforePlayback() async throws {
        let channel = try FakeTransportChannel(seconds: 40, lead: 16, burst: 6)
        defer { channel.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(channel.port)/play/1234.ts"))
        let recorder = EngineEventRecorder()
        let session = try StreamEngine.shared.makeSession(routes: [.init(url: url, label: "MPEG-TS")], headers: [:],
                                                          configuration: .profile(.balanced), isSingleConnectionAccount: false,
                                                          onEvent: { recorder.record($0) })
        session.start()
        defer { session.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }
        while recorder.ready == nil, elapsed() < 10 { try await Task.sleep(nanoseconds: 50_000_000) }
        let playlistURL = try #require(recorder.ready)

        // Like AVPlayer while it starts: it has read the playlist, reports where it will start from,
        // and isn't playing yet.
        var player = VirtualPlayer(epoch: session.programmeEpoch)
        var segments: [Int] = []
        var lastChange = elapsed()
        var longestUnchanged = 0.0
        let watchUntil = elapsed() + 9
        while elapsed() < watchUntil {
            let playlist = await fetch(playlistURL)
            if player.read(String(decoding: playlist.body, as: UTF8.self)) { lastChange = elapsed() }
            longestUnchanged = max(longestUnchanged, elapsed() - lastChange)
            segments.append(player.entries.count)
            let start = player.entries.values.map(\.start).min()
            session.reportPlayback(programmeTime: start, isWaiting: false, isPlaying: false, rate: 1)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        #expect(longestUnchanged < 1.5 * player.targetDuration)
        #expect((segments.last ?? 0) >= (segments.first ?? 0) + 3)
    }

    @Test("Native output hands the renderer the first segment at once, every segment once and in order, and restarts at a keyframe")
    func nativeOutput() async throws {
        // A provider that bursts only 3 s on connect: the HLS publication would wait for 6 s.
        var stream = SyntheticTransportStream()
        stream.parameterSets = [EncoderSamples.avcHighSPS, EncoderSamples.avcHighPPS]
        let channel = try FakeTransportChannel(seconds: 40, lead: 16, burst: 3, streams: [(0, stream)])
        defer { channel.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(channel.port)/play/1234.ts"))
        var configuration = StreamEngineConfiguration.profile(.balanced)
        configuration.nativeOutput = true
        let recorder = EngineEventRecorder()
        let session = try StreamEngine.shared.makeSession(routes: [.init(url: url, label: "MPEG-TS")], headers: [:],
                                                          configuration: configuration, isSingleConnectionAccount: false,
                                                          onEvent: { recorder.record($0) })
        let received = NativeItemCollector()
        session.nativeFeed.setListener { [feed = session.nativeFeed] in received.take(feed.drain()) }
        session.start()
        defer { session.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }
        while recorder.ready == nil, elapsed() < 10 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(recorder.ready != nil)
        #expect(elapsed() < 2)

        // A renderer playing in real time: the engine keeps handing over what's ahead of it.
        while elapsed() < 6 {
            let segments = received.segments
            if let first = segments.first {
                let position = first.programmeStart + max(0, elapsed() - 1)
                session.reportPlayback(programmeTime: position, isWaiting: false, isPlaying: true, rate: 1)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let segments = received.segments
        #expect(segments.count >= 3)
        #expect(segments.first?.startsWithKeyframe == true)
        #expect(segments.map(\.sequence) == Array((segments.first?.sequence ?? 0)..<((segments.first?.sequence ?? 0) + segments.count)))
        let samples = segments.compactMap(\.samples.video).flatMap(\.samples)
        let frames = samples.compactMap { SyntheticTransportStream.picture(inSample: [UInt8]($0.data)[...])?.frame }
        #expect(frames == Array((frames.first ?? 0)..<((frames.first ?? 0) + frames.count)))
        #expect(segments.allSatisfy { !$0.samples.audio.isEmpty })

        // A renderer restart: flush, then the segments from the keyframe at or before the position again.
        received.reset()
        let position = (segments.last?.programmeStart ?? 0) + 0.5
        session.reportPlayback(programmeTime: position, isWaiting: false, isPlaying: true, rate: 1)
        session.noteDecoderReset()
        let restartedAt = elapsed()
        while received.items.isEmpty, elapsed() - restartedAt < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
        let items = received.items
        guard case .restart(let time)? = items.first else {
            Issue.record("the feed didn't start with a restart")
            return
        }
        #expect(time >= position - 0.01)
        guard case .segment(let joined)? = items.dropFirst().first else {
            Issue.record("no segment after the restart")
            return
        }
        #expect(joined.startsWithKeyframe && joined.programmeStart <= time)
    }

    @Test("The first playlist holds three target durations: AVPlayer starts a live playlist that far behind its end")
    func firstPlaylistDepth() async throws {
        // A panel's usual burst on connect, then programme in real time.
        let channel = try FakeTransportChannel(seconds: 30, lead: 16, burst: 7)
        defer { channel.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(channel.port)/play/1234.ts"))
        let recorder = EngineEventRecorder()
        let session = try StreamEngine.shared.makeSession(routes: [.init(url: url, label: "MPEG-TS")], headers: [:],
                                                          configuration: .profile(.balanced), isSingleConnectionAccount: false,
                                                          onEvent: { recorder.record($0) })
        session.start()
        defer { session.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        while recorder.ready == nil, ProcessInfo.processInfo.systemUptime - started < 10 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let playlist = await fetch(try #require(recorder.ready))
        var player = VirtualPlayer(epoch: session.programmeEpoch)
        player.read(String(decoding: playlist.body, as: UTF8.self))
        let listed = player.entries.values.reduce(0) { $0 + $1.duration }
        #expect(listed >= 3 * player.targetDuration - 0.05)
    }

    @Test("A channel that switches from H.264 to HEVC moves the player to fMP4 renditions")
    func codecSwitch() async throws {
        var hevc = SyntheticTransportStream(content: 1)
        hevc.videoStreamType = 0x24
        hevc.parameterSets = EncoderSamples.pq
        let channel = try FakeTransportChannel(seconds: 60, lead: 16, burst: 12,
                                               streams: [(0, SyntheticTransportStream()), (20, hevc)])
        defer { channel.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(channel.port)/play/1234.ts"))
        let run = try await play(routes: [.init(url: url, label: "MPEG-TS")], profile: .fast, seconds: 18)

        #expect(run.failure == nil)
        // MPEG-TS played first; the player was moved once, to the fMP4 renditions.
        #expect(run.replaced.count == 1)
        let before = try #require(run.replaced.first)
        #expect(!before.downloaded.isEmpty)
        #expect(before.downloaded.allSatisfy { $0.data.first == 0x47 })
        #expect(run.multivariant?.contains("CODECS=\"hvc1.2.4.L153.90,mp4a.40.2\"") == true)
        let fragments = expectFragmentedTimeline(run.player, maximumMissing: 0)
        let encoders = Set(fragments.flatMap { $0.sampleData.compactMap { SyntheticTransportStream.picture(inSample: $0)?.content } })
        #expect(encoders == [1])
        #expect(run.player.freezes == 0)
    }

    @Test("A channel whose MPEG-TS output drops programme moves to the panel's HLS output, which carries all of it",
          arguments: [
            // Every eighth 0.4 s chunk of the raw stream never arrives, like a panel whose MPEG-TS
            // output can't keep up with a 4K channel; its HLS output of the same programme is whole.
            // One of them holds the keyframe the HLS output's window starts the move at.
            (Set(stride(from: 7, to: 150, by: 8)), 12.0, 60),
            // 2.4 s of every 8 go missing, too long to close up on the spot: each is a timeline jump,
            // and each costs the reserve its length; a 20 s burst (panels send 5–23 s) leaves enough.
            (Set(stride(from: 3, to: 150, by: 20).flatMap { $0..<($0 + 6) }), 20.0, 200)
          ])
    func lossyTransportStream(drops: Set<Int>, burst: Double, maximumMissing: Int) async throws {
        let transport = try FakeTransportChannel(seconds: 60, lead: 24, burst: burst, drops: drops)
        defer { transport.stop() }
        // As on the live panel, the HLS output runs a few seconds ahead of an MPEG-TS output that
        // falls behind like this, and a 4K segment takes a while to fetch.
        let hls = try FakeHLSChannel(seconds: 60, lead: 28, segmentDelay: 0.5)
        defer { hls.stop() }
        let routes: [StreamEngineSession.Route] = [
            .init(url: try #require(URL(string: "http://127.0.0.1:\(transport.port)/live/user/pass/77.ts")), label: "MPEG-TS"),
            .init(url: try #require(URL(string: "http://127.0.0.1:\(hls.port)/live/user/pass/77.m3u8")), label: "HLS")
        ]
        let run = try await play(routes: routes, profile: .balanced, seconds: 20)

        #expect(run.failure == nil)
        let status = try #require(run.status)
        #expect(status.route == "HLS")
        #expect(status.routeSwitches == 1)
        #expect(run.player.freezes == 0)
        #expect(!run.player.sawDiscontinuity)
        // What the raw stream dropped in its burst was closed up, never held as a frozen picture:
        // decode times run one frame apart throughout, and from the move on the programme is whole.
        expectOneTimeline(run.player, maximumMissing: maximumMissing)
    }

    /// The pictures the player received form one timeline: decode times one frame apart, no
    /// picture twice, and at most `maximumMissing` source pictures skipped.
    private func expectOneTimeline(_ player: VirtualPlayer, maximumMissing: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        let bytes = player.downloaded.flatMap { [UInt8]($0.data) }
        let pictures = pesUnits(in: bytes, pid: 0x100)
        let frames = pictures.compactMap { SyntheticTransportStream.picture(in: $0)?.frame }
        let times = pictures.compactMap { $0.parseHeader().flatMap { $0.dts ?? $0.pts } }
        #expect(frames.count > 150, sourceLocation: sourceLocation)
        let increasing = zip(frames.dropFirst(), frames).allSatisfy { $0 > $1 }
        #expect(increasing, sourceLocation: sourceLocation)
        let steps = Set(zip(times.dropFirst(), times).map { MPEGTS.signedDelta($0, $1) })
        #expect(steps == [3_600], sourceLocation: sourceLocation)
        if let first = frames.first, let last = frames.last {
            #expect(last - first + 1 - frames.count <= maximumMissing, "\(last - first + 1 - frames.count) pictures missing",
                    sourceLocation: sourceLocation)
        }
    }

    /// The fMP4 fragments the player received form one timeline: decode times unbroken from
    /// fragment to fragment, no picture twice, and at most `maximumMissing` source pictures skipped.
    @discardableResult
    private func expectFragmentedTimeline(_ player: VirtualPlayer, maximumMissing: Int,
                                          sourceLocation: SourceLocation = #_sourceLocation) -> [ParsedFragment] {
        let fragments = player.downloaded.compactMap { ParsedFragment($0.data) }
        #expect(fragments.count == player.downloaded.count, "fragments that don't parse", sourceLocation: sourceLocation)
        expectContinuous(fragments, sourceLocation: sourceLocation)
        let frames = fragments.flatMap { $0.sampleData.compactMap { SyntheticTransportStream.picture(inSample: $0)?.frame } }
        #expect(frames.count > 150, sourceLocation: sourceLocation)
        let increasing = zip(frames.dropFirst(), frames).allSatisfy { $0 > $1 }
        #expect(increasing, sourceLocation: sourceLocation)
        if let first = frames.first, let last = frames.last {
            #expect(last - first + 1 - frames.count <= maximumMissing, "\(last - first + 1 - frames.count) pictures missing",
                    sourceLocation: sourceLocation)
        }
        return fragments
    }

    private struct Run {
        var player: VirtualPlayer
        /// Players the engine moved off their endpoint, oldest first.
        var replaced: [VirtualPlayer]
        /// Fragmented MP4 sessions: the multivariant playlist, a player per audio rendition and
        /// the initialization sections fetched, by name.
        var multivariant: String?
        var audioPlayers: [VirtualPlayer]
        var initializations: [String: Data]
        /// The last video (or only) media playlist read.
        var lastPlaylist: String
        var status: StreamEngineStatus?
        var failure: StreamEngineFailure?
        /// Seconds from start to the first published segment.
        var startup: Double
    }

    /// Plays `routes` through a real engine session, with a virtual player on the local playlist.
    private func play(routes: [StreamEngineSession.Route], profile: StreamEngineConfiguration.Profile,
                      seconds: Double, readyWithin: Double = 10) async throws -> Run {
        let recorder = EngineEventRecorder()
        let session = try StreamEngine.shared.makeSession(routes: routes, headers: [:], configuration: .profile(profile),
                                                          isSingleConnectionAccount: false, onEvent: { recorder.record($0) })
        session.start()
        defer { session.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }

        while recorder.ready == nil, recorder.failure == nil, elapsed() < readyWithin {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        var playlistURL = try #require(recorder.ready)
        let startup = elapsed()
        var media = await resolve(playlistURL)
        var player = VirtualPlayer(epoch: session.programmeEpoch)
        var audioPlayers = media.audio.map { _ in VirtualPlayer(epoch: session.programmeEpoch) }
        var replaced: [VirtualPlayer] = []
        var initializations: [String: Data] = [:]
        var lastPlaylist = ""
        var endpointChanges = recorder.endpointChanges
        var nextReload = 0.0
        let end = elapsed() + seconds
        while elapsed() < end, recorder.failure == nil {
            if recorder.endpointChanges != endpointChanges, let url = recorder.ready {
                // Like the app: a fresh player item on the new endpoint, joining where it says.
                endpointChanges = recorder.endpointChanges
                session.noteDecoderReset()
                playlistURL = url
                media = await resolve(url)
                replaced.append(player)
                player = VirtualPlayer(epoch: session.programmeEpoch)
                audioPlayers = media.audio.map { _ in VirtualPlayer(epoch: session.programmeEpoch) }
                nextReload = 0
            }
            if elapsed() >= nextReload {
                // Like AVPlayer: a target duration after a playlist that changed, half of one otherwise.
                let base = playlistURL.deletingLastPathComponent()
                let playlist = await fetch(media.video)
                if playlist.status == 200 { lastPlaylist = String(decoding: playlist.body, as: UTF8.self) }
                let changed = playlist.status == 200 && player.read(lastPlaylist)
                nextReload = elapsed() + (changed ? player.targetDuration : player.targetDuration / 2)
                await download(&player, base: base, initializations: &initializations)
                for (index, url) in media.audio.enumerated() {
                    let audio = await fetch(url)
                    if audio.status == 200 { audioPlayers[index].read(String(decoding: audio.body, as: UTF8.self)) }
                    await download(&audioPlayers[index], base: base, initializations: &initializations)
                }
            }
            let rate = recorder.rate
            player.advance(by: 0.1, rate: rate)
            session.reportPlayback(programmeTime: player.position, isWaiting: player.isWaiting, isPlaying: player.isPlaying, rate: rate)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return Run(player: player, replaced: replaced, multivariant: media.multivariant, audioPlayers: audioPlayers,
                   initializations: initializations, lastPlaylist: lastPlaylist, status: recorder.status, failure: recorder.failure,
                   startup: startup)
    }

    /// What a player item on `url` plays: that media playlist, or a multivariant playlist's video
    /// variant and audio renditions.
    private func resolve(_ url: URL) async -> (video: URL, audio: [URL], multivariant: String?) {
        let top = await fetch(url)
        let text = String(decoding: top.body, as: UTF8.self)
        guard text.contains("#EXT-X-STREAM-INF:") else { return (url, [], nil) }
        let base = url.deletingLastPathComponent()
        let lines = text.split(separator: "\n").map(String.init)
        var video = url
        if let index = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }), index + 1 < lines.count {
            video = base.appendingPathComponent(lines[index + 1])
        }
        let audio = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO,") }.compactMap { line -> URL? in
            guard let range = line.range(of: "URI=\"") else { return nil }
            return base.appendingPathComponent(String(line[range.upperBound...].prefix { $0 != "\"" }))
        }
        return (video, audio, text)
    }

    /// Fetches what `player` plays next, in order, with each initialization section before the
    /// first segment that needs it.
    private func download(_ player: inout VirtualPlayer, base: URL, initializations: inout [String: Data]) async {
        while let next = player.nextSequence, let entry = player.entries[next] {
            if let map = entry.map, initializations[map] == nil {
                let section = await fetch(base.appendingPathComponent(map))
                guard section.status == 200 else { return }
                initializations[map] = section.body
            }
            let segment = await fetch(base.appendingPathComponent(entry.uri))
            guard segment.status == 200 else { return }
            player.received(segment.body, sequence: next)
        }
    }
}

// MARK: - Test doubles

/// AVPlayer reduced to what matters here: join where the playlist says, fetch segments in order,
/// play them at the engine's pace, and freeze when they run out.
struct VirtualPlayer {
    struct Entry {
        let start: Double
        let duration: Double
        let uri: String
        /// The initialization section it plays after (fragmented MP4).
        let map: String?
    }

    let epoch: Date
    private(set) var targetDuration: Double = 4
    private(set) var entries: [Int: Entry] = [:]
    private(set) var downloaded: [(sequence: Int, data: Data)] = []
    private(set) var position: Double?
    private(set) var isPlaying = false
    private(set) var freezes = 0
    private(set) var sawDiscontinuity = false
    private var joinSequence: Int?

    init(epoch: Date) {
        self.epoch = epoch
    }

    /// Reads the local playlist; true when it lists a segment it didn't before.
    @discardableResult
    mutating func read(_ playlist: String) -> Bool {
        let previousLast = entries.keys.max()
        var date: Date?
        var duration = 0.0
        var startOffset = 0.0
        var map: String?
        var window: [Int] = []
        for line in playlist.split(separator: "\n").map(String.init) {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? targetDuration
            } else if line.hasPrefix("#EXT-X-START:TIME-OFFSET=") {
                startOffset = Double(line.dropFirst("#EXT-X-START:TIME-OFFSET=".count).split(separator: ",")[0]) ?? 0
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                date = Self.date(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)))
            } else if line.hasPrefix("#EXTINF:") {
                duration = Double(line.dropFirst("#EXTINF:".count).split(separator: ",")[0]) ?? 0
            } else if line == "#EXT-X-DISCONTINUITY" {
                sawDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-MAP:URI=\"") {
                map = String(line.dropFirst("#EXT-X-MAP:URI=\"".count).prefix { $0 != "\"" })
            } else if !line.hasPrefix("#"), !line.isEmpty, let sequence = Self.sequence(of: line), let date {
                entries[sequence] = Entry(start: date.timeIntervalSince(epoch), duration: duration, uri: line, map: map)
                window.append(sequence)
            }
        }
        if joinSequence == nil, let first = window.first, let firstStart = entries[first]?.start {
            let target = firstStart + startOffset
            joinSequence = window.last { (entries[$0]?.start ?? .infinity) <= target + 0.001 } ?? first
        }
        return entries.keys.max() != previousLast
    }

    /// The media sequence number a segment's name ends with: s12.ts, v12.m4s, a1-12.m4s.
    static func sequence(of uri: String) -> Int? {
        let name = uri.split(separator: ".").first.map(String.init) ?? uri
        return Int(String(name.reversed().prefix { $0.isNumber }.reversed()))
    }

    /// The next segment to fetch, once the playlist lists it.
    var nextSequence: Int? {
        guard let next = downloaded.last.map({ $0.sequence + 1 }) ?? joinSequence, entries[next] != nil else { return nil }
        return next
    }

    mutating func received(_ data: Data, sequence: Int) {
        downloaded.append((sequence, data))
        if position == nil { position = entries[sequence]?.start }
    }

    mutating func advance(by seconds: Double, rate: Double) {
        guard let position, let last = downloaded.last, let entry = entries[last.sequence] else { return }
        let end = entry.start + entry.duration
        if position < end - 0.04 {
            isPlaying = true
            self.position = min(end, position + seconds * rate)
        } else if isPlaying {
            isPlaying = false
            freezes += 1
        }
    }

    var isWaiting: Bool { position != nil && !isPlaying }

    /// 2026-10-20T16:46:14.138Z
    static func date(_ text: String) -> Date? {
        guard text.hasSuffix("Z") else { return nil }
        let parts = text.dropLast().split { "-T:".contains($0) }
        guard parts.count == 6, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hour = Int(parts[3]), let minute = Int(parts[4]), let second = Double(parts[5]),
              let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        return calendar.date(from: components)?.addingTimeInterval(second)
    }
}

final class EngineEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var readyURL: URL?
    private var endpointChangeCount = 0
    private var latestRate = 1.0
    private var latestStatus: StreamEngineStatus?
    private var latestFailure: StreamEngineFailure?

    func record(_ event: StreamEngineSession.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .ready(let url): readyURL = url
        case .endpointChanged(let url):
            readyURL = url
            endpointChangeCount += 1
        case .status(let status): latestStatus = status
        case .pace(let rate): latestRate = rate
        case .failed(let failure): latestFailure = failure
        case .decoderResetRequested, .nativeOutputUnsupported: break
        }
    }

    private func read<T>(_ value: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return value()
    }

    var ready: URL? { read { readyURL } }
    var endpointChanges: Int { read { endpointChangeCount } }
    var rate: Double { read { latestRate } }
    var status: StreamEngineStatus? { read { latestStatus } }
    var failure: StreamEngineFailure? { read { latestFailure } }
}

func fetch(_ url: URL, headers: [String: String] = [:]) async -> (status: Int, body: Data, headers: [String: String]) {
    await withCheckedContinuation { continuation in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            var fields: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                fields[String(describing: key).lowercased()] = String(describing: value)
            }
            continuation.resume(returning: (http?.statusCode ?? 0, data ?? Data(), fields))
        }.resume()
    }
}

/// A live channel served the way IPTV panels serve raw MPEG-TS: one endless HTTP response that
/// starts with a burst of the programme the server buffered (joining mid-packet), then carries
/// on in real time. Chosen connections are cut a few seconds in, in the middle of a packet.
final class FakeTransportChannel: @unchecked Sendable {
    private let chunks: [[UInt8]]
    private let chunkSeconds = 0.4
    /// Programme the panel holds when the test starts.
    private let lead: Double
    private let burst: Double
    /// Connection index → seconds after which that connection is cut.
    private let cuts: [Int: Double]
    /// Chunks the panel never sends: programme its output dropped.
    private let drops: Set<Int>
    /// The status every request gets; anything but 200 comes with an empty body (502 for a
    /// channel that's off the air).
    private let answer: Int
    /// Seconds the panel takes to answer, counted from the first request: an on-demand source that
    /// nobody else is watching has to be started first.
    private let startupDelay: Double
    /// Answers 200 and then sends nothing: a channel whose source is down.
    private let silent: Bool
    private var firstRequestAt: Double?
    private let origin = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var listener: Int32
    private var running = true
    private var connections = 0
    let port: UInt16

    enum ProviderError: Error { case socket }

    /// `streams` are the encoders of the programme, each from the second it takes over.
    init(seconds: Double, lead: Double, burst: Double, cuts: [Int: Double] = [:], drops: Set<Int> = [],
         answer: Int = 200, startupDelay: Double = 0, silent: Bool = false,
         streams: [(start: Double, stream: SyntheticTransportStream)] = [(0, SyntheticTransportStream())]) throws {
        var encoders = streams
        chunks = (0..<Int(seconds / 0.4)).map { index in
            let current = encoders.lastIndex { $0.start <= Double(index) * 0.4 + 0.001 } ?? 0
            return encoders[current].stream.bytes(seconds: 0.4, firstFrame: index * 10)
        }
        self.lead = lead
        self.burst = burst
        self.cuts = cuts
        self.drops = drops
        self.answer = answer
        self.startupDelay = startupDelay
        self.silent = silent
        listener = try Self.makeListener()
        port = Self.localPort(of: listener)
        let thread = Thread { [self] in acceptLoop() }
        thread.start()
    }

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections
    }

    func stop() {
        lock.lock()
        running = false
        let socket = listener
        listener = -1
        lock.unlock()
        if socket >= 0 {
            _ = shutdown(socket, Int32(SHUT_RDWR))
            _ = close(socket)
        }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - origin }

    private func acceptLoop() {
        while isRunning {
            lock.lock()
            let socket = listener
            lock.unlock()
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard socket >= 0, poll(&descriptor, 1, 200) > 0 else { continue }
            let client = accept(socket, nil, nil)
            guard client >= 0 else { continue }
            lock.lock()
            let index = connections
            connections += 1
            lock.unlock()
            let thread = Thread { [self] in
                serve(client, index: index)
                _ = close(client)
            }
            thread.start()
        }
    }

    private func serve(_ client: Int32, index: Int) {
        Self.configure(client)
        guard readRequestHead(client) else { return }
        if startupDelay > 0 {
            lock.lock()
            let first = firstRequestAt ?? elapsed()
            firstRequestAt = first
            lock.unlock()
            while isRunning, elapsed() < first + startupDelay { Thread.sleep(forTimeInterval: 0.02) }
        }
        guard answer == 200 else {
            _ = write(Array("HTTP/1.1 \(answer) Off Air\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: client)
            return
        }
        guard write(Array("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n".utf8), to: client) else { return }
        if silent {
            var probe: UInt8 = 0
            // Hold the connection open until the client gives up on it.
            while isRunning, recv(client, &probe, 1, Int32(MSG_DONTWAIT)) != 0 { Thread.sleep(forTimeInterval: 0.05) }
            return
        }
        let openedAt = elapsed()
        var chunk = max(0, Int((lead + openedAt - burst) / chunkSeconds))
        // A panel's buffer rarely starts on a packet boundary.
        var offset = 61
        while isRunning, chunk < chunks.count {
            let available = min(chunks.count, Int((lead + elapsed()) / chunkSeconds))
            while chunk < available {
                guard drops.contains(chunk) || write(chunks[chunk][offset...], to: client) else { return }
                chunk += 1
                offset = 0
            }
            if let cut = cuts[index], elapsed() - openedAt >= cut {
                if chunk < chunks.count { _ = write(chunks[chunk][0..<94], to: client) }
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func readRequestHead(_ client: Int32) -> Bool {
        var head: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while head.count < 16_384 {
            let count = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return false }
            head += buffer[0..<count]
            if LoopbackHTTPServer.headerTerminator(in: head) != nil { return true }
        }
        return false
    }

    private func write<C: Collection>(_ bytes: C, to client: Int32) -> Bool where C.Element == UInt8 {
        let data = Array(bytes)
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                #if canImport(Darwin)
                return send(client, base + offset, raw.count - offset, 0)
                #else
                return send(client, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #endif
            }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }

    private static func makeListener() throws -> Int32 {
        #if canImport(Darwin)
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        let socket = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard socket >= 0 else { throw ProviderError.socket }
        var on: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socket, 8) == 0 else {
            _ = close(socket)
            throw ProviderError.socket
        }
        return socket
    }

    private static func localPort(of socket: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : 0
    }

    private static func configure(_ client: Int32) {
        var on: Int32 = 1
        #if canImport(Darwin)
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}

/// An Xtream panel's outputs for one channel: `.ts` isn't offered (404), the HLS output is a live
/// playlist of 2 s segments over a 20 s sliding window, and during `outage` every HLS request fails.
final class FakeHLSChannel: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let segments: [Data]
        let lead: Double
        let outage: Range<Double>?
        /// Seconds each segment takes to arrive.
        let segmentDelay: Double
        /// The status playlists and segments get (502 for a channel that's off the air).
        let answer: Int
        let origin = ProcessInfo.processInfo.systemUptime
        private let lock = NSLock()
        private var transportCount = 0
        private var playlistCount = 0
        private var segmentLog: [(time: Double, sequence: Int)] = []

        init(segments: [Data], lead: Double, outage: Range<Double>?, segmentDelay: Double, answer: Int) {
            self.segments = segments
            self.lead = lead
            self.outage = outage
            self.segmentDelay = segmentDelay
            self.answer = answer
        }

        var playlistRequests: Int {
            lock.lock()
            defer { lock.unlock() }
            return playlistCount
        }

        var transportRequests: Int {
            lock.lock()
            defer { lock.unlock() }
            return transportCount
        }

        var segmentRequests: [(time: Double, sequence: Int)] {
            lock.lock()
            defer { lock.unlock() }
            return segmentLog
        }

        func respond(to request: LoopbackHTTPServer.Request) -> LoopbackHTTPServer.Response {
            let now = ProcessInfo.processInfo.systemUptime - origin
            let name = request.path.split(separator: "/").last.map(String.init) ?? ""
            if name == "77.ts" {
                lock.lock()
                transportCount += 1
                lock.unlock()
                return .notFound()
            }
            if name == "77.m3u8" {
                lock.lock()
                playlistCount += 1
                lock.unlock()
            }
            if answer != 200 { return .init(status: answer, contentType: "text/plain", body: Data()) }
            if outage?.contains(now) == true { return .unavailable() }
            let available = max(0, min(segments.count, Int((lead + now) / 2)))
            if name == "77.m3u8" {
                let first = max(0, available - 10)
                var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:\(first)"]
                for sequence in first..<available { lines += ["#EXTINF:2.000,", "seg\(sequence).ts"] }
                return .init(status: 200, contentType: "application/vnd.apple.mpegurl", body: Data((lines.joined(separator: "\n") + "\n").utf8))
            }
            if name.hasPrefix("seg"), name.hasSuffix(".ts"), let sequence = Int(name.dropFirst(3).dropLast(3)), sequence < available {
                lock.lock()
                segmentLog.append((now, sequence))
                lock.unlock()
                if segmentDelay > 0 { Thread.sleep(forTimeInterval: segmentDelay) }
                return .init(status: 200, contentType: "video/mp2t", body: segments[sequence])
            }
            return .notFound()
        }
    }

    private let state: State
    private let server: LoopbackHTTPServer
    let port: UInt16

    init(seconds: Double, lead: Double, outage: Range<Double>? = nil, segmentDelay: Double = 0, answer: Int = 200,
         stream: SyntheticTransportStream = SyntheticTransportStream()) throws {
        var stream = stream
        let segments = (0..<Int(seconds / 2)).map { Data(stream.bytes(seconds: 2, firstFrame: $0 * 50)) }
        let state = State(segments: segments, lead: lead, outage: outage, segmentDelay: segmentDelay, answer: answer)
        self.state = state
        server = LoopbackHTTPServer { request in state.respond(to: request) }
        port = try server.start()
    }

    var transportRequests: Int { state.transportRequests }
    var playlistRequests: Int { state.playlistRequests }
    /// Segments served, with the channel time each was requested at.
    var segmentRequests: [(time: Double, sequence: Int)] { state.segmentRequests }

    func stop() { server.stop() }
}

/// What a native renderer would have been handed, in order.
final class NativeItemCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [NativeFeed.Item] = []

    func take(_ items: [NativeFeed.Item]) {
        lock.lock()
        collected += items
        lock.unlock()
    }

    func reset() {
        lock.lock()
        collected.removeAll()
        lock.unlock()
    }

    var items: [NativeFeed.Item] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var segments: [NativeFeed.Segment] {
        items.compactMap { if case .segment(let segment) = $0 { return segment } else { return nil } }
    }
}
