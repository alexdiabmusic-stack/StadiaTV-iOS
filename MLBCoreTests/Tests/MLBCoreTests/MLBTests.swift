import Foundation
import Testing
@testable import MLBCore

func fixtureData(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    #endif
    return try Data(contentsOf: url)
}
func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T { try JSONDecoder().decode(type, from: fixtureData(name)) }

@Suite("MLB fixture normalization")
struct MLBFixtureTests {
    @Test(arguments: ["scheduled", "pregame", "warmup", "live-early", "live-late", "between-innings", "final", "extra-innings", "rain-delay", "suspended", "postponed", "postseason"])
    func gameStates(_ name: String) throws {
        let feed: MLBGameFeedResponse = try fixture(name)
        let game = try #require(MLBGameMapper.feed(feed))
        let expected: [String: BaseballGameStatus] = ["scheduled": .scheduled, "pregame": .pregame, "warmup": .warmup, "live-early": .live, "live-late": .live, "between-innings": .live, "final": .final, "extra-innings": .live, "rain-delay": .delayed, "suspended": .suspended, "postponed": .postponed, "postseason": .final]
        #expect(game.status == expected[name]); #expect(game.id == 744834)
        if name == "postseason" { #expect(game.gameType == "W") }
        if name == "extra-innings" { #expect(MLBGameMapper.line(feed.live["linescore"], players: [:])?.currentInning == 12) }
        if name == "between-innings" { #expect(MLBGameMapper.line(feed.live["linescore"], players: [:])?.bases.occupied == [false, false, false]) }
    }
    @Test func discoveryAndDoubleheaders() throws {
        let schedule: MLBScheduleResponse = try fixture("schedule")
        let games = schedule.games.compactMap(MLBGameMapper.schedule)
        #expect(!games.isEmpty); #expect(Set(games.map(\.id)).count == games.count)
        let first: MLBScheduleResponse = try fixture("doubleheader-1"), second: MLBScheduleResponse = try fixture("doubleheader-2")
        let a = try #require(first.games.first.flatMap(MLBGameMapper.schedule)), b = try #require(second.games.first.flatMap(MLBGameMapper.schedule))
        #expect(a.id != b.id); #expect(a.gameNumber == 1); #expect(b.gameNumber == 2)
    }
    @Test(arguments: ["runner-first", "runners-corners", "bases-loaded"])
    func baseOccupancy(_ name: String) throws {
        let raw: MLBLineScoreResponse = try fixture(name)
        let line = try #require(MLBGameMapper.line(raw.raw, players: [:]))
        #expect(line.bases.occupied == (name == "runner-first" ? [true, false, false] : name == "runners-corners" ? [true, false, true] : [true, true, true]))
        #expect(line.count.balls == 2); #expect(line.count.strikes == 1); #expect(line.count.outs == 1)
    }
    @Test func allPlayTypesAndCurrentPlayDeduplicate() throws {
        let raw: MLBPlayByPlayResponse = try fixture("play-types")
        let plays = MLBPlayMapper.plays(raw, gamePk: 744834, players: [:])
        #expect(plays.count == 19); #expect(Set(plays.map(\.id)).count == 19)
        #expect(plays.map(\.atBatIndex) == Array(0..<19))
        let types: [BaseballResultType] = [.homeRun, .single, .double, .triple, .strikeout, .walk, .hitByPitch, .sacrificeFly, .doublePlay, .error, .stolenBase, .caughtStealing, .wildPitch, .passedBall, .pitchingChange, .substitution, .substitution, .review, .unknown("future_new_event")]
        #expect(plays.map(\.resultType) == types)
        #expect(plays[0].isScoringPlay); #expect(plays[0].runners.first?.scored == true)
        #expect(plays.last?.events.first?.resultType == .unknown("future_new_event"))
        #expect(plays[0].events.contains { $0.isPitch && $0.coordinates != nil && $0.startSpeed != nil })
        #expect(plays[0].batter?.name == "Francisco Lindor")
    }
    @Test func missingOptionalDataAndScalarSafety() throws {
        let raw: MLBPlayByPlayResponse = try fixture("missing-data")
        let plays = MLBPlayMapper.plays(raw, gamePk: 1, players: [:])
        #expect(plays.count == 1); #expect(plays[0].events.isEmpty); #expect(plays[0].batter == nil)
        #expect(MLBValue.string("nan").double == nil); #expect(MLBValue.number(1e100).int == nil)
        #expect(MLBGameMapper.count(.object(["balls": .number(8), "strikes": .number(5), "outs": .number(-1)]), live: true) == BaseballCount(balls: nil, strikes: nil, outs: nil))
        #expect(MLBStatusMapper.status(.object(["detailedState": .string("Future unknown")])) == .unknown)
    }
    @Test func fullSnapshotAndBoxScore() throws {
        let feed: MLBGameFeedResponse = try fixture("final")
        let result = MLBGameCenterReducer.apply(MLBGameCenterUpdate(gamePk: 744834, requestedAt: Date(), feed: feed), to: BaseballGameSnapshot(gamePk: 744834))
        #expect(result.game?.away.runs == 0); #expect(result.game?.home.runs == 1)
        #expect(result.line?.homeHits == 5); #expect(result.line?.awayHits == 1)
        #expect(result.atBats.count > 50); #expect(result.players.count > 30)
        #expect(result.box.contains { !$0.batting.isEmpty }); #expect(result.box.contains { !$0.pitching.isEmpty })
        #expect(result.line?.innings.last?.homeRuns == nil)
    }
    @Test func staleAndWrongGameRejected() throws {
        let feed: MLBGameFeedResponse = try fixture("final")
        let time = Date()
        let state = MLBGameCenterReducer.apply(MLBGameCenterUpdate(gamePk: 744834, requestedAt: time, feed: feed), to: BaseballGameSnapshot(gamePk: 744834))
        #expect(MLBGameCenterReducer.apply(MLBGameCenterUpdate(gamePk: 1, requestedAt: time.addingTimeInterval(1), feed: feed), to: state) == state)
        #expect(MLBGameCenterReducer.apply(MLBGameCenterUpdate(gamePk: 744834, requestedAt: time.addingTimeInterval(-1), feed: feed), to: state) == state)
        let live: MLBGameFeedResponse = try fixture("live-early")
        #expect(MLBGameCenterReducer.apply(MLBGameCenterUpdate(gamePk: 744834, requestedAt: time.addingTimeInterval(1), feed: live), to: state) == state)
    }
    @Test func cacheRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed: MLBGameFeedResponse = try fixture("final")
        let state = MLBGameCenterReducer.apply(MLBGameCenterUpdate(gamePk: 744834, requestedAt: Date(), feed: feed), to: BaseballGameSnapshot(gamePk: 744834))
        await MLBGameCenterCache(directory: directory).save(state)
        #expect(await MLBGameCenterCache(directory: directory).load(744834) == state)
        #expect(await MLBGameCenterCache(directory: directory).load(123) == nil)
    }
    @Test func endpointVersionsAndFilters() throws {
        #expect(try MLBEndpoint.feed(744834).url().path == "/api/v1.1/game/744834/feed/live")
        #expect(try MLBEndpoint.game(744834, resource: "boxscore").url().path == "/api/v1/game/744834/boxscore")
        let url = try MLBEndpoint.schedule(start: Date(), teamID: 141, season: 2026, gameTypes: "R").url()
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "sportId" && $0.value == "1" })
        #expect(query.contains { $0.name == "teamId" && $0.value == "141" })
    }
}
