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

    private struct Run {
        var player: VirtualPlayer
        var status: StreamEngineStatus?
        var failure: StreamEngineFailure?
        /// Seconds from start to the first published segment.
        var startup: Double
    }

    /// Plays `routes` through a real engine session, with a virtual player on the local playlist.
    private func play(routes: [StreamEngineSession.Route], profile: StreamEngineConfiguration.Profile,
                      seconds: Double) async throws -> Run {
        let recorder = EngineEventRecorder()
        let session = try StreamEngine.shared.makeSession(routes: routes, headers: [:], configuration: .profile(profile),
                                                          isSingleConnectionAccount: false, onEvent: { recorder.record($0) })
        session.start()
        defer { session.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Double { ProcessInfo.processInfo.systemUptime - started }

        while recorder.ready == nil, recorder.failure == nil, elapsed() < 10 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let playlistURL = try #require(recorder.ready)
        let startup = elapsed()
        var player = VirtualPlayer(epoch: session.programmeEpoch)
        var nextReload = 0.0
        let end = elapsed() + seconds
        while elapsed() < end, recorder.failure == nil {
            if elapsed() >= nextReload {
                // Like AVPlayer: a target duration after a playlist that changed, half of one otherwise.
                let playlist = await fetch(playlistURL)
                let changed = playlist.status == 200 && player.read(String(decoding: playlist.body, as: UTF8.self))
                nextReload = elapsed() + (changed ? player.targetDuration : player.targetDuration / 2)
                while let next = player.nextSequence {
                    let segment = await fetch(playlistURL.deletingLastPathComponent().appendingPathComponent("s\(next).ts"))
                    guard segment.status == 200 else { break }
                    player.received(segment.body, sequence: next)
                }
            }
            let rate = recorder.rate
            player.advance(by: 0.1, rate: rate)
            session.reportPlayback(programmeTime: player.position, isWaiting: player.isWaiting, isPlaying: player.isPlaying, rate: rate)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return Run(player: player, status: recorder.status, failure: recorder.failure, startup: startup)
    }
}

// MARK: - Test doubles

/// AVPlayer reduced to what matters here: join where the playlist says, fetch segments in order,
/// play them at the engine's pace, and freeze when they run out.
struct VirtualPlayer {
    struct Entry {
        let start: Double
        let duration: Double
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
            } else if line.hasPrefix("s"), line.hasSuffix(".ts"), let sequence = Int(line.dropFirst().dropLast(3)), let date {
                entries[sequence] = Entry(start: date.timeIntervalSince(epoch), duration: duration)
                window.append(sequence)
            }
        }
        if joinSequence == nil, let first = window.first, let firstStart = entries[first]?.start {
            let target = firstStart + startOffset
            joinSequence = window.last { (entries[$0]?.start ?? .infinity) <= target + 0.001 } ?? first
        }
        return entries.keys.max() != previousLast
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
    private var latestRate = 1.0
    private var latestStatus: StreamEngineStatus?
    private var latestFailure: StreamEngineFailure?

    func record(_ event: StreamEngineSession.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .ready(let url), .endpointChanged(let url): readyURL = url
        case .status(let status): latestStatus = status
        case .pace(let rate): latestRate = rate
        case .failed(let failure): latestFailure = failure
        case .decoderResetRequested: break
        }
    }

    private func read<T>(_ value: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return value()
    }

    var ready: URL? { read { readyURL } }
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
    private let origin = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var listener: Int32
    private var running = true
    private var connections = 0
    let port: UInt16

    enum ProviderError: Error { case socket }

    init(seconds: Double, lead: Double, burst: Double, cuts: [Int: Double] = [:]) throws {
        var stream = SyntheticTransportStream()
        chunks = (0..<Int(seconds / 0.4)).map { stream.bytes(seconds: 0.4, firstFrame: $0 * 10) }
        self.lead = lead
        self.burst = burst
        self.cuts = cuts
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
        guard readRequestHead(client),
              write(Array("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nConnection: close\r\n\r\n".utf8), to: client) else { return }
        let openedAt = elapsed()
        var chunk = max(0, Int((lead + openedAt - burst) / chunkSeconds))
        // A panel's buffer rarely starts on a packet boundary.
        var offset = 61
        while isRunning, chunk < chunks.count {
            let available = min(chunks.count, Int((lead + elapsed()) / chunkSeconds))
            while chunk < available {
                guard write(chunks[chunk][offset...], to: client) else { return }
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
        let origin = ProcessInfo.processInfo.systemUptime
        private let lock = NSLock()
        private var transportCount = 0
        private var segmentLog: [(time: Double, sequence: Int)] = []

        init(segments: [Data], lead: Double, outage: Range<Double>?) {
            self.segments = segments
            self.lead = lead
            self.outage = outage
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
            if outage?.contains(now) == true { return .unavailable() }
            let available = min(segments.count, Int((lead + now) / 2))
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
                return .init(status: 200, contentType: "video/mp2t", body: segments[sequence])
            }
            return .notFound()
        }
    }

    private let state: State
    private let server: LoopbackHTTPServer
    let port: UInt16

    init(seconds: Double, lead: Double, outage: Range<Double>? = nil) throws {
        var stream = SyntheticTransportStream()
        let segments = (0..<Int(seconds / 2)).map { Data(stream.bytes(seconds: 2, firstFrame: $0 * 50)) }
        let state = State(segments: segments, lead: lead, outage: outage)
        self.state = state
        server = LoopbackHTTPServer { request in state.respond(to: request) }
        port = try server.start()
    }

    var transportRequests: Int { state.transportRequests }
    /// Segments served, with the channel time each was requested at.
    var segmentRequests: [(time: Double, sequence: Int)] { state.segmentRequests }

    func stop() { server.stop() }
}
