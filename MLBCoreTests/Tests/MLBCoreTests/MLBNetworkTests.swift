import Foundation
import Testing
@testable import MLBCore

private final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int, [String:String], Data)] = []
    private var count = 0
    private var routes: [String: (Int, [String:String], Data)] = [:]
    func set(_ responses: [(Int, [String:String], Data)]) { lock.lock(); defer { lock.unlock() }; entries = responses; routes = [:]; count = 0 }
    func setRoutes(_ responses: [String: (Int, [String:String], Data)]) {
        lock.lock(); defer { lock.unlock() }; routes = responses; entries = []; count = 0
    }
    func next(path: String) -> (Int, [String:String], Data) {
        lock.lock(); defer { lock.unlock() }; count += 1
        if let route = routes[path] { return route }
        return entries.isEmpty ? (503, [:], Data()) : entries.removeFirst()
    }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class MLBURLProtocol: URLProtocol, @unchecked Sendable {
    static let responses = ResponseQueue()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, data) = Self.responses.next(path: request.url?.path ?? "")
        // A held test response remains in flight until URLSession cancels it.
        if code == 0 { return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("MLB networking", .serialized)
struct MLBNetworkTests {
    private func client() -> MLBAPIClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MLBURLProtocol.self]
        return MLBAPIClient(session: URLSession(configuration: configuration))
    }
    @Test func decodingAndLimitedRetry() async throws {
        MLBURLProtocol.responses.set([(503, [:], Data()), (503, [:], Data()), (200, [:], try fixtureData("schedule"))])
        let response = try await client().schedule(date: Date())
        #expect(!response.games.isEmpty); #expect(MLBURLProtocol.responses.requests == 3)
    }
    @Test func malformedAndRateLimit() async throws {
        MLBURLProtocol.responses.set([(200, [:], Data("not JSON".utf8))])
        do { _ = try await client().schedule(date: Date()); Issue.record("Expected decoding error") } catch { #expect(error is MLBAPIError) }
        MLBURLProtocol.responses.set([(429, ["Retry-After": "60"], Data())])
        let api = client()
        for _ in 0..<2 {
            do { _ = try await api.schedule(date: Date()); Issue.record("Expected rate limit") }
            catch MLBAPIError.rateLimited(let date) { #expect(date > Date()) }
        }
        #expect(MLBURLProtocol.responses.requests == 1)
    }
    @Test func cancellationDoesNotRetry() async throws {
        MLBURLProtocol.responses.set([(0, [:], Data())])
        let api = client(); let task = Task { try await api.liveFeed(gamePk: 744834) }
        for _ in 0..<100 where MLBURLProtocol.responses.requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        #expect(MLBURLProtocol.responses.requests == 1)
    }
    @Test func partialFailureKeepsOtherResources() async throws {
        let feed: MLBGameFeedResponse = try fixture("final")
        MLBURLProtocol.responses.setRoutes([
            "/api/v1.1/game/744834/feed/live": (404, [:], Data()),
            "/api/v1/game/744834/linescore": (200, [:], try JSONEncoder().encode(feed.live["linescore"])),
            "/api/v1/game/744834/playByPlay": (404, [:], Data()),
            "/api/v1/game/744834/boxscore": (200, [:], try JSONEncoder().encode(feed.live["boxscore"]))
        ])
        let update = try await MLBGameCenterService(client: client()).fetch(gamePk: 744834, tab: .plays, full: true, includeContent: false)
        #expect(update.errors["plays"] != nil); #expect(update.box != nil); #expect(update.line != nil)
        let snapshot = MLBGameCenterReducer.apply(update, to: BaseballGameSnapshot(gamePk: 744834))
        #expect(!snapshot.box.isEmpty); #expect(snapshot.line?.homeRuns == 1)
    }
    @Test func lightBoxRefreshDoesNotRequestPlaysOrFullFeed() async throws {
        let feed: MLBGameFeedResponse = try fixture("final")
        MLBURLProtocol.responses.setRoutes([
            "/api/v1.1/game/744834/feed/live": (200, [:], try fixtureData("final")),
            "/api/v1/game/744834/linescore": (200, [:], try JSONEncoder().encode(feed.live["linescore"])),
            "/api/v1/game/744834/boxscore": (200, [:], try JSONEncoder().encode(feed.live["boxscore"]))
        ])
        let update = try await MLBGameCenterService(client: client()).fetch(gamePk: 744834, tab: .boxscore, full: false, includeContent: false)
        #expect(update.feed == nil); #expect(update.plays == nil); #expect(update.box != nil); #expect(MLBURLProtocol.responses.requests == 3)
    }
}
