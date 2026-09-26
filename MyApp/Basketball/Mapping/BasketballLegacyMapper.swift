import Foundation

/// Bridges the canonical `BasketballGame` into the app-wide legacy `Match`/
/// `RosterAthlete` models. Shared verbatim between NBA and WNBA — unlike the
/// EPL/MLS/LaLiga soccer mappers (which each have genuinely different raw-field
/// mapping logic per provider), this transform only ever consumes the already-
/// canonical `BasketballGame`, so there is nothing league-specific left to
/// duplicate; only the `BasketballLeagueConfiguration` (and the `League` it
/// resolves to) varies per call.
nonisolated enum BasketballLegacyMapper {
    @MainActor static func match(_ game: BasketballGame, config: BasketballLeagueConfiguration) -> Match {
        let league = League.all.first { $0.path == config.leaguePath }
            ?? League(name: config.displayName, shortName: config.displayName, path: config.leaguePath, group: .basketball, keywords: [config.displayName.lowercased(), "basketball"])
        func side(_ team: BasketballTeam) -> TeamSide {
            let opponentScore = team.id == game.home.id ? game.away.score : game.home.score
            return TeamSide(displayName: team.displayName, shortName: team.tricode, abbreviation: team.tricode, logoURL: team.logo,
                score: team.score.map(String.init), record: team.record,
                isWinner: game.status == .final && (team.score ?? -1) > (opponentScore ?? -1),
                teamID: String(team.id), canonicalIDString: "team:\(league.bannerKey):\(config.league.rawValue):\(team.id)")
        }
        let state: GameState = game.status == .final ? .final : [.live, .halftime, .delayed, .suspended].contains(game.status) ? .live : .pre
        let clockText = game.gameClock.map { NBADuration.clockText(seconds: $0) }
        let statusDetail: String
        switch game.status {
        case .final: statusDetail = game.finalLabel
        case .live, .halftime: statusDetail = [game.periodLabel, clockText].compactMap { $0 }.joined(separator: " ")
        default: statusDetail = game.statusText
        }
        let periods: [LineScorePeriod] = game.away.periods.map { awayPeriod in
            let homePeriod = game.home.periods.first { $0.period == awayPeriod.period }
            return LineScorePeriod(label: awayPeriod.label, awayScore: String(awayPeriod.score), homeScore: homePeriod.map { String($0.score) })
        }
        let situation = BasketballSituation(quarter: game.periodLabel, clock: clockText,
            possessionTeamID: nil, possessionTeamAbbreviation: nil,
            homeTimeoutsRemaining: game.home.timeoutsRemaining, awayTimeoutsRemaining: game.away.timeoutsRemaining,
            homeBonus: game.home.inBonus, awayBonus: game.away.inBonus, scoringByPeriod: periods)
        var result = Match(id: game.id.providerID, league: league, date: game.start,
            name: "\(game.away.displayName) at \(game.home.displayName)", shortName: "\(game.away.tricode) @ \(game.home.tricode)",
            state: state, statusDetail: statusDetail, home: side(game.home), away: side(game.away),
            broadcasts: game.broadcasts, venue: game.arena?.name, liveContext: MatchLiveContext(basketball: situation))
        result.canonicalID = "game:\(league.bannerKey):\(config.league.rawValue):\(game.id.providerID)"
        return result
    }

    static func athlete(id: Int, name: String, jersey: String?, position: String?, config: BasketballLeagueConfiguration, height: String? = nil,
                        weight: String? = nil, age: Int? = nil, experienceYears: Int? = nil, college: String? = nil) -> RosterAthlete {
        var result = RosterAthlete(id: String(id), displayName: name, jersey: jersey, position: position, positionName: position,
            headshotURL: nil, age: age, displayHeight: height, displayWeight: weight, college: college,
            experienceYears: experienceYears, birthPlace: nil, isInjured: false)
        result.canonicalID = "player:league.\(config.leaguePath.replacingOccurrences(of: "/", with: "-")):\(config.league.rawValue):\(id)"
        return result
    }
}
