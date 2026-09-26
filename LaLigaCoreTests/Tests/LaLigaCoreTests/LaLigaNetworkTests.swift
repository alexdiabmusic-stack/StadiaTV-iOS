import Foundation
import Testing
@testable import LaLigaCore

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
// Two independent stub classes (not one shared class) since Swift Testing runs
// different `@Suite`s concurrently by default — `.serialized` only orders tests
// *within* a suite, so LaLiga's and FotMob's network suites need their own
// isolated static response queues or they corrupt each other's request counts.
private final class LaLigaStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let responses = ResponseQueue()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, data) = Self.responses.next()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class FotMobStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let responses = ResponseQueue()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, headers, data) = Self.responses.next()
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("LaLiga official-API networking", .serialized)
struct LaLigaNetworkTests {
    private func client() -> LaLigaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LaLigaStubURLProtocol.self]
        return LaLigaClient(session: URLSession(configuration: configuration))
    }

    @Test func unauthorizedTripsCircuitBreakerWithoutImmediateRetry() async throws {
        LaLigaStubURLProtocol.responses.set([(401, [:], Data())])
        let api = client()
        do { _ = try await api.standing(subscriptionSlug: "laliga-easports-2026"); Issue.record("Expected unauthorized") }
        catch LaLigaAPIError.unauthorized { /* expected */ }
        // A second call within the cooldown window must short-circuit locally —
        // never a second network request for a key that's already been rejected (Step 34).
        do { _ = try await api.standing(subscriptionSlug: "laliga-easports-2026"); Issue.record("Expected unauthorized") }
        catch LaLigaAPIError.unauthorized { /* expected */ }
        #expect(LaLigaStubURLProtocol.responses.requests == 1)
    }

    @Test func rateLimitStopsLocalRetrying() async throws {
        LaLigaStubURLProtocol.responses.set([(429, ["Retry-After": "30"], Data())])
        let api = client()
        do { _ = try await api.matches(subscriptionSlug: "laliga-easports-2026"); Issue.record("Expected rate-limit error") }
        catch LaLigaAPIError.rateLimited(let date) { #expect(date > Date()) }
        #expect(LaLigaStubURLProtocol.responses.requests == 1)
    }

    @Test func serverErrorRetriesWithBoundedAttempts() async throws {
        let ok = Data("""
        {"total":1,"standings":[]}
        """.utf8)
        LaLigaStubURLProtocol.responses.set([(503, [:], Data()), (503, [:], Data()), (200, [:], ok)])
        let value = try await client().standing(subscriptionSlug: "laliga-easports-2026")
        #expect(value["total"].int == 1)
        #expect(LaLigaStubURLProtocol.responses.requests == 3)
    }

    @Test func malformedJSONIsADecodingErrorNotACrash() async throws {
        LaLigaStubURLProtocol.responses.set([(200, [:], Data("not JSON".utf8))])
        do { _ = try await client().standing(subscriptionSlug: "x"); Issue.record("Expected decoding error") }
        catch LaLigaAPIError.decoding { /* expected */ }
    }
}

@Suite("FotMob networking", .serialized)
struct FotMobNetworkTests {
    private func client() -> FotMobClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FotMobStubURLProtocol.self]
        return FotMobClient(session: URLSession(configuration: configuration))
    }

    @Test func missingTickerFileMapsToNotFoundNeverCrashes() async throws {
        // A 403 from FotMob's CDN (observed live 2026-09-24 for a wrong lang code)
        // means "no such object" here, not a real auth failure — mapped to
        // `.notFound` so callers can degrade gracefully (Step 14/26).
        FotMobStubURLProtocol.responses.set([(403, [:], Data())])
        do { _ = try await client().liveTickerRaw(ltcUrl: "https://data.fotmob.com/webcl/ltc/gsm/x_en.json.gz"); Issue.record("Expected notFound") }
        catch FotMobAPIError.notFound { /* expected */ }
    }

    @Test func rateLimitStopsLocalRetrying() async throws {
        FotMobStubURLProtocol.responses.set([(429, ["Retry-After": "10"], Data())])
        do { _ = try await client().matchDetails(matchId: "1"); Issue.record("Expected rate-limit error") }
        catch FotMobAPIError.rateLimited(let date) { #expect(date > Date()) }
        #expect(FotMobStubURLProtocol.responses.requests == 1)
    }

    @Test func serverErrorRetriesWithBoundedAttempts() async throws {
        let ok = Data("""
        {"general":{"matchId":"1"}}
        """.utf8)
        FotMobStubURLProtocol.responses.set([(503, [:], Data()), (503, [:], Data()), (200, [:], ok)])
        let value = try await client().matchDetails(matchId: "1")
        #expect(value["general"]["matchId"].string == "1")
        #expect(FotMobStubURLProtocol.responses.requests == 3)
    }
}
