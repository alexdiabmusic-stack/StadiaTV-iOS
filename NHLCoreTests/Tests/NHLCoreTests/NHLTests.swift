import Foundation
import Testing
@testable import NHLCore

private func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    #if SWIFT_PACKAGE
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    #endif
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

@Suite("NHL fixtures and normalization")
struct NHLFixtureTests {
    @Test(arguments: ["final-play-by-play", "live-regulation", "intermission", "overtime", "shootout", "pregame"])
    func decodeStates(_ name: String) throws {
        let response: NHLPlayByPlayResponse = try fixture(name)
        let game = try #require(NHLGameMapper.game(response.game))
        #expect(game.id == response.game.id)
        #expect(game.home.id != game.away.id)
        if name == "pregame" { #expect(game.status == .scheduled || game.status == .pregame) }
        if name == "intermission" { #expect(game.intermission) }
        if name == "final-play-by-play" { #expect(game.status == .final) }
        if name == "overtime" { #expect(game.period.kind == .overtime) }
        if name == "shootout" { #expect(game.period.kind == .shootout) }
    }

    @Test func discoveryUsesNHLIDs() throws {
        let score: NHLScoreResponse = try fixture("score")
        #expect(score.games.count == 1)
        #expect(score.games.first?.id == 2023020573)
    }

    @Test func realGoalMergeAndRoster() throws {
        let plays: NHLPlayByPlayResponse = try fixture("final-play-by-play")
        let landing: NHLGameDTO = try fixture("final-landing")
        let events = NHLPlayMapper.events(plays, landing: landing)
        let goals = events.filter { $0.eventType == .goal }
        #expect(goals.count == 5)
        #expect(Set(events.map(\.id)).count == events.count)
        #expect(events.map(\.sortOrder) == events.map(\.sortOrder).sorted())
        let goal = try #require(goals.first { $0.nhlEventID == 399 })
        #expect(goal.primaryPlayer?.name == "Kirill Kaprizov")
        #expect(goal.assists.count == 2)
        #expect(goal.strength == "Power-play goal")
        #expect(goal.videoURL?.host == "nhl.com")
        #expect(goals.contains { $0.assists.count == 1 })
        #expect(goals.contains { $0.videoURL == nil })
        #expect(!events.contains { $0.title.contains("Player 84") })
    }

    @Test func boxScoreStatsAndGoalies() throws {
        let box: NHLBoxscoreResponse = try fixture("final-boxscore")
        let pbp: NHLPlayByPlayResponse = try fixture("final-play-by-play")
        let rows = NHLGameMapper.players(box, roster: NHLPlayMapper.roster(pbp.rosterSpots))
        #expect(rows.count >= 38)
        #expect(rows.contains { $0.group == "Goalies" && $0.stats.contains { $0.id == "saveShotsAgainst" } })
        #expect(rows.contains { $0.group == "Defensemen" })
        #expect(rows.contains { $0.stats.contains { $0.id == "toi" } })
    }

    @Test(arguments: ["goal", "shot-on-goal", "missed-shot", "blocked-shot", "hit", "faceoff", "penalty", "giveaway", "takeaway", "delayed-penalty", "period-start", "period-end", "game-end", "stoppage", "failed-shot-attempt", "future-event"])
    func eventTypes(_ key: String) throws {
        let response = try synthetic(key: key)
        let event = try #require(NHLPlayMapper.events(response, landing: nil).first)
        #expect(!event.title.isEmpty)
        if key == "future-event" { #expect(event.eventType == .unknown(rawValue: key)) }
        if key == "hit" { #expect(event.title == "Ada One hits Bea Two") }
        if key == "faceoff" { #expect(event.title == "Ada One wins faceoff vs. Bea Two") }
        if key == "blocked-shot" { #expect(event.title == "Bea Two blocks Ada One's shot") }
        if key == "penalty" {
            #expect(event.title.contains("Tripping"))
            #expect(event.subtitle?.contains("2 min") == true)
            #expect(event.subtitle?.contains("Served by Cy Three") == true)
        }
    }

    @Test(arguments: [0, 1, 2])
    func goalAssists(_ count: Int) throws {
        var details: [String: Any] = ["scoringPlayerId": 1]
        if count > 0 { details["assist1PlayerId"] = 2 }
        if count > 1 { details["assist2PlayerId"] = 3 }
        let response = try synthetic(key: "goal", details: details)
        let event = try #require(NHLPlayMapper.events(response, landing: nil).first)
        #expect(event.assists.count == count)
        if count == 0 { #expect(event.subtitle?.contains("Unassisted") == true) }
    }

    @Test func benchPenaltyAndMissingPlayer() throws {
        let bench = try #require(NHLPlayMapper.events(synthetic(key: "penalty", details: ["descKey":"too-many-men-on-the-ice", "duration":2, "servedByPlayerId":3]), landing: nil).first)
        #expect(bench.title.hasPrefix("Bench"))
        #expect(bench.subtitle?.contains("Served by Cy Three") == true)
        let unknown = try #require(NHLPlayMapper.events(synthetic(key: "shot-on-goal", details: ["shootingPlayerId":999]), landing: nil).first)
        #expect(unknown.primaryPlayer?.name == "Unknown player")
        #expect(unknown.primaryPlayer?.headshot == nil)
        #expect(unknown.xCoordinate == nil)
        #expect(unknown.videoURL == nil)
    }

    @Test func semanticKeyWinsAndCodeFallback() {
        #expect(HockeyEventType(key: "future-event", code: 505) == .unknown(rawValue: "future-event"))
        #expect(HockeyEventType(key: nil, code: 505) == .goal)
        #expect(HockeyEventType(key: nil, code: 999) == .unknown(rawValue: "999"))
    }

    @Test func situationParsing() {
        let pp = NHLSituationParser("1541")
        #expect(pp?.awaySkaters == 5)
        #expect(pp?.homeSkaters == 4)
        #expect(pp?.label(scoringHome: false) == "5-on-4")
        #expect(NHLSituationParser("0651")?.awayGoalie == false)
        #expect(NHLSituationParser("invalid") == nil)
        #expect(NHLSituationParser("9999") == nil)
    }

    @Test func explicitStrengthAndEmptyNet() throws {
        for (raw, expected) in [("pp", "Power-play goal"), ("sh", "Short-handed goal"), ("ev", "Even-strength goal")] {
            let goal: [String: Any] = ["eventId":10,"playerId":1,"strength":raw]
            let landing = try JSONDecoder().decode(NHLGameDTO.self, from: JSONSerialization.data(withJSONObject: ["summary":["scoring":[["goals":[goal]]]]]))
            let event = try #require(NHLPlayMapper.events(synthetic(key: "goal"), landing: landing).first)
            #expect(event.strength == expected)
        }
        let event = try #require(NHLPlayMapper.events(synthetic(key: "goal", situation: "1550"), landing: nil).first)
        #expect(event.strength == "Empty-net goal")
    }

    @Test func shootoutAndMultipleOvertime() throws {
        let response: NHLPlayByPlayResponse = try fixture("shootout")
        let attempts = NHLPlayMapper.events(response, landing: nil).filter { $0.shootoutRound != nil }
        #expect(!attempts.isEmpty)
        #expect(attempts.allSatisfy { $0.period.kind == .shootout })
        #expect(attempts.contains { $0.subtitle == "Goal" })
        let raw = NHLValue.object(["number":.number(5),"periodType":.string("OT"),"maxRegulationPeriods":.number(3)])
        #expect(HockeyPeriod(raw: raw).label == "2OT")
    }

    @Test func optionalSchemaChangesAndDuplicateRoster() throws {
        let payload = #"{"id":2023020204,"clock":"changed","plays":[{"eventId":1,"sortOrder":2,"typeDescKey":"future","details":{"xCoord":"12.5"}}],"rosterSpots":[{"playerId":1},{"playerId":1}]}"#
        let response = try JSONDecoder().decode(NHLPlayByPlayResponse.self, from: Data(payload.utf8))
        #expect(response.game.clock.secondsRemaining == nil)
        #expect(NHLPlayMapper.roster(response.rosterSpots).count == 1)
        let events = NHLPlayMapper.events(response, landing: nil)
        #expect(events.count == 1)
        #expect(events[0].xCoordinate == 12.5)
    }

    @Test func rejectsOlderAndWrongGame() throws {
        let final: NHLPlayByPlayResponse = try fixture("final-play-by-play")
        let live: NHLPlayByPlayResponse = try fixture("live-regulation")
        let update = NHLGameCenterUpdate(gameID: 2023020204, landing: nil, boxscore: nil, playByPlay: final, errors: [:], retryAfter: nil)
        let current = NHLGameCenterReducer.apply(update, to: HockeyGameCenterSnapshot(gameID: 2023020204))
        let older = NHLGameCenterUpdate(gameID: 2023020204, landing: nil, boxscore: nil, playByPlay: live, errors: [:], retryAfter: nil)
        let result = NHLGameCenterReducer.apply(older, to: current)
        #expect(result.game == current.game)
        #expect(result.events == current.events)
        #expect(result.fetchedAt == current.fetchedAt)
        #expect(result.teamStats == current.teamStats)
        #expect(NHLGameCenterReducer.apply(update, to: HockeyGameCenterSnapshot(gameID: 123)).game == nil)
        #expect(NHLGameCenterReducer.apply(update, to: current).events.count == current.events.count)
    }

    @Test func rejectsInvalidScalars() {
        #expect(NHLValue.string("nan").double == nil)
        #expect(NHLValue.string("inf").double == nil)
        #expect(NHLValue.number(.infinity).double == nil)
        #expect(NHLValue.number(1e100).int == nil)
        #expect(NHLValue.number(3.5).int == nil)
        #expect(NHLValue.string("42").int == 42)
    }

    @Test func rejectsOneSecondClockRegression() throws {
        let raw: NHLValue = try fixture("live-regulation")
        let current = try #require(NHLGameMapper.game(NHLGameDTO(raw: raw)))
        guard case .object(var fields) = raw, case .object(var clock) = raw["clock"] else {
            Issue.record("Expected fixture game and clock objects")
            return
        }
        clock["secondsRemaining"] = .number(Double(try #require(current.secondsRemaining)) + 1)
        fields["clock"] = .object(clock)
        let older = try #require(NHLGameMapper.game(NHLGameDTO(raw: .object(fields))))
        #expect(!NHLGameCenterReducer.accepts(older, over: current))
    }

    @Test func landingAndBoxScoreSurvivePlayFailure() throws {
        let landing: NHLGameDTO = try fixture("final-landing")
        let box: NHLBoxscoreResponse = try fixture("final-boxscore")
        let update = NHLGameCenterUpdate(gameID: 2023020204, landing: landing, boxscore: box, playByPlay: nil, errors: ["plays": "Offline"], retryAfter: nil)
        let result = NHLGameCenterReducer.apply(update, to: HockeyGameCenterSnapshot(gameID: 2023020204))
        #expect(result.landingLoaded)
        #expect(result.boxscoreLoaded)
        #expect(!result.playsLoaded)
        #expect(result.scoringSummary.count == 5)
        #expect(result.players.count >= 38)
        #expect(result.events.isEmpty)
    }

    @Test func diskCacheRoundTrip() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let cache = NHLGameCenterCache(directory: path)
        var state = HockeyGameCenterSnapshot(gameID: 2023020204)
        let pbp: NHLPlayByPlayResponse = try fixture("final-play-by-play")
        state.events = NHLPlayMapper.events(pbp, landing: nil)
        await cache.save(state)
        let freshCache = NHLGameCenterCache(directory: path)
        #expect(await freshCache.load(state.gameID) == state)
        #expect(await freshCache.load(123) == nil)
    }
}

private func synthetic(key: String, details: [String: Any]? = nil, situation: String = "1551") throws -> NHLPlayByPlayResponse {
    let all: [String: Any] = ["scoringPlayerId":1,"shootingPlayerId":1,"hittingPlayerId":1,"winningPlayerId":1,"committedByPlayerId":1,"playerId":1,
                             "assist1PlayerId":2,"assist2PlayerId":3,"goalieInNetId":2,"blockingPlayerId":2,"hitteePlayerId":2,"losingPlayerId":2,"drawnByPlayerId":2,"servedByPlayerId":3,
                             "descKey":"tripping","duration":2,"eventOwnerTeamId":30,"shotType":"wrist"]
    let play: [String: Any] = ["eventId":10,"sortOrder":20,"typeDescKey":key,"periodDescriptor":["number":1,"periodType":"REG"],"timeInPeriod":"01:20","situationCode":situation,"details":details ?? all]
    let roster = [(1,"Ada","One"),(2,"Bea","Two"),(3,"Cy","Three")].map { id, first, last -> [String: Any] in
        ["playerId":id,"firstName":["default":first],"lastName":["default":last],"teamId":30]
    }
    let raw: [String: Any] = ["id":2023020204,"homeTeam":["id":7],"awayTeam":["id":30],"plays":[play],"rosterSpots":roster]
    return try JSONDecoder().decode(NHLPlayByPlayResponse.self, from: JSONSerialization.data(withJSONObject: raw))
}
