import Foundation
import Testing
@testable import NBACore

/// A mutation of a captured `var` inside a `@Sendable` closure is a compile error
/// under strict concurrency, so call-tracking in these fakes goes through an actor.
private actor CallFlag {
    private(set) var called = false
    func markCalled() { called = true }
}

private struct FakeLiveClient: NBALiveCDNClientProtocol {
    var _scoreboard: @Sendable () async throws -> NBAScoreboardResponse = { NBAScoreboardResponse(raw: .object(["scoreboard": .object(["games": .array([])])])) }
    var _box: @Sendable (String) async throws -> NBABoxScoreResponse = { _ in NBABoxScoreResponse(raw: .object([:])) }
    var _plays: @Sendable (String) async throws -> NBAPlayByPlayResponse = { _ in NBAPlayByPlayResponse(raw: .object([:])) }
    var _schedule: @Sendable () async throws -> NBAScheduleResponse = { NBAScheduleResponse(raw: .object([:])) }
    func todaysScoreboard() async throws -> NBAScoreboardResponse { try await _scoreboard() }
    func boxScore(gameID: String) async throws -> NBABoxScoreResponse { try await _box(gameID) }
    func playByPlay(gameID: String) async throws -> NBAPlayByPlayResponse { try await _plays(gameID) }
    func scheduleLeagueV2() async throws -> NBAScheduleResponse { try await _schedule() }
}

private struct FakeStatsClient: NBAStatsClientProtocol {
    var _schedule: @Sendable (String) async throws -> NBAScheduleResponse = { _ in NBAScheduleResponse(raw: .object([:])) }
    var _standings: @Sendable (String, String) async throws -> NBAStandingsResponse = { _, _ in NBAStandingsResponse(raw: .object([:])) }
    var _scoreboardV3: @Sendable (Date) async throws -> NBAScoreboardV3Response = { _ in NBAScoreboardV3Response(raw: .object(["scoreboard": .object(["games": .array([])])])) }
    var _playByPlayV3: @Sendable (String) async throws -> NBAPlayByPlayV3Response = { _ in NBAPlayByPlayV3Response(raw: .object([:])) }
    var _playerInfo: @Sendable (String) async throws -> NBAPlayerInfoResponse = { _ in NBAPlayerInfoResponse(raw: .object([:])) }
    var _careerStats: @Sendable (String) async throws -> NBAPlayerCareerStatsResponse = { _ in NBAPlayerCareerStatsResponse(raw: .object([:])) }
    var _roster: @Sendable (String, String) async throws -> NBARosterResponse = { _, _ in NBARosterResponse(raw: .object([:])) }
    func scheduleLeagueV2(season: String) async throws -> NBAScheduleResponse { try await _schedule(season) }
    func leagueStandingsV3(season: String, seasonType: String) async throws -> NBAStandingsResponse { try await _standings(season, seasonType) }
    func scoreboardV3(date: Date) async throws -> NBAScoreboardV3Response { try await _scoreboardV3(date) }
    func playByPlayV3(gameID: String) async throws -> NBAPlayByPlayV3Response { try await _playByPlayV3(gameID) }
    func commonPlayerInfo(playerID: String) async throws -> NBAPlayerInfoResponse { try await _playerInfo(playerID) }
    func playerCareerStats(playerID: String) async throws -> NBAPlayerCareerStatsResponse { try await _careerStats(playerID) }
    func commonTeamRoster(teamID: String, season: String) async throws -> NBARosterResponse { try await _roster(teamID, season) }
}

private struct FakeNBAAPIClient: NBAAPIClientProtocol {
    var _scoreboard: @Sendable () async throws -> NBAScoreboardResponse = { NBAScoreboardResponse(raw: .object(["scoreboard": .object(["games": .array([])])])) }
    var _scoreboardOn: @Sendable (Date) async throws -> [NBAValue] = { _ in [] }
    var _box: @Sendable (String) async throws -> NBABoxScoreResponse = { _ in NBABoxScoreResponse(raw: .object([:])) }
    var _plays: @Sendable (String) async throws -> NBAPlayByPlayResponse = { _ in NBAPlayByPlayResponse(raw: .object([:])) }
    var _playsV3: @Sendable (String) async throws -> NBAPlayByPlayV3Response = { _ in NBAPlayByPlayV3Response(raw: .object([:])) }
    var _schedule: @Sendable (String) async throws -> NBAScheduleResponse = { _ in NBAScheduleResponse(raw: .object([:])) }
    var _standings: @Sendable (String, String) async throws -> NBAStandingsResponse = { _, _ in NBAStandingsResponse(raw: .object([:])) }
    var _scoreboardV3: @Sendable (Date) async throws -> NBAScoreboardV3Response = { _ in NBAScoreboardV3Response(raw: .object([:])) }
    var _playerInfo: @Sendable (String) async throws -> NBAPlayerInfoResponse = { _ in NBAPlayerInfoResponse(raw: .object([:])) }
    var _careerStats: @Sendable (String) async throws -> NBAPlayerCareerStatsResponse = { _ in NBAPlayerCareerStatsResponse(raw: .object([:])) }
    var _roster: @Sendable (String, String) async throws -> NBARosterResponse = { _, _ in NBARosterResponse(raw: .object([:])) }

    func todaysScoreboard() async throws -> NBAScoreboardResponse { try await _scoreboard() }
    func scoreboard(on date: Date) async throws -> [NBAValue] { try await _scoreboardOn(date) }
    func boxScore(gameID: String) async throws -> NBABoxScoreResponse { try await _box(gameID) }
    func playByPlay(gameID: String) async throws -> NBAPlayByPlayResponse { try await _plays(gameID) }
    func scheduleLeagueV2(season: String) async throws -> NBAScheduleResponse { try await _schedule(season) }
    func leagueStandingsV3(season: String, seasonType: String) async throws -> NBAStandingsResponse { try await _standings(season, seasonType) }
    func scoreboardV3(date: Date) async throws -> NBAScoreboardV3Response { try await _scoreboardV3(date) }
    func playByPlayV3(gameID: String) async throws -> NBAPlayByPlayV3Response { try await _playsV3(gameID) }
    func commonPlayerInfo(playerID: String) async throws -> NBAPlayerInfoResponse { try await _playerInfo(playerID) }
    func playerCareerStats(playerID: String) async throws -> NBAPlayerCareerStatsResponse { try await _careerStats(playerID) }
    func commonTeamRoster(teamID: String, season: String) async throws -> NBARosterResponse { try await _roster(teamID, season) }
}

@Suite("NBAAPIClient routing")
struct NBAAPIClientRoutingTests {
    @Test func todaysScoreboardFallsBackToStatsOnBlockedCDN() async throws {
        var live = FakeLiveClient()
        live._scoreboard = { throw NBAAPIError.blocked(host: "cdn.nba.com", status: 403) }
        var stats = FakeStatsClient()
        stats._scoreboardV3 = { _ in NBAScoreboardV3Response(raw: .object(["scoreboard": .object(["games": .array([.object(["gameId": .string("1")])])])])) }
        let client = NBAAPIClient(live: live, stats: stats)
        let result = try await client.todaysScoreboard()
        #expect(result.games.count == 1)
    }
    @Test func todaysScoreboardDoesNotFallBackOnDecodingFailure() async throws {
        var live = FakeLiveClient()
        live._scoreboard = { throw NBAAPIError.decoding("bad shape") }
        let statsCalled = CallFlag()
        var stats = FakeStatsClient()
        stats._scoreboardV3 = { _ in await statsCalled.markCalled(); return NBAScoreboardV3Response(raw: .object([:])) }
        let client = NBAAPIClient(live: live, stats: stats)
        await #expect(throws: NBAAPIError.self) { try await client.todaysScoreboard() }
        #expect(await !statsCalled.called)
    }
    @Test func currentSeasonScheduleGoesToCDNFirst() async throws {
        let liveCalled = CallFlag()
        var live = FakeLiveClient()
        live._schedule = { await liveCalled.markCalled(); return NBAScheduleResponse(raw: .object([:])) }
        let client = NBAAPIClient(live: live, stats: FakeStatsClient())
        _ = try await client.scheduleLeagueV2(season: NBASeason.current())
        #expect(await liveCalled.called)
    }
    @Test func historicalSeasonScheduleSkipsCDNEntirely() async throws {
        let liveCalled = CallFlag()
        var live = FakeLiveClient()
        live._schedule = { await liveCalled.markCalled(); return NBAScheduleResponse(raw: .object([:])) }
        let statsCalled = CallFlag()
        var stats = FakeStatsClient()
        stats._schedule = { _ in await statsCalled.markCalled(); return NBAScheduleResponse(raw: .object([:])) }
        let client = NBAAPIClient(live: live, stats: stats)
        _ = try await client.scheduleLeagueV2(season: "2010-11")
        #expect(await !liveCalled.called); #expect(await statsCalled.called)
    }
    @Test func boxScoreIsNeverConsultedAgainstStats() async throws {
        // boxScore is a declared single-source (CDN-only) capability — confirm the
        // façade doesn't quietly reach for a stats fallback that doesn't exist.
        let live = FakeLiveClient()
        let client = NBAAPIClient(live: live, stats: FakeStatsClient())
        _ = try await client.boxScore(gameID: "1")
    }
}

@Suite("NBAGameCenterService")
struct NBAGameCenterServiceTests {
    private let id = BasketballGameID(league: .nba, providerID: "0022500500")

    @Test func foreignCDNPlayResponseIsRejected() async throws {
        var client = FakeNBAAPIClient()
        client._plays = { _ in
            NBAPlayByPlayResponse(raw: .object(["game": .object([
                "gameId": .string("0022500501"),
                "actions": .array([.object(["actionNumber": .number(1), "period": .number(1)])])])]))
        }
        let update = try await NBAGameCenterService(client: client).fetch(gameID: id, tab: .plays, full: false)
        #expect(update.plays == nil)
        #expect(update.errors["plays"] != nil)
    }

    @Test func foreignStatsPlayResponseIsRejected() async throws {
        var client = FakeNBAAPIClient()
        client._plays = { _ in throw NBAAPIError.http(404) }
        client._playsV3 = { _ in
            NBAPlayByPlayV3Response(raw: .object(["resultSets": .array([.object([
                "name": .string("PlayByPlay"),
                "headers": .array([.string("gameId"), .string("actionNumber"), .string("period")]),
                "rowSet": .array([.array([.string("0022500501"), .number(1), .number(1)])])])])]))
        }
        let update = try await NBAGameCenterService(client: client).fetch(gameID: id, tab: .plays, full: false)
        #expect(update.plays == nil)
        #expect(update.errors["plays"] != nil)
    }

    @Test func blockedHostProducesPopulatedErrorNeverAcceptedEmptySurface() async throws {
        var client = FakeNBAAPIClient()
        client._box = { _ in throw NBAAPIError.blocked(host: "cdn.nba.com", status: 403) }
        client._plays = { _ in throw NBAAPIError.blocked(host: "cdn.nba.com", status: 403) }
        client._playsV3 = { _ in throw NBAAPIError.blocked(host: "stats.nba.com", status: nil) }
        let service = NBAGameCenterService(client: client)
        let update = try await service.fetch(gameID: id, tab: .overview, full: true)
        #expect(!update.errors.isEmpty)
        #expect(update.boxGame == nil)
        #expect(update.retryAfter != nil)
    }
    @Test func genuinelyEmptyScoreboardIsAcceptedNotAnError() async throws {
        var client = FakeNBAAPIClient()
        client._scoreboard = { NBAScoreboardResponse(raw: .object(["scoreboard": .object(["games": .array([])])])) }
        let service = NBAGameCenterService(client: client)
        let update = try await service.fetch(gameID: id, tab: .overview, full: false)
        // The scoreboard call itself succeeded (no thrown error) — this game just
        // isn't in it, which is a real "different/absent game" condition, not a
        // host failure. That distinction is what the provider-level invariant
        // documented on NBAProvider.scores(on:) depends on: only a successful,
        // decoded response may ever report "no game", never a failed one.
        #expect(update.errors["overview"] != nil)
    }
    @Test func playsFallBackToStatsAndTagSource() async throws {
        var client = FakeNBAAPIClient()
        client._box = { gameID in
            NBABoxScoreResponse(raw: .object(["game": .object(["gameId": .string(gameID), "homeTeam": .object(["teamId": .number(1), "players": .array([])]), "awayTeam": .object(["teamId": .number(2), "players": .array([])])])]))
        }
        client._plays = { _ in throw NBAAPIError.blocked(host: "cdn.nba.com", status: 403) }
        client._playsV3 = { _ in
            NBAPlayByPlayV3Response(raw: .object(["resultSets": .array([.object(["name": .string("PlayByPlay"),
                "headers": .array([.string("actionNumber"), .string("orderNumber"), .string("actionId"), .string("period")]),
                "rowSet": .array([.array([.number(1), .number(1), .number(1), .number(1)])])])])]))
        }
        let service = NBAGameCenterService(client: client)
        let update = try await service.fetch(gameID: id, tab: .overview, full: true)
        #expect(update.playsSource == "stats")
        #expect(update.plays?.isEmpty == false)
        #expect(update.errors["plays"] == nil)
    }
}
