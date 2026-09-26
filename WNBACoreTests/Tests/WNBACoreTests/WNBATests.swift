import Foundation
import Testing
@testable import WNBACore

func fixtureData(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    #endif
    return try Data(contentsOf: url)
}
func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T { try JSONDecoder().decode(type, from: fixtureData(name)) }

@Suite("WNBA fixture normalization")
struct WNBAFixtureTests {
    @Test func scoreboardLiveQ1() throws {
        let response: WNBAScoreboardResponse = try fixture("scoreboard-live-q1.constructed")
        let games = WNBAGameMapper.scoreboard(response)
        #expect(games.count == 1)
        let game = try #require(games.first)
        #expect(game.id.providerID == "1022600050")
        #expect(game.id.league == .wnba)
        #expect(game.status == .live)
        #expect(game.period == 1)
        #expect(game.home.tricode == "CHI"); #expect(game.away.tricode == "WAS")
        #expect(game.homeLeader?.points == 6)
        #expect(game.broadcasts.contains("NBC Sports Chicago"))
    }
    @Test func scoreboardScheduledHasNoScoreYet() throws {
        let response: WNBAScoreboardResponse = try fixture("scoreboard-scheduled.constructed")
        let game = try #require(WNBAGameMapper.scoreboard(response).first)
        #expect(game.status == .scheduled || game.status == .pregame)
        #expect(game.home.score == nil)
        #expect(game.away.score == nil)
    }
    @Test func scoreboardHalftimeStatus() throws {
        let response: WNBAScoreboardResponse = try fixture("scoreboard-halftime.constructed")
        let game = try #require(WNBAGameMapper.scoreboard(response).first)
        #expect(game.status == .halftime)
    }
    @Test func scoreboardSubMinuteClockParsesToTenths() throws {
        let response: WNBAScoreboardResponse = try fixture("scoreboard-live-q4-underminute.constructed")
        let game = try #require(WNBAGameMapper.scoreboard(response).first)
        #expect(game.gameClock == 29.8)
        // Step 5: sub-minute clock shows tenths ("0:29.8"), not truncated whole seconds.
        #expect(NBADuration.clockText("PT00M29.80S") == "0:29.8")
        #expect(game.home.inBonus == true)
    }
    @Test func playoffSeriesContextMappedVerbatim() throws {
        // Step 22: series context is passed through, never independently computed.
        let response: WNBAScoreboardResponse = try fixture("scoreboard-playoff.constructed")
        let game = try #require(WNBAGameMapper.scoreboard(response).first)
        #expect(game.gameLabel == "WNBA Finals")
        #expect(game.seriesGameNumber == "3")
        #expect(game.seriesText == "Series tied 1-1")
    }
    @Test func scheduleNormalizationAndDiscovery() throws {
        let response: WNBAScheduleResponse = try fixture("schedule-cdn.constructed")
        #expect(response.seasonYear == "2026")
        let games = WNBAGameMapper.schedule(response)
        #expect(games.count == 2)
        #expect(Set(games.map(\.id)).count == games.count)
        #expect(games.contains { $0.status == .final })
        #expect(games.contains { $0.status == .scheduled })
    }
    @Test func boxScoreLiveOnCourtAndDNP() throws {
        let response: WNBABoxScoreResponse = try fixture("boxscore-live.constructed")
        let game = try #require(WNBAGameMapper.boxScore(response))
        #expect(game.id.providerID == "1022600050")
        let homeBox = WNBABoxScoreMapper.players(response.homeTeam)
        #expect(homeBox.count == 3)
        let onCourt = WNBABoxScoreMapper.onCourt(response.homeTeam)
        // Step 11: current lineup straight from `oncourt`, not replayed substitutions.
        #expect(onCourt == [1000])
        let dnp = try #require(homeBox.first { $0.isDNP })
        #expect(dnp.notPlayingReason == "INACTIVE_INJURY")
        let leaders = WNBABoxScoreMapper.leaders(homeBox, teamID: game.home.id)
        #expect(leaders.points?.value == 22)
    }
    @Test func boxScoreFinalOvertime() throws {
        let response: WNBABoxScoreResponse = try fixture("boxscore-final-ot.constructed")
        let game = try #require(WNBAGameMapper.boxScore(response))
        #expect(game.status == .final)
        #expect(game.isOvertime)
        #expect(game.finalLabel == "FINAL/OT")
    }
    @Test func boxScoreFinalDoubleOvertimeHasNoHardcodedCeiling() throws {
        let response: WNBABoxScoreResponse = try fixture("boxscore-final-2ot.constructed")
        let game = try #require(WNBAGameMapper.boxScore(response))
        #expect(game.period == 6)
        #expect(game.finalLabel == "FINAL/2OT")
        #expect(game.home.periods.count == 6)
    }
}

@Suite("WNBAStatusMapper")
struct WNBAStatusMapperTests {
    @Test func textTakesPrecedenceOverCode() {
        #expect(WNBAStatusMapper.status(.object(["gameStatus": .number(2), "gameStatusText": .string("Halftime")])) == .halftime)
    }
    @Test func numericFallback() {
        #expect(WNBAStatusMapper.status(.object(["gameStatus": .number(3), "gameStatusText": .string("Final")])) == .final)
        #expect(WNBAStatusMapper.status(.object(["gameStatus": .number(2), "gameStatusText": .string("Q2 5:00")])) == .live)
    }
    @Test func unrecognizedValuePreservedNotDropped() {
        #expect(WNBAStatusMapper.status(.object(["gameStatusText": .string("something new")])) == .scheduled)
        #expect(WNBAStatusMapper.status(.object([:])) == .unknown)
    }
}

@Suite("WNBAPlayMapper")
struct WNBAPlayMapperTests {
    private func loadEvents() throws -> [NBAPlayEvent] {
        let response: WNBAPlayByPlayResponse = try fixture("playbyplay-live.constructed")
        let gameID = try #require(BasketballGameID.validated("1022600050", league: .wnba))
        return WNBAPlayMapper.events(response, gameID: gameID)
    }
    @Test func everyMainEventTypeDisplays() throws {
        let events = try loadEvents()
        #expect(events.contains { $0.type == .madeShot })
        #expect(events.contains { $0.type == .missedShot })
        #expect(events.contains { $0.type == .freeThrow })
        #expect(events.contains { $0.type == .rebound })
        #expect(events.contains { $0.type == .turnover })
        #expect(events.contains { $0.type == .steal })
        #expect(events.contains { $0.type == .block })
        #expect(events.contains { $0.type == .technicalFoul })
        #expect(events.contains { $0.type == .timeout })
        #expect(events.contains { $0.type == .substitution })
        #expect(events.contains { $0.type == .jumpBall })
        #expect(events.contains { $0.type == .periodStart })
        #expect(events.contains { $0.type == .periodEnd })
    }
    @Test func threePointValueRegressionForDescriptiveSubType() throws {
        let events = try loadEvents()
        let three = try #require(events.first { $0.personID == 2000 && $0.type == .madeShot && $0.period == 1 })
        #expect(three.shot?.value == 3)
    }
    @Test func unknownActionTypeNeverDropped() throws {
        let events = try loadEvents()
        let unknown = try #require(events.first { if case .unknown("video_review") = $0.type { return true }; return false })
        #expect(unknown.title.lowercased().contains("review"))
    }
    @Test func idsUniqueAndGameIDTaggedWithLeague() throws {
        let events = try loadEvents()
        #expect(events.count == Set(events.map(\.id)).count)
        #expect(events.allSatisfy { $0.gameID.league == .wnba })
    }
    @Test func dedupesOnRefetch() throws {
        let first = try loadEvents()
        let second = try loadEvents()
        #expect(first.map(\.id) == second.map(\.id))
    }
}

@Suite("WNBABoxScoreMapper")
struct WNBABoxScoreMapperTests {
    @Test func missingStatsRenderAsMissingNotZero() throws {
        let response: WNBABoxScoreResponse = try fixture("boxscore-live.constructed")
        let homeBox = WNBABoxScoreMapper.players(response.homeTeam)
        let dnp = try #require(homeBox.first { $0.isDNP })
        #expect(dnp.stat("points") == nil)
    }
}

@Suite("WNBA/NBA game identity isolation")
struct WNBAIdentityIsolationTests {
    @Test func identicalDigitsDifferentLeagueNeverEqual() {
        // Step 3: never assume NBA and WNBA IDs belong in the same provider namespace.
        let wnba = BasketballGameID(league: .wnba, providerID: "1022600050")
        let nba = BasketballGameID(league: .nba, providerID: "1022600050")
        #expect(wnba != nba)
        #expect(wnba.providerID == nba.providerID) // same digits...
        #expect(wnba.league != nba.league)          // ...but never the same identity
    }
}
