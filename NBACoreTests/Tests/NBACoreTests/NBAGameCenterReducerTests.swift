import Foundation
import Testing
@testable import NBACore

private func team(_ id: Int, tricode: String, score: Int?, timeouts: Int? = nil) -> BasketballTeam {
    BasketballTeam(id: id, city: "", name: tricode, tricode: tricode, slug: nil, wins: nil, losses: nil,
        score: score, timeoutsRemaining: timeouts, inBonus: nil, periods: [], seed: nil)
}
private func game(id: String = "1", period: Int, clock: TimeInterval?, homeScore: Int?, awayScore: Int?,
                  status: BasketballGameStatus = .live, broadcasts: [String] = []) -> BasketballGame {
    BasketballGame(id: BasketballGameID(league: .nba, providerID: id), gameCode: nil, start: Date(),
        away: team(2, tricode: "AWY", score: awayScore), home: team(1, tricode: "HOM", score: homeScore),
        status: status, rawStatus: nil, statusText: "", period: period, regulationPeriods: 4, gameClock: clock,
        arena: nil, attendance: nil, officials: [], seriesGameNumber: nil, seriesText: nil, gameLabel: nil,
        gameSubLabel: nil, gameSubtype: nil, homeLeader: nil, awayLeader: nil, broadcasts: broadcasts)
}
private func play(_ id: String, period: Int, order: Int, gameID: BasketballGameID = BasketballGameID(league: .nba, providerID: "1")) -> NBAPlayEvent {
    NBAPlayEvent(id: id, gameID: gameID, actionNumber: order, orderNumber: order, period: period, clockText: nil, type: .rebound,
        teamID: nil, teamTricode: nil, personID: nil, playerName: nil, title: id, subtitle: nil, scoreHome: nil, scoreAway: nil,
        isFieldGoal: false, shot: nil, isPeriodBoundary: false, priority: .compact, assistPlayerName: nil, videoAvailable: false)
}
private let id = BasketballGameID(league: .nba, providerID: "1")

private func boxLines(homeID: Int, awayID: Int) -> (home: [NBAPlayerGameLine], away: [NBAPlayerGameLine]) {
    let box = NBABoxScoreResponse(raw: .object([
        "game": .object([
            "gameId": .string("1"),
            "homeTeam": .object(["teamId": .number(Double(homeID)), "players": .array([])]),
            "awayTeam": .object(["teamId": .number(Double(awayID)), "players": .array([])])
        ])
    ]))
    return (NBABoxScoreMapper.players(box.homeTeam), NBABoxScoreMapper.players(box.awayTeam))
}

@Suite("BasketballGameCenterReducer")
struct BasketballGameCenterReducerTests {
    @Test func periodRegressionRejected() {
        let old = BasketballGameSnapshot(gameID: id, game: game(period: 3, clock: 300, homeScore: 50, awayScore: 48), fetchedAt: Date())
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date().addingTimeInterval(1),
            scoreboardGame: game(period: 2, clock: 500, homeScore: 50, awayScore: 48))
        #expect(BasketballGameCenterReducer.apply(update, to: old) == old)
    }
    @Test func clockRollbackWithoutCorroboratingProgressRejected() {
        let old = BasketballGameSnapshot(gameID: id, game: game(period: 2, clock: 300, homeScore: 50, awayScore: 48), fetchedAt: Date())
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date().addingTimeInterval(1),
            scoreboardGame: game(period: 2, clock: 400, homeScore: 50, awayScore: 48))
        #expect(BasketballGameCenterReducer.apply(update, to: old) == old)
    }
    @Test func clockRollbackWithScoreProgressAccepted() {
        let old = BasketballGameSnapshot(gameID: id, game: game(period: 2, clock: 300, homeScore: 50, awayScore: 48), fetchedAt: Date())
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date().addingTimeInterval(1),
            scoreboardGame: game(period: 2, clock: 400, homeScore: 52, awayScore: 48))
        let result = BasketballGameCenterReducer.apply(update, to: old)
        #expect(result.game?.gameClock == 400)
    }
    @Test func scoreDecreaseWithoutFreshBoxRejected() {
        let old = BasketballGameSnapshot(gameID: id, game: game(period: 2, clock: 300, homeScore: 50, awayScore: 48), fetchedAt: Date())
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date().addingTimeInterval(1),
            scoreboardGame: game(period: 2, clock: 300, homeScore: 48, awayScore: 48))
        #expect(BasketballGameCenterReducer.apply(update, to: old) == old)
    }
    @Test func scoreDecreaseWithFreshBoxAccepted() throws {
        let old = BasketballGameSnapshot(gameID: id, game: game(period: 2, clock: 300, homeScore: 50, awayScore: 48), fetchedAt: Date())
        let corrected = game(period: 2, clock: 300, homeScore: 48, awayScore: 48)
        let lines = boxLines(homeID: 1, awayID: 2)
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date().addingTimeInterval(1), boxGame: corrected, homeBox: lines.home, awayBox: lines.away)
        let result = BasketballGameCenterReducer.apply(update, to: old)
        #expect(result.game?.home.score == 48)
    }
    @Test func terminalStateRegressionRejected() {
        let old = BasketballGameSnapshot(gameID: id, game: game(period: 4, clock: 0, homeScore: 100, awayScore: 90, status: .final), fetchedAt: Date())
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date().addingTimeInterval(1),
            scoreboardGame: game(period: 4, clock: 10, homeScore: 100, awayScore: 90, status: .live))
        #expect(BasketballGameCenterReducer.apply(update, to: old) == old)
    }
    @Test func playListNeverShrinksAndMergesById() {
        let old = BasketballGameSnapshot(gameID: id, game: nil, plays: [play("a", period: 1, order: 1), play("b", period: 1, order: 2)], fetchedAt: .distantPast)
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date(), plays: [play("b", period: 1, order: 2), play("c", period: 1, order: 3)])
        let result = BasketballGameCenterReducer.apply(update, to: old)
        #expect(result.plays.map(\.id) == ["a", "b", "c"])
        #expect(result.playsLoaded)
    }
    @Test func replayReviewCorrectionReplacesRatherThanDuplicates() {
        let original = play("a", period: 1, order: 1)
        let old = BasketballGameSnapshot(gameID: id, game: nil, plays: [original], fetchedAt: .distantPast)
        let corrected = NBAPlayEvent(id: "a", gameID: id, actionNumber: 1, orderNumber: 1, period: 1, clockText: nil, type: .madeShot,
            teamID: nil, teamTricode: nil, personID: nil, playerName: nil, title: "corrected", subtitle: nil, scoreHome: nil, scoreAway: nil,
            isFieldGoal: true, shot: nil, isPeriodBoundary: false, priority: .high, assistPlayerName: nil, videoAvailable: false)
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date(), plays: [corrected])
        let result = BasketballGameCenterReducer.apply(update, to: old)
        #expect(result.plays.count == 1)
        #expect(result.plays.first?.title == "corrected")
    }
    @Test func foreignTeamIDInBoxRejected() throws {
        // Row-level defense: a player row whose own `teamID` doesn't match either
        // side of the game is rejected wholesale, even though the box was fetched
        // for the right `gameID` — this is the reducer's own remaining check;
        // container-level consistency (does the raw box's own team-id field agree
        // with the mapped game) is now `NBAGameCenterService`'s responsibility,
        // covered separately in `NBAServiceRoutingTests`.
        let g = game(period: 1, clock: 500, homeScore: 10, awayScore: 8)
        let old = BasketballGameSnapshot(gameID: id, game: g, fetchedAt: Date())
        let foreignLine = NBAPlayerGameLine(personID: 1, teamID: 999, name: "X", nameInitial: nil, jerseyNum: nil, position: nil,
            order: nil, starter: true, onCourt: false, played: true, status: nil, notPlayingReason: nil, notPlayingDescription: nil, minutesSeconds: nil, stats: [:])
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date().addingTimeInterval(1), boxGame: g, homeBox: [foreignLine], awayBox: [])
        let result = BasketballGameCenterReducer.apply(update, to: old)
        #expect(result.homeBox.isEmpty)
        #expect(!result.boxLoaded)
    }
    @Test func statsCannotClobberFreshCDNPlays() {
        // CDN populated plays already; a same-or-behind "stats" update contributes
        // nothing new and must not replace what's already there.
        let old = BasketballGameSnapshot(gameID: id, game: nil, plays: [play("a", period: 2, order: 5)], fetchedAt: .distantPast, playsLoaded: true)
        let staleUpdate = BasketballGameCenterUpdate(gameID: id, requestedAt: Date(), plays: [play("a", period: 1, order: 1)], playsSource: "stats")
        let result = BasketballGameCenterReducer.apply(staleUpdate, to: old)
        #expect(result.plays.map(\.id) == ["a"])
        #expect(result.plays.first?.period == 2)
    }
    @Test func fetchedAtBumpsOnlyWhenSomethingLanded() {
        let old = BasketballGameSnapshot(gameID: id, game: nil, fetchedAt: .distantPast)
        let noOpUpdate = BasketballGameCenterUpdate(gameID: id, requestedAt: Date())
        #expect(BasketballGameCenterReducer.apply(noOpUpdate, to: old).fetchedAt == .distantPast)
        let realUpdate = BasketballGameCenterUpdate(gameID: id, requestedAt: Date(), scoreboardGame: game(period: 1, clock: 700, homeScore: 0, awayScore: 0))
        #expect(BasketballGameCenterReducer.apply(realUpdate, to: old).fetchedAt != .distantPast)
    }
    @Test func shotsTrackPlaysAsAPureProjection() {
        let shot = NBAShotCoordinate(x: 5, y: 10, distanceFeet: 11, made: true, value: 2)
        let scoring = NBAPlayEvent(id: "s", gameID: id, actionNumber: 1, orderNumber: 1, period: 1, clockText: nil, type: .madeShot,
            teamID: nil, teamTricode: nil, personID: nil, playerName: nil, title: "shot", subtitle: nil, scoreHome: nil, scoreAway: nil,
            isFieldGoal: true, shot: shot, isPeriodBoundary: false, priority: .high, assistPlayerName: nil, videoAvailable: false)
        let old = BasketballGameSnapshot(gameID: id, game: nil, fetchedAt: .distantPast)
        let update = BasketballGameCenterUpdate(gameID: id, requestedAt: Date(), plays: [scoring])
        let result = BasketballGameCenterReducer.apply(update, to: old)
        #expect(result.shots.count == 1)
        #expect(result.shots.first?.x == 5)
    }
    @Test func mismatchedGameIDRejectedWholesale() {
        let old = BasketballGameSnapshot(gameID: id, game: game(period: 1, clock: 700, homeScore: 0, awayScore: 0), fetchedAt: Date())
        let update = BasketballGameCenterUpdate(gameID: BasketballGameID(league: .nba, providerID: "999"), requestedAt: Date().addingTimeInterval(1),
            scoreboardGame: game(id: "999", period: 2, clock: 500, homeScore: 5, awayScore: 5))
        #expect(BasketballGameCenterReducer.apply(update, to: old) == old)
    }
}
