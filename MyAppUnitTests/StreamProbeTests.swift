import Foundation
import Testing
@testable import BannerTV

/// What a provider turns out to be sending when a stream won't start.
@Suite("Stream probe")
struct StreamProbeTests {

    private let streamURL = URL(string: "http://panel.test/live/AliceUser/Secret99/12.m3u8")!

    // MARK: Fixtures

    private func mediaPlaylist(segments count: Int = 6, duration: Double = 6) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:100\n"
        for i in 0..<count { text += "#EXTINF:\(duration),\nseg\(100 + i).ts\n" }
        return text
    }

    private let masterPlaylist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,AVERAGE-BANDWIDTH=2000000,RESOLUTION=1280x720
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=6000000
        high/index.m3u8
        """

    private let transportStream = SyntheticTransportStream().data(seconds: 1)
    private let page = Data("<html><head><title>Just a moment...</title></head><body>Checking your browser</body></html>".utf8)

    private func ok(_ body: String, type: String = "application/vnd.apple.mpegurl", url: String? = nil) -> StreamProbe.Reply {
        .init(url: url.flatMap(URL.init(string:)), status: 200, contentType: type, body: Data(body.utf8), end: .completed, seconds: 0.1)
    }

    private func ok(_ body: Data, type: String = "video/mp2t", seconds: Double = 0.4, end: StreamProbe.Reply.End = .completed, length: Int64? = nil) -> StreamProbe.Reply {
        .init(status: 200, contentType: type, contentLength: length, body: body, end: end, seconds: seconds)
    }

    private func status(_ code: Int, _ body: String = "") -> StreamProbe.Reply {
        .init(status: code, contentType: "text/html", body: Data(body.utf8), end: .completed, seconds: 0.1)
    }

    /// Answers by the last path component of the URL asked for, and remembers what was asked.
    private func provider(_ answers: [String: StreamProbe.Reply]) -> (fetch: StreamProbe.Fetch, asked: Asked) {
        let asked = Asked()
        let fetch: StreamProbe.Fetch = { url, _, _ in
            asked.add(url)
            return answers[url.lastPathComponent] ?? StreamProbe.Reply(status: 404, body: Data(), end: .completed, seconds: 0.05)
        }
        return (fetch, asked)
    }

    // MARK: Healthy and unhealthy streams

    @Test("A playlist whose segments arrive faster than they play is healthy, and the segment near the live edge is the one tried")
    func healthy() async {
        let (fetch, asked) = provider(["12.m3u8": ok(mediaPlaylist()), "seg103.ts": ok(transportStream, seconds: 0.5)])
        let report = await StreamProbe.probe(url: streamURL, fetch: fetch)
        #expect(report.verdict == .healthy)
        #expect(report.summary.contains("healthy") && report.summary.contains("6 segments") && report.summary.contains("12.0× real time"))
        #expect(asked.names == ["12.m3u8", "seg103.ts"], "the playlist, then the third segment from the end")
    }

    @Test("A master playlist is followed to its first variant, with relative addresses resolved")
    func masterPlaylistFollowed() async {
        let (fetch, asked) = provider(["12.m3u8": ok(masterPlaylist), "index.m3u8": ok(mediaPlaylist(segments: 4)), "seg101.ts": ok(transportStream)])
        let report = await StreamProbe.probe(url: streamURL, fetch: fetch)
        #expect(report.verdict == .healthy)
        #expect(asked.urls.map(\.absoluteString) == [
            "http://panel.test/live/AliceUser/Secret99/12.m3u8",
            "http://panel.test/live/AliceUser/Secret99/low/index.m3u8",
            "http://panel.test/live/AliceUser/Secret99/low/seg101.ts",
        ])
    }

    @Test("Segments that take longer to arrive than to play are too slow, and the message says by how much")
    func slow() async {
        let (fetch, _) = provider(["12.m3u8": ok(mediaPlaylist()), "seg103.ts": ok(transportStream, seconds: 12)])
        let report = await StreamProbe.probe(url: streamURL, fetch: fetch)
        #expect(report.verdict == .slowSegments)
        #expect(report.summary.contains("0.5× real time"))
    }

    @Test("A segment still arriving when the clock ran out is judged by what it says its size is")
    func timedOut() async {
        let partial = Data(transportStream.prefix(60_000))
        let reply = ok(partial, seconds: 6, end: .timeLimit, length: 3_000_000)
        let (fetch, _) = provider(["12.m3u8": ok(mediaPlaylist()), "seg103.ts": reply])
        #expect(await StreamProbe.probe(url: streamURL, fetch: fetch).verdict == .slowSegments)

        // The same cut-off but with a size that says the rate is easily enough.
        let quick = ok(Data(transportStream.prefix(60_000)), seconds: 0.05, end: .sizeLimit, length: 100_000)
        let (fetch2, _) = provider(["12.m3u8": ok(mediaPlaylist()), "seg103.ts": quick])
        #expect(await StreamProbe.probe(url: streamURL, fetch: fetch2).verdict == .healthy)
    }

    // MARK: What the provider says instead

    @Test("A refusal names the status and the usual cause, and a 404 says HLS may be off")
    func refusals() async {
        let (forbidden, _) = provider(["12.m3u8": status(403, "<html><head><title>Forbidden</title></head></html>")])
        let report = await StreamProbe.probe(url: streamURL, fetch: forbidden)
        #expect(report.verdict == .refused(403))
        #expect(report.summary.contains("HTTP 403") && report.summary.contains("connections") && report.summary.contains("User-Agent"))
        #expect(report.summary.contains("It said: \"Forbidden\""), "the page's own title is quoted")

        let (missing, _) = provider(["12.m3u8": status(404)])
        let notFound = await StreamProbe.probe(url: streamURL, fetch: missing)
        #expect(notFound.verdict == .refused(404) && notFound.summary.contains("HLS"))

        let (limited, _) = provider(["12.m3u8": status(429)])
        #expect(await StreamProbe.probe(url: streamURL, fetch: limited).summary.contains("limiting requests"))
        let (broken, _) = provider(["12.m3u8": status(503)])
        #expect(await StreamProbe.probe(url: streamURL, fetch: broken).summary.contains("server failed"))
    }

    @Test("A raw transport stream where HLS was expected is named, with what to ask the provider for")
    func rawTransportStream() async {
        let (fetch, _) = provider(["12.m3u8": ok(transportStream, seconds: 0.2)])
        let report = await StreamProbe.probe(url: streamURL, fetch: fetch)
        #expect(report.verdict == .rawTransportStream)
        #expect(report.summary.contains("MPEG-TS") && report.summary.contains("HLS (m3u8) output"))
    }

    @Test("A web page, and a message, are quoted")
    func pagesAndMessages() async {
        let (fetch, _) = provider(["12.m3u8": ok(page, type: "text/html")])
        let report = await StreamProbe.probe(url: streamURL, fetch: fetch)
        #expect(report.verdict == .webPage && report.summary.contains("titled \"Just a moment...\""))

        let json = ok(#"{"user_info":{"auth":0,"message":"Account expired"}}"#, type: "application/json")
        let (messageFetch, _) = provider(["12.m3u8": json])
        let message = await StreamProbe.probe(url: streamURL, fetch: messageFetch)
        #expect(message.verdict == .providerMessage && message.summary.contains("Account expired"))
    }

    @Test("Nothing at all, and bytes that mean nothing, are each said")
    func emptyAndBinary() async {
        let (empty, _) = provider(["12.m3u8": ok(Data(), type: "text/plain")])
        #expect(await StreamProbe.probe(url: streamURL, fetch: empty).verdict == .unrecognised)
        let noise = Data((0..<500).map { UInt8(truncatingIfNeeded: $0 &* 13) | 0x80 })
        let (binary, _) = provider(["12.m3u8": ok(noise, type: "application/octet-stream")])
        let report = await StreamProbe.probe(url: streamURL, fetch: binary)
        #expect(report.verdict == .unrecognised && report.summary.contains("isn't a playlist"))
    }

    // MARK: Further along

    @Test("A playlist with no segments in it is an empty feed")
    func emptyPlaylist() async {
        let (fetch, _) = provider(["12.m3u8": ok("#EXTM3U\n#EXT-X-TARGETDURATION:6\n")])
        #expect(await StreamProbe.probe(url: streamURL, fetch: fetch).verdict == .emptyPlaylist)
    }

    @Test("A playlist that loads while its video is refused, or is a web page, is said so")
    func segmentsRefused() async {
        let (refused, _) = provider(["12.m3u8": ok(mediaPlaylist()), "seg103.ts": status(403)])
        let report = await StreamProbe.probe(url: streamURL, fetch: refused)
        #expect(report.verdict == .segmentsRefused(403) && report.summary.contains("refuses the video itself"))

        let (html, _) = provider(["12.m3u8": ok(mediaPlaylist()), "seg103.ts": ok(page, type: "text/html")])
        #expect(await StreamProbe.probe(url: streamURL, fetch: html).verdict == .webPage)
    }

    @Test("A provider that can't be reached says why, at the playlist or at the video")
    func unreachable() async {
        let refusedConnection = StreamProbe.Reply(status: nil, body: Data(), end: .failed, seconds: 0.01, failure: "the connection was refused")
        let (dead, _) = provider(["12.m3u8": refusedConnection])
        let report = await StreamProbe.probe(url: streamURL, fetch: dead)
        #expect(report.verdict == .unreachable)
        #expect(report.summary == "Couldn't reach panel.test to ask for the stream: the connection was refused.")

        let (halfway, _) = provider(["12.m3u8": ok(mediaPlaylist()), "seg103.ts": refusedConnection])
        let late = await StreamProbe.probe(url: streamURL, fetch: halfway)
        #expect(late.verdict == .unreachable && late.summary.hasPrefix("The playlist loads, but fetching the video failed"))
    }

    // MARK: Credentials

    @Test("The account's username and password never appear in what is shown or logged")
    func redaction() async {
        let echoing = ok(#"{"error":"Invalid login AliceUser / Secret99"}"#, type: "application/json")
        let (fetch, _) = provider(["12.m3u8": echoing])
        let report = await StreamProbe.probe(url: streamURL, fetch: fetch)
        #expect(!report.summary.contains("AliceUser") && !report.summary.contains("Secret99"))
        #expect(!report.technical.contains("AliceUser") && !report.technical.contains("Secret99"))
        #expect(report.summary.contains("•••"))
        #expect(report.technical.hasPrefix("panel.test · "), "the host is kept, as the person knows it")
    }

    @Test("Credentials are found in the path, in either shape, and in a query")
    func secretsFound() {
        func secrets(_ string: String) -> [String] { StreamProbe.secrets(in: URL(string: string)!) }
        #expect(secrets("http://h/live/alice/pw12345/9.m3u8") == ["pw12345", "alice"], "longest first, so one that contains another is cleaned whole")
        #expect(secrets("http://h/alice/pw12345/9") == ["pw12345", "alice"])
        #expect(secrets("http://h/get.php?username=bob99&password=hunter22&type=m3u") == ["hunter22", "bob99"])
        #expect(secrets("http://h/live/us%2Fer/p%3Fss/9.ts").contains("us/er"), "the decoded form too")
        #expect(secrets("http://h/ab/cd/9").isEmpty, "two-letter values aren't worth masking")
        #expect(StreamProbe.redact("user alice pw12345", secrets: ["pw12345", "alice"]) == "user ••• •••")
    }

    // MARK: Reading what came back

    @Test("Bodies are classified: playlists, transport streams, pages, JSON, text, noise")
    func classification() {
        #expect(StreamProbe.classify(Data()) == .empty)
        #expect(StreamProbe.classify(Data(masterPlaylist.utf8)) == .hlsMaster)
        #expect(StreamProbe.classify(Data(mediaPlaylist().utf8)) == .hlsMedia)
        #expect(StreamProbe.classify(Data("\u{FEFF}#EXTM3U\n#EXTINF:1,\na.ts".utf8)) == .hlsMedia, "a byte-order mark in front")
        #expect(StreamProbe.classify(transportStream) == .transportStream)
        #expect(StreamProbe.classify(page) == .html)
        #expect(StreamProbe.classify(Data("<?xml version=\"1.0\"?><error/>".utf8)) == .text)
        #expect(StreamProbe.classify(Data(#"{"a":1}"#.utf8)) == .json && StreamProbe.classify(Data("[]".utf8)) == .json)
        #expect(StreamProbe.classify(Data("Not found".utf8)) == .text)
        #expect(StreamProbe.classify(Data(repeating: 0, count: 300)) == .binary)
        // A text that begins with "G" (0x47) and has another at the next packet position is not a transport stream.
        let tricky = Data(("G" + String(repeating: "a", count: 187) + "G" + String(repeating: "b", count: 100)).utf8)
        #expect(StreamProbe.classify(tricky) == .text)
    }

    @Test("A playlist's segments, durations and variants are read, and an AVERAGE-BANDWIDTH isn't taken for BANDWIDTH")
    func playlistParsing() {
        let base = URL(string: "http://panel.test/a/b/index.m3u8")!
        let master = StreamProbe.parsePlaylist(masterPlaylist, base: base)
        #expect(master.variants.map(\.absoluteString) == ["http://panel.test/a/b/low/index.m3u8", "http://panel.test/a/b/high/index.m3u8"])
        #expect(master.variantBandwidths == [2_500_000, 6_000_000])

        let media = StreamProbe.parsePlaylist("""
            #EXTM3U
            #EXT-X-TARGETDURATION:8
            #EXTINF:7.5,
            https://cdn.test/x/one.ts
            #EXTINF:-1,
            /abs/two.ts
            #EXTINF:4,title
            three.ts
            #EXT-X-ENDLIST
            """, base: base)
        #expect(media.segments.map(\.absoluteString) == ["https://cdn.test/x/one.ts", "http://panel.test/abs/two.ts", "http://panel.test/a/b/three.ts"])
        #expect(media.segmentDurations == [7.5, 8, 4], "an unknown duration is taken as the target")
        #expect(media.targetDuration == 8 && media.isEnded)
    }

    @Test("The probe introduces itself as the player does unless the channel names its own User-Agent")
    func userAgent() {
        #expect(StreamProbe.playerUserAgent.hasPrefix("AppleCoreMedia/1.0.0 ("))
    }
}

/// The URLs a probe asked for, in order.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func add(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
    var names: [String] { urls.map(\.lastPathComponent) }
}

// MARK: - Over the network

/// A provider that answers over a real session: a playlist and a segment, an endless transport stream, or a refusal.
private final class ProbeStub: URLProtocol {
    nonisolated(unsafe) static var userAgents: [String] = []
    private static let lock = NSLock()
    static let segment = SyntheticTransportStream().data(seconds: 1)

    override class func canInit(with request: URLRequest) -> Bool { (request.url?.host ?? "").hasPrefix("probe-") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.userAgents.append("\(url.host ?? "") \(request.value(forHTTPHeaderField: "User-Agent") ?? "none")")
        Self.lock.unlock()
        func answer(_ status: Int, _ type: String, _ body: Data, finish: Bool = true) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var offset = 0
            while offset < body.count {
                let end = min(offset + 16_384, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
            if finish { client?.urlProtocolDidFinishLoading(self) }
        }
        switch (url.host ?? "", url.lastPathComponent) {
        case ("probe-hls.test", "1.m3u8"):
            answer(200, "application/vnd.apple.mpegurl", Data("#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\ns1.ts\n#EXTINF:2.0,\ns2.ts\n#EXTINF:2.0,\ns3.ts\n".utf8))
        case ("probe-hls.test", _):
            answer(200, "video/mp2t", Self.segment)
        case ("probe-ts.test", _):
            // An endless transport stream: far more than the probe will read, and it never ends.
            answer(200, "video/mp2t", Data((0..<40).flatMap { _ in Array(Self.segment) }), finish: false)
        case ("probe-403.test", _):
            answer(403, "text/html", Data("<html><title>Denied</title></html>".utf8))
        case ("probe-dead.test", _):
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        default:
            answer(404, "text/plain", Data())
        }
    }
    override func stopLoading() {}
}

@Suite("Stream probe over the network")
struct StreamProbeNetworkTests {

    @Test("A healthy HLS stream is walked through: playlist, then a segment")
    func healthy() async throws {
        let url = try #require(URL(string: "http://probe-hls.test/live/u/p/1.m3u8"))
        let report = await StreamProbe.run(url: url, headers: nil, protocolClasses: [ProbeStub.self])
        #expect(report.verdict == .healthy, "\(report.summary) [\(report.technical)]")
        #expect(report.technical.contains("3 segments") && report.technical.contains("segment HTTP 200"))
    }

    @Test("An endless transport stream is read only as far as needed, not to its end")
    func endlessStream() async throws {
        let url = try #require(URL(string: "http://probe-ts.test/live/u/p/1.m3u8"))
        let began = Date()
        let report = await StreamProbe.run(url: url, headers: nil, protocolClasses: [ProbeStub.self])
        #expect(report.verdict == .rawTransportStream)
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(report.technical.contains("cut off at the size limit"))
    }

    @Test("A refusal and a dead host come back as findings, not errors")
    func failures() async throws {
        let refused = await StreamProbe.run(url: try #require(URL(string: "http://probe-403.test/live/u/p/1.m3u8")), headers: nil, protocolClasses: [ProbeStub.self])
        #expect(refused.verdict == .refused(403) && refused.summary.contains("Denied"))
        let dead = await StreamProbe.run(url: try #require(URL(string: "http://probe-dead.test/live/u/p/1.m3u8")), headers: nil, protocolClasses: [ProbeStub.self])
        #expect(dead.verdict == .unreachable && dead.summary.contains("refused"))
    }

    @Test("The channel's headers go with the requests, and without any the player's own User-Agent does")
    func headersSent() async throws {
        let own = try #require(URL(string: "http://probe-403.test/live/u/p/1.m3u8"))
        _ = await StreamProbe.run(url: own, headers: ["User-Agent": "VLC/3.0.20"], protocolClasses: [ProbeStub.self])
        let plain = try #require(URL(string: "http://probe-dead.test/live/u/p/1.m3u8"))
        _ = await StreamProbe.run(url: plain, headers: nil, protocolClasses: [ProbeStub.self])
        #expect(ProbeStub.userAgents.contains("probe-403.test VLC/3.0.20"))
        #expect(ProbeStub.userAgents.contains { $0.hasPrefix("probe-dead.test AppleCoreMedia/1.0.0") })
    }
}
