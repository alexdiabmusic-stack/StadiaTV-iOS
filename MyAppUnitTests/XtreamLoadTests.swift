import Foundation
import Testing
@testable import BannerTV

/// A stand-in Xtream panel, picked by host name so each test has its own and they can run side by side.
private final class StubPanelProtocol: URLProtocol {
    struct Reply: Sendable {
        var status = 200
        var type = "application/json"
        var body: String
    }

    /// What a host answers for `get_live_categories` and `get_live_streams`.
    struct Panel: Sendable {
        var categories = Reply(body: "[]")
        var streams = Reply(body: "[]")
    }

    private static let page = "<html><body>Checking your browser before accessing the site.</body></html>"
    private static let rejected = #"{"user_info":{"auth":0}}"#
    private static let blocked = Reply(status: 403, type: "text/html", body: page)

    static let panels: [String: Panel] = [
        // Real panels repeat a category id, send entries without one, and mix numbers with strings.
        "repeated-ids.test": Panel(
            categories: Reply(body: #"[{"category_id":"7","category_name":"Sports"},{"category_id":"7","category_name":"Sports (copy)"},{"category_name":"No id"},{"category_id":"","category_name":"Empty id"},{"category_id":9,"category_name":"News"}]"#),
            streams: Reply(body: #"[{"stream_id":1,"name":"One","category_id":"7"},{"stream_id":"2","name":"Two","category_id":9},{"stream_id":3,"name":"Three","category_id":"404"},{"stream_id":4,"name":"Four"}]"#)
        ),
        "rejected.test": Panel(categories: Reply(body: rejected), streams: Reply(body: rejected)),
        "rejected-empty.test": Panel(categories: Reply(body: "[]"), streams: Reply(body: "[]")),
        "html.test": Panel(categories: Reply(type: "text/html", body: page), streams: Reply(type: "text/html", body: page)),
        "blocked.test": Panel(categories: blocked, streams: blocked),
        "limited.test": Panel(categories: Reply(status: 429, body: ""), streams: Reply(status: 429, body: "")),
        "empty.test": Panel(categories: Reply(body: #"[{"category_id":"1","category_name":"Sports"}]"#), streams: Reply(body: "[]")),
    ]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host.flatMap { panels[$0] } != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let panel = Self.panels[url.host ?? ""] else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "action" }?.value
        let reply = action == "get_live_categories" ? panel.categories : panel.streams
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubPanelProtocol.self]
    return URLSession(configuration: configuration)
}

/// What a refresh does with a provider that misbehaves. A refresh that throws leaves the cached lineup alone,
/// so these are the cases where answering with nothing, or with a login page, must not look like success.
@Suite("Xtream channel load")
struct XtreamLoadTests {

    private func load(host: String) async throws -> (channels: [AdapterChannel], error: LiveProviderError?) {
        let id = UUID()
        try KeychainStore.saveXtreamCredentials(XtreamCredentials(username: "u", password: "p"), for: id)
        defer { KeychainStore.deleteXtreamCredentials(for: id) }
        let playlist = Playlist(id: id, name: "Test", kind: .xtream, host: "http://\(host)", credentialID: id)
        let adapter = XtreamProviderAdapter(provider: LiveProvider(playlist: playlist), session: stubbedSession())
        do {
            return (try await adapter.loadChannels().channels, nil)
        } catch let error as LiveProviderError {
            return ([], error)
        }
    }

    @Test("A repeated, missing or numeric id in the category list loads the channels instead of crashing")
    func awkwardCategoryIDs() async throws {
        let result = try await load(host: "repeated-ids.test")
        #expect(result.error == nil)
        #expect(result.channels.map(\.name) == ["One", "Two", "Three", "Four"])
        #expect(result.channels.map(\.groupTitle) == ["Sports", "News", nil, nil], "the first title for an id wins; an unknown or missing id has none")
        #expect(result.channels.map(\.xtreamStreamID) == [1, 2, 3, 4], "a stream id sent as a string is still read")
    }

    @Test("A rejected login is reported as a credentials problem, not as unreadable data")
    func rejectedLogin() async throws {
        #expect(try await load(host: "rejected.test").error == .authenticationFailed)
    }

    @Test("A page that isn't JSON is an unexpected response, and an HTTP error names its status")
    func badReplies() async throws {
        #expect(try await load(host: "html.test").error == .badResponse)
        #expect(try await load(host: "blocked.test").error == .httpStatus(403))
        #expect(try await load(host: "limited.test").error == .httpStatus(429))
    }

    @Test("An empty list is an error, not a lineup, so it can't replace the channels already cached")
    func emptyList() async throws {
        #expect(try await load(host: "empty.test").error == .noChannels)
        #expect(try await load(host: "rejected-empty.test").error == .noChannels, "some panels answer a rejected login with []")
    }

    @Test("The messages say what happened and what to try")
    func messages() throws {
        let blocked = try #require(LiveProviderError.httpStatus(403).errorDescription)
        #expect(blocked.contains("403") && blocked.contains("password"))
        #expect(try #require(LiveProviderError.httpStatus(429).errorDescription).contains("limiting"))
        #expect(try #require(LiveProviderError.httpStatus(503).errorDescription).contains("503"))
        #expect(try #require(LiveProviderError.noChannels.errorDescription).contains("expired"))
    }
}

@Suite("M3U playlist load")
struct M3ULoadTests {

    private func result(status: Int, body: String) async throws -> (channels: [AdapterChannel], error: LiveProviderError?) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("m3u-\(UUID().uuidString).m3u")
        try Data(body.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = URL(string: "http://playlist.test/get.m3u")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        do {
            return (try await M3UProviderAdapter.channels(inDownload: file, response: response).channels, nil)
        } catch let error as LiveProviderError {
            return ([], error)
        }
    }

    @Test("A page that isn't a playlist is an error, not an empty lineup")
    func notAPlaylist() async throws {
        #expect(try await result(status: 200, body: "<html><body>Your link has expired.</body></html>").error == .noChannels)
        #expect(try await result(status: 200, body: "").error == .noChannels)
        #expect(try await result(status: 200, body: "#EXTM3U\n").error == .noChannels, "a header with no entries")
    }

    @Test("An HTTP error names its status, whatever the body says")
    func httpError() async throws {
        #expect(try await result(status: 404, body: "<html>Not found</html>").error == .httpStatus(404))
        #expect(try await result(status: 403, body: "#EXTM3U\n#EXTINF:-1,A\nhttp://a/1.ts\n").error == .httpStatus(403))
    }

    @Test("A page of HTML is not read as a list of streams, but a plain list of stream URLs still is")
    func htmlIsNotChannels() async throws {
        let page = """
            <!DOCTYPE html>
            <html>
            <head><title>Just a moment...</title></head>
            <body>Checking your browser before accessing the site. https://example.com/help</body>
            </html>
            """
        #expect(try await result(status: 200, body: page).error == .noChannels)
        let plain = try await result(status: 200, body: "http://playlist.test/a.m3u8\nhttps://playlist.test/b.m3u8\n")
        #expect(plain.error == nil && plain.channels.map(\.name) == ["a.m3u8", "b.m3u8"], "named after the file when nothing names them")
    }

    @Test("A playlist with entries still loads")
    func playlistLoads() async throws {
        let playlist = """
            #EXTM3U
            #EXTINF:-1 tvg-id="espn.us" group-title="Sports",ESPN
            http://playlist.test/1.ts
            #EXTINF:-1 tvg-id="fox.us" group-title="Sports",FOX
            http://playlist.test/2.ts
            """
        let loaded = try await result(status: 200, body: playlist)
        #expect(loaded.error == nil)
        #expect(loaded.channels.map(\.name) == ["ESPN", "FOX"])
    }
}
