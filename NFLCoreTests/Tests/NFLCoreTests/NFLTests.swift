import Foundation
import Testing
@testable import NFLCore

@Suite struct NFLMappingTests {
    func fixture() throws -> NFLWeeklyResponse {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/regular-final.json")
        return try JSONDecoder().decode(NFLWeeklyResponse.self, from: Data(contentsOf: url))
    }
    @Test func finalSummaryOverridesScheduledMetadata() throws {
        let response = try fixture()
        let raw = try #require(response.games.first)
        let game = try #require(NFLGameMapper.game(raw))
        #expect(game.status == .final)
        #expect(game.home.score == 24)
        #expect(game.away.score == 20)
        #expect(game.drives.count == 16)
        #expect(game.plays.contains { $0.type == .touchdown })
        #expect(Set(game.plays.map(\.id)).count == game.plays.count)
    }
    @Test func nativeSeasonParameterNames() throws {
        let week = NFLWeek(season: 2026, seasonType: .regular, week: 2)
        let weekly = try NFLEndpoint.weekly(week).url().absoluteString
        let summary = try NFLEndpoint.resource("stats/live/game-summaries", week: week).url().absoluteString
        #expect(weekly.contains("type=REG")); #expect(summary.contains("seasonType=REG"))
        #expect(!weekly.contains("seasonType="))
    }
    @Test func unknownStatusAndPlaySurvive() {
        #expect(NFLGameMapper.status("NEW_STATUS") == .unknown)
        #expect(NFLPlayMapper.type("FUTURE", scoring: nil, text: "Something new") == .unknown("FUTURE"))
    }
    @Test func jwtExpirationIsOnlyReadLocally() {
        let payload = Data("{\"exp\":2000000000}".utf8).base64EncodedString()
        #expect(NFLTokenProvider.expiration("x.\(payload).x") == Date(timeIntervalSince1970: 2000000000))
        #expect(NFLTokenProvider.expiration("invalid") == nil)
    }
    @Test func staleAndWrongGameSummaryRejected() throws {
        let response = try fixture()
        let raw = try #require(response.games.first)
        let game = try #require(NFLGameMapper.game(raw))
        let wrong: NFLValue = .object(["gameId": .string("other"), "phase": .string("LIVE")])
        #expect(NFLGameMapper.applySummary(wrong, to: game) == game)
        let stale: NFLValue = .object(["gameId": .string(game.id), "offset": .number(1), "phase": .string("LIVE")])
        #expect(NFLGameMapper.applySummary(stale, to: game) == game)
    }
    @Test func playerTotalsMatchNFLGamebook() throws {
        let response = try fixture()
        let raw = try #require(response.games.first)
        let game = try #require(NFLGameMapper.game(raw))
        let players = NFLStatisticsMapper.players(game.plays)
        let prescott = try #require(players.first { $0.name == "D.Prescott" })
        #expect(prescott.passingAttempts == 34 && prescott.completions == 21 && prescott.passingYards == 188)
        let hurts = try #require(players.first { $0.name == "J.Hurts" })
        #expect(hurts.rushingYards == 62 && hurts.carries == 14 && hurts.rushingTouchdowns == 2)
        let lamb = try #require(players.first { $0.name == "C.Lamb" })
        #expect(lamb.receptions == 7 && lamb.receivingYards == 110)
        let anger = try #require(players.first { $0.name == "B.Anger" })
        #expect(anger.punts == 2 && anger.puntYards == 87)
    }
    @Test func statusBoundaryFixtures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/status-cases.json")
        let cases = try JSONDecoder().decode([NFLValue].self, from: Data(contentsOf: url))
        let response = try fixture()
        let raw = try #require(response.games.first)
        for value in cases {
            var object = raw.object, summary = raw["summary"].object
            summary["phase"] = value["phase"]; object["summary"] = .object(summary); object["seasonType"] = value["seasonType"]
            let game = try #require(NFLGameMapper.game(.object(object)))
            #expect(game.week.seasonType.rawValue == value["seasonType"].string)
            #expect(game.status == NFLGameMapper.status(value["phase"].string))
        }
        #expect(NFLGameMapper.status("INGAME", quarter: "END_OF_HALF") == .halftime)
    }
    @Test func missingOptionalDataAndAdditionalKeys() throws {
        let response = try fixture()
        var raw = try #require(response.games.first).object
        raw["driveChart"] = .null; raw["summary"] = .null; raw["futureField"] = .array([.bool(true)])
        let game = try #require(NFLGameMapper.game(.object(raw)))
        #expect(game.plays.isEmpty && game.drives.isEmpty && game.home.score == nil)
    }
    @Test func fieldPositionUsesTeamIdentityAndPossession() throws {
        let response = try fixture()
        let raw = try #require(response.games.first)
        let game = try #require(NFLGameMapper.game(raw))
        #expect(NFLGameMapper.field("DAL 15", possession: game.home, home: game.home, away: game.away)?.yardsToGoal == 15)
        #expect(NFLGameMapper.field("PHI 15", possession: game.home, home: game.home, away: game.away)?.yardsToGoal == 85)
        #expect(NFLGameMapper.field("FUTURE 15", possession: game.home, home: game.home, away: game.away)?.yardsToGoal == nil)
    }
    @Test func topLevelResponseShapes() throws {
        let response = try fixture()
        for raw in [NFLValue.array(response.games), .object(["games": .array(response.games)]), .object(["data": .array(response.games)])] {
            let decoded = try JSONDecoder().decode(NFLWeeklyResponse.self, from: JSONEncoder().encode(raw))
            #expect(decoded.games.count == 1)
        }
    }
    @Test func recordedPlayCategories() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/representative-plays.json")
        let cases = try JSONDecoder().decode([NFLValue].self, from: Data(contentsOf: url))
        let expected: [String: FootballPlayType] = ["rush": .run, "pass": .pass, "incomplete": .passIncomplete, "sack": .sack,
            "punt": .punt, "kickoff": .kickoff, "touchdown": .touchdown, "field_goal": .fieldGoal,
            "missed_field_goal": .fieldGoalMissed, "extra_point": .extraPoint, "two_point": .twoPoint,
            "interception": .interception, "fumble_lost": .fumble, "fumble_retained": .fumble,
            "penalty": .penalty, "timeout": .timeout, "end_quarter": .quarterEnd, "end_game": .gameEnd]
        for value in cases {
            let name = try #require(value["case"].string)
            let mapped = NFLPlayMapper.plays(.array([value["play"]]), gameID: "fixture", drives: [])
            let play = try #require(mapped.first)
            #expect(!play.text.isEmpty)
            if let type = expected[name] { #expect(play.type == type, "Case: \(name)") }
            if ["interception", "fumble_lost", "downs"].contains(name) { #expect(play.turnover) }
            if name == "fumble_retained" { #expect(!play.turnover) }
            if ["penalty", "declined", "offsetting"].contains(name) { #expect(play.penalty) }
        }
        #expect(cases.count == 23)
    }
    @Test func nestedDifferentGameIdentityRejected() throws {
        let response = try fixture()
        var raw = try #require(response.games.first).object
        var summary = raw["summary"]?.object ?? [:]; summary["gameId"] = .string("other"); raw["summary"] = .object(summary)
        #expect(NFLGameMapper.game(.object(raw)) == nil)
    }
    @Test func correctionAndDeletion() {
        func value(_ yards: Double, deleted: Bool = false) -> NFLValue {
            .object(["playId": .number(72), "playSequenceNumber": .number(72), "playType": .string("RUSH"), "yardsGained": .number(yards), "playDeleted": .bool(deleted)])
        }
        let plays = NFLPlayMapper.plays(.array([value(4), value(7)]), gameID: "game", drives: [])
        #expect(plays.count == 1); #expect(plays.first?.yards == 7)
        #expect(NFLPlayMapper.plays(.array([value(4), value(0, deleted: true)]), gameID: "game", drives: []).isEmpty)
    }
}
