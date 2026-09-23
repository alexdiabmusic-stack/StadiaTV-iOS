import Foundation
import Testing
@testable import NBACore

func fixtureData(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    #endif
    return try Data(contentsOf: url)
}
func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T { try JSONDecoder().decode(type, from: fixtureData(name)) }

@Suite("NBA fixture normalization")
struct NBAFixtureTests {
    @Test func scoreboardNormalization() throws {
        let response: NBAScoreboardResponse = try fixture("scoreboard.constructed")
        let games = NBAGameMapper.scoreboard(response)
        #expect(games.count == 1)
        let game = try #require(games.first)
        #expect(game.id.rawValue == "0022500500")
        #expect(game.status == .live)
        #expect(game.period == 3)
        #expect(game.home.tricode == "LAL"); #expect(game.away.tricode == "BOS")
        #expect(game.home.score == 78); #expect(game.away.score == 81)
        #expect(game.home.periods.count == 3)
        #expect(game.homeLeader?.points == 24)
        #expect(game.broadcasts.contains("Spectrum SportsNet"))
    }
    @Test func emptyOffseasonScoreboardIsGenuinelyEmpty() throws {
        let response: NBAScoreboardResponse = try fixture("scoreboard-empty-offseason.constructed")
        #expect(NBAGameMapper.scoreboard(response).isEmpty)
        #expect(response.gameDate == "2026-09-22")
    }
    @Test func scheduleNormalizationAndDiscovery() throws {
        let response: NBAScheduleResponse = try fixture("schedule-cdn.constructed")
        let games = NBAGameMapper.schedule(response)
        #expect(games.count == 2)
        #expect(Set(games.map(\.id)).count == games.count)
        #expect(games.contains { $0.status == .final })
        #expect(games.contains { $0.status == .scheduled })
    }
    @Test func boxScoreNormalizationLive() throws {
        let response: NBABoxScoreResponse = try fixture("boxscore-live.constructed")
        let game = try #require(NBAGameMapper.boxScore(response))
        #expect(game.id.rawValue == "0022500500")
        let homeBox = NBABoxScoreMapper.players(response.homeTeam)
        #expect(homeBox.count == 3)
        let onCourt = NBABoxScoreMapper.onCourt(response.homeTeam)
        #expect(onCourt.count == 2)
        let dnp = try #require(homeBox.first { $0.isDNP })
        #expect(dnp.notPlayingReason == "INACTIVE_INJURY")
        let leaders = NBABoxScoreMapper.leaders(homeBox, teamID: game.home.id)
        #expect(leaders.points?.value == 24)
    }
    @Test func boxScoreNormalizationFinalOvertime() throws {
        let response: NBABoxScoreResponse = try fixture("boxscore-final-ot.constructed")
        let game = try #require(NBAGameMapper.boxScore(response))
        #expect(game.status == .final)
        #expect(game.isOvertime)
        #expect(game.finalLabel == "FINAL/OT")
    }
    @Test func standingsRowParsing() throws {
        let response: NBAStandingsResponse = try fixture("standings-v3.constructed")
        #expect(response.rows.count == 2)
        let celtics = try #require(response.rows.first { $0.field("TeamAbbreviation").string == "BOS" })
        #expect(celtics.field("WINS").int == 28)
        #expect(celtics.field("Conference").string == "East")
    }
    @Test func rosterRowParsing() throws {
        let response: NBARosterResponse = try fixture("roster.constructed")
        #expect(response.players.count == 2)
        let lebron = try #require(response.players.first { $0.field("PLAYER_ID").int == 2544 })
        #expect(lebron.field("PLAYER").string == "LeBron James")
        #expect(lebron.field("POSITION").string == "F")
    }
}

@Suite("NBACourtCoordinateTransformer")
struct NBACourtCoordinateTransformerTests {
    @Test func normalizesTenthsOfFeetToFeet() {
        let shot = NBACourtCoordinateTransformer.normalize(xLegacy: 120, yLegacy: 230, distanceFeet: 26, made: true, value: 3)
        #expect(shot?.x == 12); #expect(shot?.y == 23)
    }
    @Test func nilWhenEitherCoordinateMissingEvenWithDistance() {
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: nil, yLegacy: 230, distanceFeet: 26, made: true, value: 3) == nil)
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: 120, yLegacy: nil, distanceFeet: 26, made: true, value: 3) == nil)
    }
    @Test func nilOnNonFinite() {
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: .nan, yLegacy: 230, distanceFeet: nil, made: true, value: 3) == nil)
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: 120, yLegacy: .infinity, distanceFeet: nil, made: true, value: 3) == nil)
    }
    @Test func rejectsRatherThanClampsOutOfEnvelope() {
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: 4000, yLegacy: 230, distanceFeet: nil, made: true, value: 2) == nil)
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: 0, yLegacy: -1000, distanceFeet: nil, made: true, value: 2) == nil)
    }
    @Test func zeroZeroSentinelRejectedUnlessNearRimDistance() {
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: 0, yLegacy: 0, distanceFeet: 22, made: true, value: 2) == nil)
        let dunk = NBACourtCoordinateTransformer.normalize(xLegacy: 0, yLegacy: 0, distanceFeet: 0, made: true, value: 2)
        #expect(dunk?.x == 0); #expect(dunk?.y == 0)
    }
    @Test func distanceReconciliationRejectsInconsistentLabel() {
        // 12,23 computes to ~25.7 ft; a labeled distance of 3 ft is wildly inconsistent.
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: 120, yLegacy: 230, distanceFeet: 3, made: true, value: 3) == nil)
    }
    @Test func distanceReconciliationDerivesWhenAbsent() {
        let shot = NBACourtCoordinateTransformer.normalize(xLegacy: 0, yLegacy: 100, distanceFeet: nil, made: true, value: 2)
        #expect(shot?.distanceFeet == 10)
    }
    @Test func rejectsInvalidShotValue() {
        #expect(NBACourtCoordinateTransformer.normalize(xLegacy: 0, yLegacy: 100, distanceFeet: 10, made: true, value: 1) == nil)
    }
}

@Suite("NBAPlayDescriptionBuilder")
struct NBAPlayDescriptionBuilderTests {
    @Test func suppliedDescriptionReturnedVerbatim() {
        let (title, _) = NBAPlayDescriptionBuilder.describe(type: .madeShot, description: "Curry 26' 3PT Jump Shot (12 PTS) (Green 3 AST)",
            playerName: "Curry", assistPlayerName: "Green", blockPlayerName: nil, stealPlayerName: nil, teamTricode: "GSW",
            shotDistance: 26, period: 1, scoreHome: 12, scoreAway: 10)
        #expect(title == "Curry 26' 3PT Jump Shot (12 PTS) (Green 3 AST)")
    }
    @Test func composesOnlyWhenDescriptionAbsent() {
        let (title, _) = NBAPlayDescriptionBuilder.describe(type: .madeShot, description: nil, playerName: "James", assistPlayerName: nil,
            blockPlayerName: nil, stealPlayerName: nil, teamTricode: "LAL", shotDistance: 12, period: 1, scoreHome: nil, scoreAway: nil)
        #expect(title == "James makes a 12-foot shot")
    }
    @Test func freeThrowNeverClaimsMadeOrMissed() {
        let (title, _) = NBAPlayDescriptionBuilder.describe(type: .freeThrow, description: nil, playerName: "Davis", assistPlayerName: nil,
            blockPlayerName: nil, stealPlayerName: nil, teamTricode: nil, shotDistance: nil, period: 1, scoreHome: nil, scoreAway: nil)
        #expect(title == "Davis free throw")
    }
    @Test func halftimeLabelDistinctFromOtherPeriodEnds() {
        let (halftime, _) = NBAPlayDescriptionBuilder.describe(type: .periodEnd, description: nil, playerName: nil, assistPlayerName: nil,
            blockPlayerName: nil, stealPlayerName: nil, teamTricode: nil, shotDistance: nil, period: 2, scoreHome: nil, scoreAway: nil)
        #expect(halftime == "Halftime")
        let (thirdEnd, _) = NBAPlayDescriptionBuilder.describe(type: .periodEnd, description: nil, playerName: nil, assistPlayerName: nil,
            blockPlayerName: nil, stealPlayerName: nil, teamTricode: nil, shotDistance: nil, period: 3, scoreHome: nil, scoreAway: nil)
        #expect(thirdEnd == "End of 3RD")
    }
    @Test func unknownTypeNeverDropped() {
        let (title, _) = NBAPlayDescriptionBuilder.describe(type: .unknown("weird_event"), description: nil, playerName: nil, assistPlayerName: nil,
            blockPlayerName: nil, stealPlayerName: nil, teamTricode: nil, shotDistance: nil, period: 1, scoreHome: nil, scoreAway: nil)
        #expect(title == "Weird event")
    }
    @Test func subtitleOmitsScoreForNonScoringPlays() {
        let (_, subtitle) = NBAPlayDescriptionBuilder.describe(type: .rebound, description: nil, playerName: "Davis", assistPlayerName: nil,
            blockPlayerName: nil, stealPlayerName: nil, teamTricode: "LAL", shotDistance: nil, period: 1, scoreHome: 10, scoreAway: 8)
        #expect(subtitle == "LAL")
    }
    @Test func priorityTable() {
        #expect(NBAPlayDescriptionBuilder.priority(for: .madeShot, subType: nil) == .high)
        #expect(NBAPlayDescriptionBuilder.priority(for: .flagrantFoul, subType: nil) == .high)
        #expect(NBAPlayDescriptionBuilder.priority(for: .missedShot, subType: nil) == .medium)
        #expect(NBAPlayDescriptionBuilder.priority(for: .rebound, subType: nil) == .compact)
        #expect(NBAPlayDescriptionBuilder.priority(for: .turnover, subType: "shot clock") == .medium)
        #expect(NBAPlayDescriptionBuilder.priority(for: .turnover, subType: "bad pass") == .compact)
    }
}

@Suite("NBAPlayMapper")
struct NBAPlayMapperTests {
    @Test func dedupesByGameIDAndActionID() throws {
        let response: NBAPlayByPlayResponse = try fixture("playbyplay-live.constructed")
        let gameID = try #require(NBAProviderGameID("0022500500"))
        let events = NBAPlayMapper.events(response, gameID: gameID)
        #expect(events.count == Set(events.map(\.id)).count)
        #expect(events.count == response.actions.count)
    }
    @Test func replacementOnRefetchDoesNotDuplicate() throws {
        let response: NBAPlayByPlayResponse = try fixture("playbyplay-live.constructed")
        let gameID = try #require(NBAProviderGameID("0022500500"))
        let first = NBAPlayMapper.events(response, gameID: gameID)
        let second = NBAPlayMapper.events(response, gameID: gameID)
        #expect(first.count == second.count)
        #expect(first.map(\.id) == second.map(\.id))
    }
    @Test func threePointValueRegressionForDescriptiveSubType() throws {
        // actionType "3pt" with a descriptive subType ("Pullup Jump shot") must still
        // score as a 3 — this is the actionType.hasPrefix("3") fix in NBAPlayMapper.
        let response: NBAPlayByPlayResponse = try fixture("playbyplay-live.constructed")
        let gameID = try #require(NBAProviderGameID("0022500500"))
        let events = NBAPlayMapper.events(response, gameID: gameID)
        let tatumThree = try #require(events.first { $0.personID == 1628369 && $0.type == .madeShot })
        #expect(tatumThree.shot?.value == 3)
    }
    @Test func sortStableAtEqualClock() {
        let gameID = NBAProviderGameID(unchecked: "0022500500")
        let a = NBAPlayEvent(id: "z", gameID: gameID, actionNumber: 1, orderNumber: 1, period: 1, clockText: "12:00", type: .rebound,
            teamID: nil, teamTricode: nil, personID: nil, playerName: nil, title: "a", subtitle: nil, scoreHome: nil, scoreAway: nil,
            isFieldGoal: false, shot: nil, isPeriodBoundary: false, priority: .compact, assistPlayerName: nil, videoAvailable: false)
        let b = NBAPlayEvent(id: "a", gameID: gameID, actionNumber: 1, orderNumber: 1, period: 1, clockText: "12:00", type: .rebound,
            teamID: nil, teamTricode: nil, personID: nil, playerName: nil, title: "b", subtitle: nil, scoreHome: nil, scoreAway: nil,
            isFieldGoal: false, shot: nil, isPeriodBoundary: false, priority: .compact, assistPlayerName: nil, videoAvailable: false)
        let sorted = NBAPlayMapper.sorted([a, b])
        #expect(sorted.map(\.id) == ["a", "z"])
    }
}

@Suite("NBAStatusMapper")
struct NBAStatusMapperTests {
    @Test func textTakesPrecedenceOverCode() {
        #expect(NBAStatusMapper.status(.object(["gameStatus": .number(2), "gameStatusText": .string("Halftime")])) == .halftime)
        #expect(NBAStatusMapper.status(.object(["gameStatus": .number(2), "gameStatusText": .string("PPD")])) == .postponed)
    }
    @Test func numericFallback() {
        #expect(NBAStatusMapper.status(.object(["gameStatus": .number(3), "gameStatusText": .string("Final")])) == .final)
        #expect(NBAStatusMapper.status(.object(["gameStatus": .number(2), "gameStatusText": .string("Q2 5:00")])) == .live)
    }
    @Test func unrecognizedNonEmptyTextFallsThroughToScheduledRatherThanCrashing() {
        #expect(NBAStatusMapper.status(.object(["gameStatusText": .string("something new")])) == .scheduled)
    }
    @Test func noTextAndNoCodeFallsThroughToUnknown() {
        #expect(NBAStatusMapper.status(.object([:])) == .unknown)
    }
}

@Suite("NBADuration")
struct NBADurationTests {
    @Test func parsesMinutesAndSeconds() {
        #expect(NBADuration.seconds("PT11M32.00S") == 692)
        #expect(NBADuration.clockText("PT11M32.00S") == "11:32")
    }
    @Test func periodLabelsHaveNoOvertimeCeiling() {
        #expect(NBADuration.periodLabel(1) == "Q1")
        #expect(NBADuration.periodLabel(4) == "Q4")
        #expect(NBADuration.periodLabel(5) == "OT")
        #expect(NBADuration.periodLabel(6) == "2OT")
    }
    @Test func ordinalPeriodLabels() {
        #expect(NBADuration.ordinalPeriodLabel(1) == "1ST")
        #expect(NBADuration.ordinalPeriodLabel(3) == "3RD")
        #expect(NBADuration.ordinalPeriodLabel(5) == "OT")
    }
}

@Suite("NBABoxScoreMapper")
struct NBABoxScoreMapperTests {
    @Test func missingStatsRenderAsMissingNotZero() throws {
        let response: NBABoxScoreResponse = try fixture("boxscore-live.constructed")
        let homeBox = NBABoxScoreMapper.players(response.homeTeam)
        let dnp = try #require(homeBox.first { $0.isDNP })
        #expect(dnp.stat("points") == nil)
    }
}
