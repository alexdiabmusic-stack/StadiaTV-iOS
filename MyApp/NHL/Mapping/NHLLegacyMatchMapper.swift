import Foundation

nonisolated extension NHLGameMapper {
    static func match(_ game: HockeyGame, league: League) -> Match {
        func side(_ team: HockeyTeam) -> TeamSide {
            TeamSide(displayName: team.name, shortName: team.abbreviation, abbreviation: team.abbreviation,
                     logoURL: team.logo, score: team.score.map(String.init), record: nil,
                     isWinner: game.status == .final && team.score != nil && team.score == max(game.home.score ?? -1, game.away.score ?? -1) && game.home.score != game.away.score,
                     teamID: String(team.id), canonicalIDString: "team:\(league.bannerKey):nhl:\(team.id)")
        }
        var result = Match(id: String(game.id), league: league, date: game.start,
                           name: "\(game.away.name) at \(game.home.name)",
                           shortName: "\(game.away.abbreviation) @ \(game.home.abbreviation)",
                           state: game.status.legacyGameState, statusDetail: game.statusLabel + (game.status == .live ? " " + (game.clock ?? "") : ""),
                           home: side(game.home), away: side(game.away), broadcasts: game.broadcasts, venue: game.venue,
                           liveContext: MatchLiveContext(clock: MatchClock(displayValue: game.clock, remainingSeconds: game.secondsRemaining, isRunning: game.clockRunning),
                                                         period: MatchPeriod(number: game.period.number, displayName: game.period.label)))
        result.canonicalID = "game:\(league.bannerKey):nhl:\(game.id)"
        return result
    }
}
