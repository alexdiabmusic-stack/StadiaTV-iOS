import Foundation
import Testing
import Synchronization
@testable import NFLCore

private final class NFLTestProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var mints = 0
        var gets = 0
        var rejects = 0
        var mintFails = false
        var rateLimited = false
        var expiry = Date().addingTimeInterval(3600).timeIntervalSince1970
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let result: (Int, Data, [String: String]) = Self.state.withLock { state in
            if request.url?.path == "/identity/v3/token" {
                state.mints += 1
                if state.mintFails { return (503, Data(), [:]) }
                let payload = Data("{\"exp\":\(state.expiry),\"n\":\(state.mints)}".utf8).base64EncodedString()
                let data = Data("{\"accessToken\":\"x.\(payload).x\"}".utf8)
                return (200, data, [:])
            }
            state.gets += 1
            if state.rateLimited { return (429, Data(), ["Retry-After": "120"]) }
            if state.rejects > 0 { state.rejects -= 1; return (401, Data(), [:]) }
            return (200, Data("{\"data\":[]}".utf8), [:])
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: result.0, httpVersion: nil, headerFields: result.2) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct NFLAuthTests {
    private func setup() -> (NFLTokenProvider, NFLShieldClient) {
        NFLTestProtocol.state.withLock { $0 = .init() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NFLTestProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokens = NFLTokenProvider(session: session)
        return (tokens, NFLShieldClient(session: session, tokens: tokens))
    }
    @Test func concurrentRequestsShareMintAndReuse() async throws {
        let (tokens, _) = setup()
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await tokens.validToken() } }
            var result: [String] = []
            for try await token in group { result.append(token) }
            return result
        }
        #expect(Set(values).count == 1)
        _ = try await tokens.validToken()
        #expect(NFLTestProtocol.state.withLock { $0.mints } == 1)
    }
    @Test func nearExpiryRenews() async throws {
        let (tokens, _) = setup()
        NFLTestProtocol.state.withLock { $0.expiry = Date().addingTimeInterval(60).timeIntervalSince1970 }
        _ = try await tokens.validToken()
        NFLTestProtocol.state.withLock { $0.expiry = Date().addingTimeInterval(3600).timeIntervalSince1970 }
        _ = try await tokens.validToken()
        #expect(NFLTestProtocol.state.withLock { $0.mints } == 2)
    }
    @Test func staleAuthorizationFailuresShareReplacement() async throws {
        let (tokens, _) = setup()
        let old = try await tokens.validToken()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await tokens.forceRefresh(rejectedToken: old) } }
            try await group.waitForAll()
        }
        #expect(NFLTestProtocol.state.withLock { $0.mints } == 2)
    }
    @Test func unauthorizedRetriesExactlyOnce() async throws {
        let (_, client) = setup()
        NFLTestProtocol.state.withLock { $0.rejects = 1 }
        _ = try await client.get(.seasonResource("rosters", season: 2025), as: NFLValue.self)
        #expect(NFLTestProtocol.state.withLock { $0.mints == 2 && $0.gets == 2 })
    }
    @Test func repeatedUnauthorizedFails() async {
        let (_, client) = setup()
        NFLTestProtocol.state.withLock { $0.rejects = 100 }
        do { _ = try await client.get(.seasonResource("rosters", season: 2025), as: NFLValue.self); Issue.record("Expected controlled auth failure") }
        catch { #expect(error is NFLAPIError) }
        #expect(NFLTestProtocol.state.withLock { $0.mints == 2 && $0.gets == 2 })
    }
    @Test func mintFailureDoesNotGetData() async {
        let (_, client) = setup()
        NFLTestProtocol.state.withLock { $0.mintFails = true }
        do { _ = try await client.get(.seasonResource("rosters", season: 2025), as: NFLValue.self); Issue.record("Expected mint failure") }
        catch { #expect(error is NFLAPIError) }
        #expect(NFLTestProtocol.state.withLock { $0.gets == 0 })
    }
    @Test func rateLimitPreventsAnotherRequest() async {
        let (_, client) = setup()
        NFLTestProtocol.state.withLock { $0.rateLimited = true }
        for _ in 0..<2 {
            do { _ = try await client.get(.seasonResource("rosters", season: 2025), as: NFLValue.self); Issue.record("Expected rate limit") }
            catch { #expect(error is NFLAPIError) }
        }
        #expect(NFLTestProtocol.state.withLock { $0.gets } == 1)
    }
}
