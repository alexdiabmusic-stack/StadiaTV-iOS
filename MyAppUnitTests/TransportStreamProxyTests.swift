import Foundation
import Testing
@testable import BannerTV
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Helpers

/// A plain GET (or other method) against a local URL, with no caching and no proxy in the way.
private func request(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (status: Int, headers: [String: String], body: Data) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: configuration)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (body, response) = try await session.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    var fields: [String: String] = [:]
    for (name, value) in http.allHeaderFields { fields["\(name)".lowercased()] = "\(value)" }
    return (http.statusCode, fields, body)
}

private func segment(_ sequence: Int, seconds: Double = 2, discontinuity: Bool = false) -> HLSSegmenter.Segment {
    HLSSegmenter.Segment(sequence: sequence, data: Data("segment \(sequence)".utf8), duration: seconds, discontinuity: discontinuity)
}

// MARK: - The playlist and segments

@Suite("HLS segment store")
struct HLSSegmentStoreTests {

    @Test("The playlist is held back until there is a cushion to start from")
    func startsWithACushion() {
        let store = HLSSegmentStore()
        #expect(store.playlist(timeout: 0.02) == .timedOut)
        store.add([segment(0), segment(1)])
        #expect(store.playlist(timeout: 0.02) == .timedOut, "two short segments are not enough")
        store.add([segment(2)])
        guard case .playlist = store.playlist(timeout: 0.02) else { Issue.record("three segments should be enough"); return }

        let long = HLSSegmentStore()
        long.add([segment(0, seconds: 4), segment(1, seconds: 4)])
        guard case .playlist = long.playlist(timeout: 0.02) else { Issue.record("two segments covering 8 s should be enough"); return }
    }

    @Test("The playlist is the live kind: a window that slides, numbered from its first segment")
    func slidingWindow() {
        let store = HLSSegmentStore()
        store.add((0..<3).map { segment($0) })
        guard case .playlist(let first) = store.playlist(timeout: 0.1) else { Issue.record("no playlist"); return }
        #expect(first == """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:3
            #EXT-X-MEDIA-SEQUENCE:0
            #EXTINF:2.000,
            segment0.ts
            #EXTINF:2.000,
            segment1.ts
            #EXTINF:2.000,
            segment2.ts

            """)
        #expect(!first.contains("ENDLIST"), "a live stream never ends")

        store.add((3..<10).map { segment($0) })
        guard case .playlist(let later) = store.playlist(timeout: 0.1) else { Issue.record("no playlist"); return }
        let listed = later.split(separator: "\n").filter { $0.hasSuffix(".ts") }.map(String.init)
        #expect(listed == ["segment5.ts", "segment6.ts", "segment7.ts", "segment8.ts", "segment9.ts"], "the last five")
        #expect(later.contains("#EXT-X-MEDIA-SEQUENCE:5"))
    }

    @Test("Segments are kept a little longer than they are listed, then let go")
    func retention() {
        let store = HLSSegmentStore()
        store.add((0..<12).map { segment($0) })
        #expect(store.segment(sequence: 3) == nil, "gone")
        #expect(store.segment(sequence: 4) == Data("segment 4".utf8), "the eight most recent are kept")
        #expect(store.segment(sequence: 11) != nil)
        #expect(store.segmentCount == 8)
    }

    @Test("The target duration is a promise, so it only goes up")
    func targetDuration() {
        let store = HLSSegmentStore()
        store.add([segment(0), segment(1), segment(2)])
        guard case .playlist(let first) = store.playlist(timeout: 0.1) else { return }
        #expect(first.contains("#EXT-X-TARGETDURATION:3"))
        store.add([segment(3, seconds: 5.2)])
        guard case .playlist(let longer) = store.playlist(timeout: 0.1) else { return }
        #expect(longer.contains("#EXT-X-TARGETDURATION:7"))
        store.add((4..<12).map { segment($0) })   // the long segment has left the window
        guard case .playlist(let after) = store.playlist(timeout: 0.1) else { return }
        #expect(after.contains("#EXT-X-TARGETDURATION:7"), "not lowered again")
    }

    @Test("A break in the stream is marked, and counted once it has left the window")
    func discontinuities() {
        let store = HLSSegmentStore()
        store.add([segment(0), segment(1), segment(2, discontinuity: true), segment(3)])
        guard case .playlist(let marked) = store.playlist(timeout: 0.1) else { return }
        let lines = marked.split(separator: "\n").map(String.init)
        guard let flagged = lines.firstIndex(of: "#EXT-X-DISCONTINUITY") else { Issue.record("no discontinuity tag"); return }
        #expect(lines[flagged + 2] == "segment2.ts", "directly before the segment that follows the break")
        #expect(!marked.contains("DISCONTINUITY-SEQUENCE"))

        store.add((4..<9).map { segment($0) })   // the flagged segment has slid out of the five listed
        guard case .playlist(let moved) = store.playlist(timeout: 0.1) else { return }
        #expect(moved.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"))
        #expect(!moved.contains("#EXT-X-DISCONTINUITY\n"))
    }

    @Test("Whoever is waiting for the playlist is told at once when the stream fails or is closed")
    func failureWakesWaiters() async {
        let failing = HLSSegmentStore()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { failing.fail("The provider refused this stream.") }
        let began = Date()
        let result = await Task.detached { failing.playlist(timeout: 10) }.value
        #expect(result == .failed("The provider refused this stream."))
        #expect(Date().timeIntervalSince(began) < 3, "not after the timeout")
        #expect(failing.failureReason == "The provider refused this stream.")

        let closing = HLSSegmentStore()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { closing.cancel() }
        let closed = await Task.detached { closing.playlist(timeout: 10) }.value
        #expect(closed == .failed("The stream was closed."))
    }

    @Test("A stream that fails after it started still serves the segments it has")
    func failureAfterStart() {
        let store = HLSSegmentStore()
        store.add((0..<3).map { segment($0) })
        store.fail("The provider keeps dropping the connection.")
        guard case .playlist = store.playlist(timeout: 0.1) else { Issue.record("the playlist should still be served"); return }
    }
}

// MARK: - The local server

@Suite("Local HTTP server")
struct LocalHTTPServerTests {

    @Test("A request's line and headers are read, the query dropped and the names lower-cased")
    func parsing() throws {
        let raw = Data("GET /abc/index.m3u8?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-9\r\nUser-Agent: AppleCoreMedia/1.0\r\n\r\n".utf8)
        let parsed = try #require(LocalHTTPServer.parse(raw))
        #expect(parsed.method == "GET" && parsed.path == "/abc/index.m3u8")
        #expect(parsed.headers["range"] == "bytes=0-9" && parsed.headers["user-agent"] == "AppleCoreMedia/1.0")
        #expect(LocalHTTPServer.parse(Data("nonsense".utf8)) == nil)
    }

    @Test("A response carries its length, and a HEAD response carries no body")
    func serializing() {
        let response = LocalHTTPServer.Response(status: 206, contentType: "video/mp2t", body: Data("abcdef".utf8), headers: ["Content-Range": "bytes 0-5/6"])
        let full = String(decoding: LocalHTTPServer.serialize(response, headOnly: false), as: UTF8.self)
        #expect(full.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(full.contains("Content-Length: 6\r\n") && full.contains("Content-Range: bytes 0-5/6\r\n") && full.contains("Connection: close\r\n"))
        #expect(full.hasSuffix("\r\n\r\nabcdef"))
        let head = String(decoding: LocalHTTPServer.serialize(response, headOnly: true), as: UTF8.self)
        #expect(head.contains("Content-Length: 6\r\n") && head.hasSuffix("\r\n\r\n"))
    }

    @Test("It answers real requests on the loopback interface")
    func answersRequests() async throws {
        let big = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let server = LocalHTTPServer { request in
            switch request.path {
            case "/hello": return .init(status: 200, contentType: "text/plain", body: Data("hello \(request.method)".utf8))
            case "/big": return .init(status: 200, contentType: "application/octet-stream", body: big)
            default: return .text(404, "no")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let base = try #require(URL(string: "http://127.0.0.1:\(port)"))

        let hello = try await request(base.appendingPathComponent("hello"))
        #expect(hello.status == 200 && String(decoding: hello.body, as: UTF8.self) == "hello GET")
        #expect(hello.headers["content-type"] == "text/plain")

        let head = try await request(base.appendingPathComponent("hello"), method: "HEAD")
        #expect(head.status == 200 && head.body.isEmpty)

        let missing = try await request(base.appendingPathComponent("nothing"))
        #expect(missing.status == 404)

        let large = try await request(base.appendingPathComponent("big"))
        #expect(large.body == big, "3 MB arrives intact")
    }

    @Test("Several requests at once are all answered, even while one is held")
    func concurrentRequests() async throws {
        let server = LocalHTTPServer { request in
            if request.path == "/slow" { Thread.sleep(forTimeInterval: 0.3) }
            return .text(200, request.path)
        }
        let port = try server.start()
        defer { server.stop() }
        let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for path in ["slow", "a", "b", "c", "slow", "d"] {
                group.addTask { String(decoding: try await request(base.appendingPathComponent(path)).body, as: UTF8.self) }
            }
            var all: [String] = []
            for try await result in group { all.append(result) }
            return all.sorted()
        }
        #expect(results == ["/a", "/b", "/c", "/d", "/slow", "/slow"])
    }

    @Test("Once stopped it takes no more connections")
    func stopping() async throws {
        let server = LocalHTTPServer { _ in .text(200, "ok") }
        let port = try server.start()
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/"))
        #expect(try await request(url).status == 200)
        server.stop()
        try await Task.sleep(nanoseconds: 700_000_000)   // the accept loop checks for a stop four times a second
        await #expect(throws: (any Error).self) { _ = try await request(url) }
    }

    @Test("If the listening socket is taken away, as the system can from a suspended app, the accept thread ends instead of spinning")
    func listenerLost() async throws {
        let server = LocalHTTPServer { _ in .text(200, "ok") }
        _ = try server.start()
        #expect(server.isAccepting)
        _ = close(server.listenerDescriptor)   // from outside, as the system would
        for _ in 0..<60 where server.isAccepting { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!server.isAccepting, "a closed socket reports ready for ever; looping on it would burn the battery")
        server.stop()
    }

    @Test("A stopped server's accept thread ends too")
    func acceptThreadEndsOnStop() async throws {
        let server = LocalHTTPServer { _ in .text(200, "ok") }
        _ = try server.start()
        server.stop()
        for _ in 0..<60 where server.isAccepting { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!server.isAccepting)
    }
}

// MARK: - A provider that serves a transport stream

/// Answers for provider hosts with a transport stream that is as long as a test needs and then stays open, as a live
/// stream does.
private final class ProviderStub: URLProtocol {
    static let goodStream = SyntheticTransportStream().data(seconds: 13)
    static var radioStream: Data {
        var stream = SyntheticTransportStream()
        stream.videoType = nil
        return stream.data(seconds: 8)
    }
    static var mpeg2Stream: Data {
        var stream = SyntheticTransportStream()
        stream.videoType = 0x02
        return stream.data(seconds: 4)
    }
    /// A stretch of good video that is then cut off, as a provider does when it drops a connection.
    static let shortStream = SyntheticTransportStream().data(seconds: 7)
    nonisolated(unsafe) static var requests: [String] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        ["good.test", "forbidden.test", "page.test", "longpage.test", "mpeg2.test", "message.test", "agent.test",
         "drop.test", "flaky.test", "radio.test"].contains(request.url?.host ?? "")
    }

    /// How many requests this host has had so far.
    static func count(for host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.hasPrefix(host + " ") }.count
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requests.append("\(url.host ?? "") UA=\(request.value(forHTTPHeaderField: "User-Agent") ?? "none")")
        let nth = Self.requests.filter { $0.hasPrefix((url.host ?? "") + " ") }.count
        Self.lock.unlock()
        func respond(_ status: Int, type: String, body: Data, keepOpen: Bool = false) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < body.count {
                let end = min(offset + 16_384, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
            if !keepOpen { client?.urlProtocolDidFinishLoading(self) }
        }
        switch url.host ?? "" {
        case "good.test", "agent.test": respond(200, type: "video/mp2t", body: Self.goodStream, keepOpen: true)
        case "forbidden.test": respond(403, type: "text/html", body: Data("<html>no</html>".utf8))
        case "page.test": respond(200, type: "text/html", body: Data("<html><head><title>Maintenance</title></head><body>Back soon</body></html>".utf8))
        case "longpage.test":
            // A web page of some length that the provider then keeps the connection open after.
            let body = "<html><head><title>Maintenance</title></head><body>" + String(repeating: "We will be back soon. ", count: 30) + "</body></html>"
            respond(200, type: "text/html", body: Data(body.utf8), keepOpen: true)
        case "message.test": respond(200, type: "application/json", body: Data(#"{"error":"Account suspended"}"#.utf8))
        case "mpeg2.test": respond(200, type: "video/mp2t", body: Self.mpeg2Stream, keepOpen: true)
        case "drop.test": respond(200, type: "video/mp2t", body: Self.shortStream)
        case "radio.test": respond(200, type: "video/mp2t", body: Self.radioStream, keepOpen: true)
        case "flaky.test":
            // Good for the first connection, which then ends; every connection after it is refused with a web page.
            if nth == 1 { respond(200, type: "video/mp2t", body: Self.shortStream) }
            else { respond(403, type: "text/html", body: Data("<html><body>Maximum connections reached</body></html>".utf8)) }
        default: respond(404, type: "text/plain", body: Data())
        }
    }
    override func stopLoading() {}
}

@Suite("Transport stream proxy")
struct TransportStreamProxyTests {

    private func startedProxy(_ host: String, headers: [String: String]? = nil, retryDelays: [TimeInterval] = [0.5, 1, 2, 4],
                              onFailure: (@Sendable (String) -> Void)? = nil) throws -> (proxy: TransportStreamProxy, url: URL) {
        let proxy = TransportStreamProxy(upstream: URL(string: "http://\(host)/live/u/p/1.ts")!, headers: headers,
                                         protocolClasses: [ProviderStub.self], retryDelays: retryDelays)
        if let onFailure { proxy.onFailure(onFailure) }
        return (proxy, try proxy.start())
    }

    @Test("The player is given a live HLS playlist on the loopback interface, and segments that start with a keyframe")
    func servesAStream() async throws {
        let (proxy, playlistURL) = try startedProxy("good.test")
        defer { proxy.stop() }
        #expect(playlistURL.host == "127.0.0.1" && playlistURL.lastPathComponent == "index.m3u8")

        let playlist = try await request(playlistURL)
        #expect(playlist.status == 200)
        #expect(playlist.headers["content-type"] == "application/vnd.apple.mpegurl")
        let text = String(decoding: playlist.body, as: UTF8.self)
        #expect(text.hasPrefix("#EXTM3U\n"))
        let names = text.split(separator: "\n").filter { $0.hasSuffix(".ts") }.map(String.init)
        #expect(names.count >= 3)
        #expect(proxy.streamSummary == "H.264 video, AAC audio")
        #expect(proxy.carriesVideo == true, "the player is told a picture is to be expected")

        for name in names.prefix(3) {
            let part = try await request(playlistURL.deletingLastPathComponent().appendingPathComponent(name))
            #expect(part.status == 200 && part.headers["content-type"] == "video/mp2t")
            let contents = SegmentContents(part.body)
            #expect(contents.remainder == 0 && contents.startsWithTables)
            #expect(contents.startsWithKeyframe(pid: 0x100, streamType: 0x1B))
        }
    }

    @Test("Only the right address is served: the secret in the path, then a segment that exists")
    func addressing() async throws {
        let (proxy, playlistURL) = try startedProxy("good.test")
        defer { proxy.stop() }
        _ = try await request(playlistURL)   // wait for the stream to start
        let base = playlistURL.deletingLastPathComponent()
        #expect(try await request(base.appendingPathComponent("segment999.ts")).status == 404)
        #expect(try await request(base.appendingPathComponent("notasegment.ts")).status == 404)
        // A secret of the right length but wrong: the path must be refused for what it says, not for being short.
        let secret = playlistURL.pathComponents[1]
        let wrong = try #require(URL(string: playlistURL.absoluteString.replacingOccurrences(of: secret, with: String(repeating: "a", count: secret.count))))
        #expect(wrong != playlistURL)
        #expect(try await request(wrong).status == 404)
        #expect(try await request(playlistURL, method: "POST").status == 404)
    }

    @Test("A range of a segment can be asked for")
    func ranges() async throws {
        let (proxy, playlistURL) = try startedProxy("good.test")
        defer { proxy.stop() }
        let playlist = String(decoding: try await request(playlistURL).body, as: UTF8.self)
        let name = try #require(playlist.split(separator: "\n").first { $0.hasSuffix(".ts") })
        let segmentURL = playlistURL.deletingLastPathComponent().appendingPathComponent(String(name))
        let whole = try await request(segmentURL).body
        let part = try await request(segmentURL, headers: ["Range": "bytes=188-375"])
        #expect(part.status == 206 && part.body == whole.subdata(in: 188..<376))
        #expect(part.headers["content-range"] == "bytes 188-375/\(whole.count)")
    }

    @Test("Range arithmetic: open-ended, suffix and out-of-range forms")
    func rangeForms() {
        let data = Data((0..<100).map { UInt8($0) })
        func response(_ range: String?) -> LocalHTTPServer.Response { TransportStreamProxy.segmentResponse(data, range: range) }
        #expect(response(nil).status == 200 && response(nil).body == data)
        #expect(response("bytes=10-19").body == data.subdata(in: 10..<20))
        #expect(response("bytes=90-").body == data.subdata(in: 90..<100))
        #expect(response("bytes=-5").body == data.subdata(in: 95..<100))
        #expect(response("bytes=50-5000").body == data.subdata(in: 50..<100), "clamped to the end")
        #expect(response("bytes=200-300").status == 416)
        #expect(response("bytes=20-10").status == 416)
        #expect(response("garbage").status == 200, "an unreadable range is ignored")
    }

    @Test("A provider that refuses the stream is reported at once, to the player and to the app")
    func refused() async throws {
        let reported = ReportedFailures()
        let (proxy, playlistURL) = try startedProxy("forbidden.test") { reported.add($0) }
        defer { proxy.stop() }
        let playlist = try await request(playlistURL)
        #expect(playlist.status == 502)
        let message = String(decoding: playlist.body, as: UTF8.self)
        #expect(message.contains("HTTP 403") && message.contains("connections"))
        #expect(proxy.failure == message)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(reported.all == [message], "the app is told, with the same words")
    }

    @Test("A web page where a stream should be is called what it is, and a short message is quoted")
    func notAStream() async throws {
        let (page, pageURL) = try startedProxy("page.test")
        defer { page.stop() }
        let pageReply = try await request(pageURL)
        #expect(pageReply.status == 502 && String(decoding: pageReply.body, as: UTF8.self).contains("web page"))

        // An answer long enough to judge from its first bytes, on a connection that stays open: no waiting for it to end.
        let (long, longURL) = try startedProxy("longpage.test")
        defer { long.stop() }
        let began = Date()
        let longReply = try await request(longURL)
        #expect(longReply.status == 502 && String(decoding: longReply.body, as: UTF8.self).contains("web page"))
        #expect(Date().timeIntervalSince(began) < 5)

        let (message, messageURL) = try startedProxy("message.test")
        defer { message.stop() }
        let messageReply = try await request(messageURL)
        #expect(messageReply.status == 502 && String(decoding: messageReply.body, as: UTF8.self).contains("Account suspended"))
    }

    @Test("A radio stream says it carries no video, so the player doesn't wait for a picture")
    func radio() async throws {
        let (proxy, playlistURL) = try startedProxy("radio.test")
        defer { proxy.stop() }
        #expect(proxy.carriesVideo == nil, "not known before the program table has been read")
        let playlist = try await request(playlistURL)
        #expect(playlist.status == 200)
        #expect(proxy.streamSummary == "AAC audio")
        #expect(proxy.carriesVideo == false)
    }

    @Test("Video the player can't decode is reported rather than waited on")
    func unsupportedVideo() async throws {
        let (proxy, playlistURL) = try startedProxy("mpeg2.test")
        defer { proxy.stop() }
        let reply = try await request(playlistURL)
        #expect(reply.status == 502)
        #expect(String(decoding: reply.body, as: UTF8.self) == "This channel's video is MPEG-2 video, which Apple's player can't decode.")
    }

    @Test("The failure callback fires once")
    func failureReportedOnce() async throws {
        let reported = ReportedFailures()
        let (proxy, playlistURL) = try startedProxy("forbidden.test") { reported.add($0) }
        defer { proxy.stop() }
        _ = try await request(playlistURL)
        _ = try await request(playlistURL)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(reported.all.count == 1)
    }

    @Test("The channel's own headers go to the provider, and the default introduces itself as the player does")
    func upstreamHeaders() async throws {
        let before = ProviderStub.requests.count
        let (own, ownURL) = try startedProxy("agent.test", headers: ["User-Agent": "IPTVSmarters/2.0"])
        defer { own.stop() }
        _ = try await request(ownURL)
        let (plain, plainURL) = try startedProxy("agent.test")
        defer { plain.stop() }
        _ = try await request(plainURL)
        let seen = Array(ProviderStub.requests.dropFirst(before)).filter { $0.hasPrefix("agent.test") }
        #expect(seen.contains("agent.test UA=IPTVSmarters/2.0"))
        #expect(seen.contains { $0.contains("UA=AppleCoreMedia/1.0.0") })
    }

    @Test("When the provider drops the connection the stream is picked up again, and the join is marked as a break")
    func reconnectsAfterADrop() async throws {
        let reported = ReportedFailures()
        let (proxy, playlistURL) = try startedProxy("drop.test", retryDelays: [0.02]) { reported.add($0) }
        defer { proxy.stop() }
        var text = ""
        for _ in 0..<100 {
            let reply = try await request(playlistURL)
            text = String(decoding: reply.body, as: UTF8.self)
            if text.contains("#EXT-X-DISCONTINUITY\n") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(text.contains("#EXT-X-DISCONTINUITY\n"), "the second connection's first segment follows a break")
        #expect(ProviderStub.count(for: "drop.test") >= 2)
        #expect(reported.all.isEmpty && proxy.failure == nil, "a dropped connection is not a failure while it can be reconnected")
    }

    @Test("A refusal after the stream began is retried, and its error page isn't taken for video")
    func refusedAfterItBegan() async throws {
        let reported = ReportedFailures()
        let (proxy, playlistURL) = try startedProxy("flaky.test", retryDelays: [0.02]) { reported.add($0) }
        defer { proxy.stop() }
        for _ in 0..<200 where reported.all.isEmpty { try await Task.sleep(nanoseconds: 25_000_000) }
        let reason = try #require(reported.all.first)
        #expect(reason.contains("HTTP 403") && reason.contains("connections"), "the provider's refusal is the reason, not a web page: \(reason)")
        #expect(!reason.contains("web page"))
        #expect(ProviderStub.count(for: "flaky.test") == 6, "the first connection, then five refusals, the last of which ends it")
        // What was cut before the refusals still plays.
        let reply = try await request(playlistURL)
        #expect(reply.status == 200)
    }

    @Test("Once stopped the proxy stops serving")
    func stopping() async throws {
        let (proxy, playlistURL) = try startedProxy("good.test")
        _ = try await request(playlistURL)
        proxy.stop()
        try await Task.sleep(nanoseconds: 700_000_000)
        await #expect(throws: (any Error).self) { _ = try await request(playlistURL) }
    }
}

/// Failures reported by a proxy, from whichever thread it reports on.
private final class ReportedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ failure: String) { lock.lock(); list.append(failure); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
