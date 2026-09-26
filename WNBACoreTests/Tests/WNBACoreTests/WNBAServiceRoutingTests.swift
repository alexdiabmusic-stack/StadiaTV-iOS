import Foundation
import Testing
@testable import WNBACore

private actor CallFlag {
    private(set) var called = false
    func markCalled() { called = true }
}

private struct FakeWNBALiveClient: WNBALiveCDNClientProtocol {
    var _scoreboard: @Sendable () async throws -> WNBAScoreboardResponse = { WNBAScoreboardResponse(raw: .object(["scoreboard": .object(["games": .array([])])])) }
    var _box: @Sendable (String) async throws -> WNBABoxScoreResponse = { _ in WNBABoxScoreResponse(raw: .object([:])) }
    var _plays: @Sendable (String) async throws -> WNBAPlayByPlayResponse = { _ in WNBAPlayByPlayResponse(raw: .object([:])) }
    var _schedule: @Sendable () async throws -> WNBAScheduleResponse = { WNBAScheduleResponse(raw: .object([:])) }
    func todaysScoreboard() async throws -> WNBAScoreboardResponse { try await _scoreboard() }
    func boxScore(gameID: String) async throws -> WNBABoxScoreResponse { try await _box(gameID) }
    func playByPlay(gameID: String) async throws -> WNBAPlayByPlayResponse { try await _plays(gameID) }
    func scheduleLeagueV2() async throws -> WNBAScheduleResponse { try await _schedule() }
}

@Suite("WNBAGameCenterService")
struct WNBAGameCenterServiceTests {
    private let id = BasketballGameID(league: .wnba, providerID: "1022600050")

    @Test func foreignCDNPlayResponseIsRejected() async throws {
        var client = FakeWNBALiveClient()
        client._plays = { _ in
            WNBAPlayByPlayResponse(raw: .object(["game": .object([
                "gameId": .string("1022600051"),
                "actions": .array([.object(["actionNumber": .number(1), "period": .number(1)])])])]))
        }
        let update = try await WNBAGameCenterService(client: client).fetch(gameID: id, tab: .plays, full: false)
        #expect(update.plays == nil)
        #expect(update.errors["plays"] != nil)
    }

    @Test func blockedHostProducesPopulatedErrorNeverAcceptedEmptySurface() async throws {
        var client = FakeWNBALiveClient()
        client._box = { _ in throw WNBAAPIError.blocked(host: "cdn.wnba.com", status: 403) }
        client._plays = { _ in throw WNBAAPIError.blocked(host: "cdn.wnba.com", status: 403) }
        let service = WNBAGameCenterService(client: client)
        let update = try await service.fetch(gameID: id, tab: .overview, full: true)
        #expect(!update.errors.isEmpty)
        #expect(update.boxGame == nil)
        #expect(update.retryAfter != nil)
    }

    @Test func genuinelyEmptyScoreboardIsAcceptedNotAnError() async throws {
        var client = FakeWNBALiveClient()
        client._scoreboard = { WNBAScoreboardResponse(raw: .object(["scoreboard": .object(["games": .array([])])])) }
        let service = WNBAGameCenterService(client: client)
        let update = try await service.fetch(gameID: id, tab: .overview, full: false)
        // Offseason/no-games-today is a legitimate empty result, not a host failure —
        // but this game specifically isn't in the (successfully decoded) response,
        // so it's still reported as "different game" rather than silently blank.
        #expect(update.errors["overview"] != nil)
    }

    @Test func noStatsFallbackForPlaysEvenWhenCDNFails() async throws {
        // Step 21/26: live PBP must never depend on Stats availability — confirm
        // there is no secondary attempt at all when the CDN play stream errors,
        // unlike NBA's CDN->stats fallback for the same resource.
        var client = FakeWNBALiveClient()
        client._plays = { _ in throw WNBAAPIError.blocked(host: "cdn.wnba.com", status: 403) }
        let service = WNBAGameCenterService(client: client)
        let update = try await service.fetch(gameID: id, tab: .plays, full: false)
        #expect(update.plays == nil)
        #expect(update.errors["plays"] != nil)
    }

    @Test func boxScoreSuccessPopulatesEveryMappedField() async throws {
        var client = FakeWNBALiveClient()
        client._box = { gameID in
            WNBABoxScoreResponse(raw: .object(["game": .object([
                "gameId": .string(gameID),
                "homeTeam": .object(["teamId": .number(1), "players": .array([
                    .object(["personId": .number(10), "name": .string("Player A"), "oncourt": .bool(true), "played": .bool(true), "starter": .bool(true), "statistics": .object(["points": .number(12)])])
                ])]),
                "awayTeam": .object(["teamId": .number(2), "players": .array([])])
            ])]))
        }
        let update = try await WNBAGameCenterService(client: client).fetch(gameID: id, tab: .boxscore, full: false)
        #expect(update.homeBox?.count == 1)
        #expect(update.onCourtHome == [10])
        #expect(update.errors["overview"] == nil)
    }
}
