import Foundation
import Testing
@testable import WNBACore

/// The reducer itself is shared (`BasketballGameCenterReducer`, exhaustively
/// covered by `NBACoreTests`) — these tests cover WNBA-specific scenarios that
/// exercise the shared reducer through WNBA's own mapper-produced values,
/// proving the generalization actually works for a second league rather than
/// just NBA. League-tag isolation is the one genuinely new invariant.
private func team(_ id: Int, tricode: String, score: Int?) -> BasketballTeam {
    BasketballTeam(id: id, city: "", name: tricode, tricode: tricode, slug: nil, wins: nil, losses: nil,
        score: score, timeoutsRemaining: nil, inBonus: nil, periods: [], seed: nil)
}
private func game(id: String, period: Int, status: BasketballGameStatus, homeScore: Int?, awayScore: Int?) -> BasketballGame {
    BasketballGame(id: BasketballGameID(league: .wnba, providerID: id), gameCode: nil, start: Date(),
        away: team(2, tricode: "WAS", score: awayScore), home: team(1, tricode: "CHI", score: homeScore),
        status: status, rawStatus: nil, statusText: "", period: period, regulationPeriods: 4, gameClock: nil,
        arena: nil, attendance: nil, officials: [], seriesGameNumber: nil, seriesText: nil, gameLabel: nil,
        gameSubLabel: nil, gameSubtype: nil, homeLeader: nil, awayLeader: nil, broadcasts: [])
}

@Suite("BasketballGameCenterReducer via WNBA")
struct WNBAGameCenterReducerTests {
    @Test func wnbaAndNbaGameIDsWithSameDigitsNeverCollideInTheReducer() {
        let id = BasketballGameID(league: .wnba, providerID: "1")
        let old = BasketballGameSnapshot(gameID: id, game: game(id: "1", period: 2, status: .live, homeScore: 40, awayScore: 38), fetchedAt: Date())
        // An update tagged with the NBA league sharing the same digit string must
        // be rejected wholesale — this is exactly what `BasketballGameID` being
        // `Hashable`/`Equatable` on the whole struct (not just `providerID`) buys.
        let foreignLeagueUpdate = BasketballGameCenterUpdate(gameID: BasketballGameID(league: .nba, providerID: "1"), requestedAt: Date().addingTimeInterval(1),
            scoreboardGame: game(id: "1", period: 3, status: .live, homeScore: 90, awayScore: 90))
        #expect(BasketballGameCenterReducer.apply(foreignLeagueUpdate, to: old) == old)
    }
    @Test func overtimeAndDoubleOvertimeAcceptedWithNoHardcodedCeiling() {
        let old = BasketballGameSnapshot(gameID: BasketballGameID(league: .wnba, providerID: "1"),
            game: game(id: "1", period: 4, status: .live, homeScore: 88, awayScore: 88), fetchedAt: Date())
        let update = BasketballGameCenterUpdate(gameID: BasketballGameID(league: .wnba, providerID: "1"), requestedAt: Date().addingTimeInterval(1),
            scoreboardGame: game(id: "1", period: 6, status: .final, homeScore: 110, awayScore: 106))
        let result = BasketballGameCenterReducer.apply(update, to: old)
        #expect(result.game?.period == 6)
        #expect(result.game?.finalLabel == "FINAL/2OT")
    }
    @Test func playoffGameLabelSurvivesThroughTheReducer() {
        var playoff = game(id: "1", period: 0, status: .scheduled, homeScore: nil, awayScore: nil)
        playoff.gameLabel = "WNBA Finals"; playoff.seriesGameNumber = "3"; playoff.seriesText = "Series tied 1-1"
        let old = BasketballGameSnapshot(gameID: BasketballGameID(league: .wnba, providerID: "1"), game: nil, fetchedAt: .distantPast)
        let update = BasketballGameCenterUpdate(gameID: BasketballGameID(league: .wnba, providerID: "1"), requestedAt: Date(), scoreboardGame: playoff)
        let result = BasketballGameCenterReducer.apply(update, to: old)
        #expect(result.game?.gameLabel == "WNBA Finals")
        #expect(result.game?.seriesText == "Series tied 1-1")
    }
}
