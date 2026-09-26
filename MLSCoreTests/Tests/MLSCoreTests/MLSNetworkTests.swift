import Foundation
import Testing
@testable import MLSCore

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
private final class MLSURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("MLS networking", .serialized)
struct MLSNetworkTests {
    private func client() -> MLSStatsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MLSURLProtocol.self]
        return MLSStatsClient(session: URLSession(configuration: configuration))
    }

    @Test func rateLimitStopsLocalRetrying() async throws {
        MLSURLProtocol.responses.set([(429, ["Retry-After": "30"], Data())])
        let api = client()
        do {
            _ = try await api.match("MLS-MAT-0009LX")
            Issue.record("Expected a rate-limit error")
        } catch MLSAPIError.rateLimited(let date) {
            #expect(date > Date())
        }
        #expect(MLSURLProtocol.responses.requests == 1) // no local retry on 429 — caller backs off instead
    }

    @Test func badRequestAndNotFoundMapErrorMessage() async throws {
        let badRequestBody = Data("""
        {"error_code":"MLS-001-ERR","message":"validating query parameters: Field 'Type' failed validation","error":"Bad Request"}
        """.utf8)
        MLSURLProtocol.responses.set([(400, [:], badRequestBody)])
        do { _ = try await client().match("x"); Issue.record("Expected badRequest") }
        catch MLSAPIError.badRequest(let detail) { #expect(detail.contains("validating query parameters")) }

        let notFoundBody = Data("""
        {"error_code":"MLS-002-ERR","message":"Requested resource does not exist","error":"Not found"}
        """.utf8)
        MLSURLProtocol.responses.set([(404, [:], notFoundBody)])
        do { _ = try await client().match("MLS-MAT-9999999"); Issue.record("Expected notFound") }
        catch MLSAPIError.notFound(let detail) { #expect(detail.contains("does not exist")) }
    }

    @Test func malformedJSONIsADecodingErrorNotACrash() async throws {
        MLSURLProtocol.responses.set([(200, [:], Data("not JSON".utf8))])
        do { _ = try await client().match("MLS-MAT-0009LX"); Issue.record("Expected decoding error") }
        catch MLSAPIError.decoding { /* expected */ }
    }

    @Test func serverErrorRetriesWithBoundedAttempts() async throws {
        let ok = Data("""
        {"match_information":{"match_id":"MLS-MAT-0009LX"}}
        """.utf8)
        MLSURLProtocol.responses.set([(503, [:], Data()), (503, [:], Data()), (200, [:], ok)])
        let value = try await client().match("MLS-MAT-0009LX")
        #expect(value["match_information"]["match_id"].string == "MLS-MAT-0009LX")
        #expect(MLSURLProtocol.responses.requests == 3)
    }

    @Test func cancellationDoesNotRetry() async throws {
        MLSURLProtocol.responses.set([(0, [:], Data())])
        let api = client()
        let task = Task { try await api.match("MLS-MAT-0009LX") }
        for _ in 0..<100 where MLSURLProtocol.responses.requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(MLSURLProtocol.responses.requests == 1)
    }

    @Test func oneFailingResourceDoesNotFailTheWholeAggregatorFetch() async throws {
        // A full-refresh fetch of a finished (non-live, non-shootout) match makes
        // exactly 5 calls in this order: overview, key_events, team stats, player
        // stats, commentary — team stats failing must not take down the rest.
        let overviewBody = try fixtureData("match-overview-fulltime")
        let eventsBody = try fixtureData("key-events")
        let playerStatsBody = try fixtureData("player-match-stats")
        let commentaryBody = try fixtureData("commentary")
        MLSURLProtocol.responses.set([
            (200, [:], overviewBody), (200, [:], eventsBody),
            (500, [:], Data()), (500, [:], Data()), (500, [:], Data()), // team stats: exhausts retries
            (200, [:], playerStatsBody), (200, [:], commentaryBody),
        ])
        let service = MLSGameCentreService(client: client())
        let update = try await service.fetch(matchID: "MLS-MAT-0009LX", tab: .overview, full: true, lineupsLoaded: false, knownPlayers: [:], commentaryCursor: nil)
        #expect(update.errors["stats"] != nil)
        #expect(update.match != nil)
        #expect(update.events?.isEmpty == false)
        #expect(update.playerMatchStats?.isEmpty == false)
        #expect(update.commentary?.isEmpty == false)
        #expect(update.homeLineup != nil)  // bundled in the overview response, unaffected by the stats failure
    }
}
