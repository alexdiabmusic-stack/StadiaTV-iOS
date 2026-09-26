import Foundation

nonisolated enum NFLLegacyMapper {
    @MainActor static func match(_ game: NFLGameState) -> Match {
        let league = League(name: "NFL", shortName: "NFL", path: "football/nfl", group: .football)
        func side(_ team: FootballTeamState) -> TeamSide {
            TeamSide(displayName: team.name, shortName: team.abbreviation, abbreviation: team.abbreviation, logoURL: team.logo,
                score: team.score.map(String.init), record: nil, isWinner: game.status == .final && (team.score ?? -1) > (team.id == game.home.id ? game.away.score ?? -1 : game.home.score ?? -1),
                teamID: team.id, canonicalIDString: "team:league.football-nfl:nfl:\(team.id)")
        }
        let context = MatchLiveContext(football: FootballSituation(quarter: game.quarter, clock: game.clock, possessionTeamID: game.possession?.id,
            possessionTeamAbbreviation: game.possession?.abbreviation, down: game.down, distance: game.distance, ballPosition: game.field?.text,
            yardLine: game.field?.yard, isRedZone: game.isRedZone))
        var match = Match(id: game.id, league: league, date: game.start, name: "\(game.away.name) at \(game.home.name)",
            shortName: "\(game.away.abbreviation) @ \(game.home.abbreviation)", state: game.status == .final ? .final : [.live, .halftime, .delayed, .suspended].contains(game.status) ? .live : .pre,
            statusDetail: game.statusText, home: side(game.home), away: side(game.away), broadcasts: game.broadcasts, venue: game.venue, liveContext: context)
        match.canonicalID = "game:league.football-nfl:nfl:\(game.id)"; return match
    }
}
