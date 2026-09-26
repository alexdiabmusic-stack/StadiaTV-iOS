import Foundation
import Testing
@testable import CFLCore

private actor MockCFLClient: CFLClientProtocol {
    private let responses: [String: Data]
    private(set) var requestCount: [String: Int] = [:]
    init(responses: [String: Data]) { self.responses = responses }
    func get<T: Decodable & Sendable>(_ endpoint: CFLEndpoint, as type: T.Type, maxAge: TimeInterval) async throws -> T {
        requestCount[endpoint.path, default: 0] += 1
        guard let data = responses[endpoint.path] else { throw CFLAPIError.invalidResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
private struct FailingLivePlayProvider: CFLLivePlayProvider {
    struct Failure: Error {}
    func drives(fixtureID: String) async throws -> [FootballGameDrive] { throw Failure() }
    func plays(fixtureID: String) async throws -> [FootballPlay] { throw Failure() }
}

@Suite struct CFLServiceTests {
    private func load(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    @Test func seasonIdentityCachesAfterFirstResolution() async throws {
        let mock = MockCFLClient(responses: ["/api/seasons": try load("seasons")])
        let identity = CFLSeasonIdentity(client: mock)
        let first = try await identity.seasonID(for: 2026)
        let second = try await identity.seasonID(for: 2026)
        #expect(first == 75)
        #expect(second == 75)
        let count = await mock.requestCount["/api/seasons"]
        #expect(count == 1)
    }

    @Test func seasonIdentityThrowsForAYearNotInTheList() async throws {
        let mock = MockCFLClient(responses: ["/api/seasons": try load("seasons")])
        let identity = CFLSeasonIdentity(client: mock)
        await #expect(throws: CFLAPIError.self) { try await identity.seasonID(for: 1900) }
    }

    @Test func gameCenterServiceDegradesWhenLivePlayProviderFailsScoreStillLoads() async throws {
        let mock = MockCFLClient(responses: [
            "/api/seasons": try load("seasons"),
            "/api/fixtures/6638": try load("fixture-finished"),
            "/api/teams": try load("teams"),
            "/api/venues": try load("venues"),
        ])
        let service = CFLGameCenterService(client: mock, seasonIdentity: CFLSeasonIdentity(client: mock), livePlayProvider: FailingLivePlayProvider())
        let game = try await service.load(gameID: "6638", date: Date(timeIntervalSince1970: 1_787_961_600), previous: nil, details: true)
        #expect(game.status == .final)
        #expect(game.home.score == 28)
        // The failing PBP provider must not have taken the whole load down.
        #expect(game.plays.isEmpty)
        #expect(game.drives.isEmpty)
    }

    @Test func gameCenterServiceWithNoLivePlayProviderLeavesPlaysEmptyNotCrashing() async throws {
        let mock = MockCFLClient(responses: [
            "/api/seasons": try load("seasons"),
            "/api/fixtures/6638": try load("fixture-finished"),
            "/api/teams": try load("teams"),
            "/api/venues": try load("venues"),
        ])
        let service = CFLGameCenterService(client: mock, seasonIdentity: CFLSeasonIdentity(client: mock))
        let game = try await service.load(gameID: "6638", date: Date(timeIntervalSince1970: 1_787_961_600), previous: nil, details: true)
        #expect(game.plays.isEmpty)
        #expect(game.status == .final)
    }
}
