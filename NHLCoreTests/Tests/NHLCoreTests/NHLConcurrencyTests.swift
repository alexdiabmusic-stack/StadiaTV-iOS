import Foundation
import Testing
@testable import NHLCore

private func capturedData(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    #endif
    return try Data(contentsOf: url)
}

private func captured(_ name: String) throws -> NHLPlayByPlayResponse {
    try JSONDecoder().decode(NHLPlayByPlayResponse.self, from: capturedData(name))
}

private actor DelayedGameService: NHLGameCenterServing {
    let payload: NHLPlayByPlayResponse
    private(set) var requested: [Int] = []
    init(payload: NHLPlayByPlayResponse) { self.payload = payload }
    func fetch(gameID: Int) async throws -> NHLGameCenterUpdate {
        requested.append(gameID)
        if gameID == payload.game.id {
            // Intentionally ignores cancellation, like an already-delivered delegate callback.
            try? await Task.sleep(for: .milliseconds(100))
            return NHLGameCenterUpdate(gameID: gameID, landing: nil, boxscore: nil, playByPlay: payload, errors: [:], retryAfter: nil)
        }
        return NHLGameCenterUpdate(gameID: gameID, landing: nil, boxscore: nil, playByPlay: nil, errors: ["plays":"Offline"], retryAfter: nil)
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            throw NSError(domain: "NHLTestTimeout", code: 1)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Game Centre lifecycle")
struct NHLLifecycleTests {
    @Test @MainActor func changingGameRejectsInFlightResponse() async throws {
        let payload = try captured("final-play-by-play")
        let service = DelayedGameService(payload: payload)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NHLGameCenterViewModel(service: service, cache: NHLGameCenterCache(directory: directory))
        let first = Task { await model.run(gameID: 2023020204, active: true) }
        try await waitUntil { await service.requested.count == 1 }
        first.cancel()
        let second = Task { await model.run(gameID: 123, active: true) }
        try await waitUntil { model.errors["plays"] == "Offline" }
        await first.value
        #expect(model.snapshot?.gameID == 123)
        #expect(model.snapshot?.game == nil)
        #expect(model.snapshot?.events.isEmpty == true)
        #expect(model.errors["plays"] == "Offline")
        second.cancel()
        await first.value; await second.value
    }

    @Test @MainActor func backgroundStopsAndForegroundRefreshes() async throws {
        let service = DelayedGameService(payload: try captured("live-regulation"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NHLGameCenterViewModel(service: service, cache: NHLGameCenterCache(directory: directory))
        let first = Task { await model.run(gameID: 2023020204, active: true) }
        try await waitUntil { model.snapshot?.game?.status == .live && !model.isRefreshing }
        #expect(model.pollInterval == 18)
        model.selectedTab = .plays
        #expect(model.pollInterval == 10)
        first.cancel(); await first.value
        await model.run(gameID: 2023020204, active: false)
        #expect(await service.requested.count == 1)
        let foreground = Task { await model.run(gameID: 2023020204, active: true) }
        try await waitUntil { await service.requested.count == 2 && !model.isRefreshing }
        #expect(await service.requested.count == 2)
        foreground.cancel(); await foreground.value
    }

    @Test @MainActor func finalStopsAndIntermissionSlowsPolling() async throws {
        for name in ["final-play-by-play", "intermission"] {
            let service = DelayedGameService(payload: try captured(name))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = NHLGameCenterViewModel(service: service, cache: NHLGameCenterCache(directory: directory))
            let task = Task { await model.run(gameID: 2023020204, active: true) }
            try await waitUntil { model.snapshot?.game != nil && !model.isRefreshing }
            if name == "intermission" { #expect(model.pollInterval == 30) }
            else { await task.value; #expect(model.snapshot?.game?.status == .final) }
            task.cancel(); await task.value
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

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
private final class NHLURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("NHL networking", .serialized)
struct NHLNetworkingTests {
    private func client() -> NHLAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NHLURLProtocol.self]
        return NHLAPIClient(session: URLSession(configuration: configuration), baseURL: "https://nhl.invalid/v1")
    }
    @Test func decodeAndMalformedJSON() async throws {
        NHLURLProtocol.responses.set([(200,[:],Data(#"{"games":[]}"#.utf8)),(200,[:],Data("invalid".utf8))])
        let client = client()
        #expect(try await client.score().games.isEmpty)
        do { _ = try await client.score(); Issue.record("Expected decoding error") }
        catch NHLAPIError.decoding { }
    }
    @Test func rateLimitHonorsRetryAfter() async throws {
        NHLURLProtocol.responses.set([(429,["Retry-After":"120"],Data())])
        let client = client()
        for _ in 0..<2 {
            do { _ = try await client.score(); Issue.record("Expected rate limit") }
            catch NHLAPIError.rateLimited(let date) { #expect(date.timeIntervalSinceNow > 110) }
        }
        #expect(NHLURLProtocol.responses.requests == 1)
    }
    @Test func boundedServerRetries() async throws {
        NHLURLProtocol.responses.set([(503,[:],Data()),(503,[:],Data()),(503,[:],Data())])
        do { _ = try await client().score(); Issue.record("Expected HTTP error") }
        catch NHLAPIError.http(let status) { #expect(status == 503) }
        #expect(NHLURLProtocol.responses.requests == 3)
    }
    @Test(arguments: ["playsFailure", "wrongGame", "missingCore"])
    func aggregatorIsolatesEndpointFailures(_ scenario: String) async throws {
        let gameID = 2023020204
        var landing = try #require(JSONSerialization.jsonObject(with: capturedData("final-landing")) as? [String: Any])
        if scenario == "wrongGame" { landing["id"] = 123 }
        if scenario == "missingCore" { landing.removeValue(forKey: "startTimeUTC") }
        let prefix = "/v1/gamecenter/\(gameID)/"
        NHLURLProtocol.responses.setRoutes([
            prefix + "landing": (200, [:], try JSONSerialization.data(withJSONObject: landing)),
            prefix + "boxscore": (200, [:], try capturedData("final-boxscore")),
            prefix + "play-by-play": scenario == "playsFailure"
                ? (404, [:], Data()) : (200, [:], try capturedData("final-play-by-play")),
            prefix + "right-rail": (200, [:], Data("{}".utf8))
        ])
        let update = try await NHLGameCenterService(client: client()).fetch(gameID: gameID)
        #expect(update.boxscore != nil)
        if scenario == "playsFailure" {
            #expect(update.landing != nil)
            #expect(update.playByPlay == nil)
            #expect(update.errors["plays"] != nil)
        } else {
            #expect(update.landing == nil)
            #expect(update.playByPlay != nil)
            #expect(update.errors["landing"] != nil)
        }
        #expect(NHLURLProtocol.responses.requests == 4)
    }

    @Test func cancelledInFlightRequest() async throws {
        NHLURLProtocol.responses.set([(0, [:], Data())])
        let client = client()
        let task = Task { try await client.score() }
        try await waitUntil { NHLURLProtocol.responses.requests == 1 }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        #expect(NHLURLProtocol.responses.requests == 1)
    }
}
