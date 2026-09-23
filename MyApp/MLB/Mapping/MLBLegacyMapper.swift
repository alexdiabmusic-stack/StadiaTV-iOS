import Foundation

nonisolated enum MLBLegacyMapper {
    @MainActor static func match(_ game: BaseballGame, line: BaseballLineScore? = nil) -> Match {
        let league = League(name: "MLB", shortName: "MLB", path: "baseball/mlb", group: .baseball)
        func side(_ team: BaseballTeam) -> TeamSide {
            TeamSide(displayName: team.name, shortName: team.abbreviation, abbreviation: team.abbreviation, logoURL: team.logo, score: team.runs.map(String.init), record: team.record,
                isWinner: game.status == .final && (team.runs ?? -1) > (team.id == game.home.id ? game.away.runs ?? -1 : game.home.runs ?? -1),
                teamID: String(team.id), canonicalIDString: "team:\(league.bannerKey):mlb:\(team.id)")
        }
        let state: GameState = game.status == .final ? .final : [.live, .delayed, .suspended].contains(game.status) ? .live : .pre
        let context = line.map { line in MatchLiveContext(baseball: BaseballSituation(inning: line.currentInning.map(String.init), inningHalf: line.inningState, outs: line.count.outs, balls: line.count.balls, strikes: line.count.strikes,
            runnerOnFirst: line.bases.first != nil, runnerOnSecond: line.bases.second != nil, runnerOnThird: line.bases.third != nil, batterName: line.batter?.name, pitcherName: line.pitcher?.name)) } ?? .empty
        var result = Match(id: String(game.id), league: league, date: game.start, name: "\(game.away.name) at \(game.home.name)", shortName: "\(game.away.abbreviation) @ \(game.home.abbreviation)",
            state: state, statusDetail: game.status == .live ? line?.label ?? game.detailedStatus : game.detailedStatus,
            home: side(game.home), away: side(game.away), broadcasts: game.broadcasts, venue: game.venue, liveContext: context)
        result.canonicalID = "game:\(league.bannerKey):mlb:\(game.id)"
        return result
    }
    static func athlete(_ player: BaseballPlayerReference) -> RosterAthlete {
        var result = RosterAthlete(id: String(player.id), displayName: player.name, jersey: player.jersey, position: player.position, positionName: player.position,
            headshotURL: nil, age: nil, displayHeight: nil, displayWeight: nil, college: nil, experienceYears: nil, birthPlace: nil, isInjured: false)
        result.canonicalID = "player:league.baseball-mlb:mlb:\(player.id)"
        return result
    }
}
