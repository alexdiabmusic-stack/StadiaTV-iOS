import Foundation

nonisolated enum CFLLegacyMapper {
    @MainActor static func match(_ game: CFLGameState) -> Match {
        let league = League(name: "CFL", shortName: "CFL", path: "football/cfl", group: .football)
        func side(_ team: FootballTeamState) -> TeamSide {
            TeamSide(displayName: team.name, shortName: team.abbreviation, abbreviation: team.abbreviation, logoURL: team.logo,
                score: team.score.map(String.init), record: nil,
                isWinner: game.status == .final && (team.score ?? -1) > (team.id == game.home.id ? game.away.score ?? -1 : game.home.score ?? -1),
                teamID: team.id, canonicalIDString: "team:league.football-cfl:cfl:\(team.id)")
        }
        // No down/distance/field-position surfaces here — `echo.pims.cfl.ca` never
        // exposes them (verified live); only `clock` is real, everything else in a
        // `FootballSituation` stays nil rather than fabricated.
        let context = MatchLiveContext(football: FootballSituation(quarter: nil, clock: game.clock, possessionTeamID: nil,
            possessionTeamAbbreviation: nil, down: nil, distance: nil, ballPosition: nil, yardLine: nil, isRedZone: nil))
        var match = Match(id: game.id, league: league, date: game.start, name: "\(game.away.name) at \(game.home.name)",
            shortName: "\(game.away.abbreviation) @ \(game.home.abbreviation)",
            state: game.status == .final ? .final : [.live, .halftime, .delayed, .suspended].contains(game.status) ? .live : .pre,
            statusDetail: game.statusText, home: side(game.home), away: side(game.away), broadcasts: game.broadcasts, venue: game.venue, liveContext: context)
        match.canonicalID = "game:league.football-cfl:cfl:\(game.id)"; return match
    }
}
