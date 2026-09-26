import Foundation

/// Maps `/api/v1/subscriptions/{slug}/rounds` into `[SoccerRound]`. The official
/// response nests gameweeks inside a round phase (`{rounds:[{gameweeks:[...]}]}`) —
/// verified live 2026-09-24 that La Liga's single "Regular" round currently reports
/// `num_gameweeks: 38`, but this never hardcodes that count (Step 7); it flattens
/// whatever gameweeks each round actually lists.
nonisolated enum LaLigaRoundsMapper {
    static func rounds(_ raw: LaLigaValue) -> [SoccerRound] {
        raw["rounds"].array.flatMap { round in
            round["gameweeks"].array.compactMap { gameweek -> SoccerRound? in
                guard let id = gameweek["id"].string, let week = gameweek["week"].int else { return nil }
                return SoccerRound(id: id, week: week, name: gameweek["name"].string, startDate: LaLigaDate.parse(gameweek["date"].string), endDate: nil)
            }
        }
    }
}
