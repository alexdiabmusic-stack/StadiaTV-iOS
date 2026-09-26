import Foundation
import Testing
@testable import EPLCore

private final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int, [String: String], Data)] = []
    private var count = 0
    func set(_ responses: [(Int, [String: String], Data)]) { lock.lock(); defer { lock.unlock() }; entries = responses; count = 0 }
    func next() -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }; count += 1
        return entries.isEmpty ? (503, [:], Data()) : entries.removeFirst()
    }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
}
private final class EPLURLProtocol: URLProtocol, @unchecked Sendable {
    static let responses = ResponseQueue()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, data) = Self.responses.next()
        if code == 0 { return } // held in flight until URLSession cancels it
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("EPL networking", .serialized)
struct EPLNetworkTests {
    private func client() -> EPLPulseLiveClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EPLURLProtocol.self]
        return EPLPulseLiveClient(session: URLSession(configuration: configuration))
    }

    @Test func rateLimitParsesRetryAfterAndStopsRetrying() async throws {
        EPLURLProtocol.responses.set([(429, ["Retry-After": "30"], Data())])
        let api = client()
        do {
            _ = try await api.match("2645241")
            Issue.record("Expected a rate-limit error")
        } catch EPLAPIError.rateLimited(let date) {
            #expect(date > Date())
        }
        #expect(EPLURLProtocol.responses.requests == 1) // no local retry on 429 — caller backs off instead
    }

    @Test func notEnabledAndNotFoundMapProblemJSONDetail() async throws {
        let notEnabledBody = Data("""
        {"type":"about:blank","title":"Bad Request","status":400,"detail":"This endpoint is not enabled for API access"}
        """.utf8)
        EPLURLProtocol.responses.set([(400, [:], notEnabledBody)])
        do { _ = try await client().match("x"); Issue.record("Expected notEnabled") }
        catch EPLAPIError.notEnabled(let detail) { #expect(detail.contains("not enabled")) }

        let notFoundBody = Data("""
        {"title":"The service encountered an error","status":404,"detail":"Could not find requested entity"}
        """.utf8)
        EPLURLProtocol.responses.set([(404, [:], notFoundBody)])
        do { _ = try await client().match("9999999"); Issue.record("Expected notFound") }
        catch EPLAPIError.notFound(let detail) { #expect(detail.contains("Could not find")) }
    }

    @Test func malformedJSONIsADecodingErrorNotACrash() async throws {
        EPLURLProtocol.responses.set([(200, [:], Data("not JSON".utf8))])
        do { _ = try await client().match("2645241"); Issue.record("Expected decoding error") }
        catch EPLAPIError.decoding { /* expected */ }
    }

    @Test func serverErrorRetriesWithBoundedAttempts() async throws {
        let ok = Data("""
        {"matchId":"2645241"}
        """.utf8)
        EPLURLProtocol.responses.set([(503, [:], Data()), (503, [:], Data()), (200, [:], ok)])
        let value = try await client().match("2645241")
        #expect(value["matchId"].string == "2645241")
        #expect(EPLURLProtocol.responses.requests == 3)
    }

    @Test func cancellationDoesNotRetry() async throws {
        EPLURLProtocol.responses.set([(0, [:], Data())])
        let api = client()
        let task = Task { try await api.match("2645241") }
        for _ in 0..<100 where EPLURLProtocol.responses.requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(EPLURLProtocol.responses.requests == 1)
    }

    @Test func oneFailingResourceDoesNotFailTheWholeAggregatorFetch() async throws {
        // Step 73: stats failing must not take down score/events/lineups/officials/commentary.
        let matchBody = try fixtureData("match-fulltime")
        let eventsBody = try fixtureData("events")
        let lineupsBody = try fixtureData("lineups-announced")
        let officialsBody = try fixtureData("officials")
        let commentaryBody = try fixtureData("commentary")
        EPLURLProtocol.responses.set([
            (200, [:], matchBody), (200, [:], eventsBody), (200, [:], lineupsBody),
            (500, [:], Data()), (500, [:], Data()), (500, [:], Data()), // stats: exhausts retries
            (200, [:], officialsBody), (200, [:], commentaryBody),
        ])
        let service = EPLGameCentreService(client: client())
        let update = try await service.fetch(matchID: "2645241", tab: .overview, full: true, lineupsLoaded: false, knownPlayers: [:], commentaryCursor: nil)
        #expect(update.errors["stats"] != nil)
        #expect(update.match != nil)
        #expect(update.events?.isEmpty == false)
        #expect(update.officials?.isEmpty == false)
    }
}
