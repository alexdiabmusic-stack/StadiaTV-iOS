import Foundation

/// Reuses the existing soccer domain, reducer, cache and FotMob enrichment mappers.
nonisolated struct ChampionsLeagueGameCentreService: SoccerGameCentreServing {
    let base: SoccerMatch
    var client: any FotMobClientProtocol = FotMobClient.shared

    func fetch(matchID: String, tab: SoccerGameTab, full: Bool, lineupsLoaded: Bool,
               knownPlayers: [String: SoccerPlayerReference], commentaryCursor: String?) async throws -> SoccerGameCentreUpdate {
        let raw = try await client.matchDetails(matchId: matchID)
        guard FotMobMatchMapper.matchID(raw) == matchID,
              FotMobMatchMapper.homeTeamID(raw) == base.home.team.id,
              FotMobMatchMapper.awayTeamID(raw) == base.away.team.id else { throw FotMobAPIError.invalidResponse }
        let current = FotMobMatchMapper.apply(raw, to: base)
        var update = SoccerGameCentreUpdate(matchID: matchID, requestedAt: Date())
        update.match = current
        if full || tab == .timeline || tab == .overview {
            update.events = FotMobEventMapper.events(raw, matchID: matchID, homeTeamID: base.home.team.id, awayTeamID: base.away.team.id)
        }
        if full || !lineupsLoaded {
            update.homeLineup = .some(FotMobLineupMapper.lineup(raw["content"]["lineup"]["homeTeam"], team: base.home.team))
            update.awayLineup = .some(FotMobLineupMapper.lineup(raw["content"]["lineup"]["awayTeam"], team: base.away.team))
        }
        if full || tab == .stats || tab == .overview {
            let stats = FotMobStatsMapper.stats(raw, homeTeamID: base.home.team.id, awayTeamID: base.away.team.id)
            update.homeStats = stats.home
            update.awayStats = stats.away
        }
        var directory = knownPlayers
        for lineup in [update.homeLineup ?? nil, update.awayLineup ?? nil].compactMap({ $0 }) {
            for player in lineup.starters + lineup.substitutes { directory[player.reference.id] = player.reference }
        }
        update.playerDirectory = directory
        try Task.checkCancellation()
        return update
    }
}

extension SoccerGameCentreCache {
    static let championsLeague = SoccerGameCentreCache(provider: "ChampionsLeague")
}

nonisolated extension ChampionsLeagueMapper {
    static func seed(from match: Match) -> SoccerMatch? {
        guard match.league.path == league.path,
              let homeID = match.home.teamID, let awayID = match.away.teamID else { return nil }
        func side(_ value: TeamSide, id: String) -> SoccerTeamMatchState {
            SoccerTeamMatchState(team: SoccerTeam(id: id, name: value.displayName,
                shortName: value.shortName, abbreviation: value.abbreviation),
                score: value.score.flatMap(Int.init), halfTimeScore: nil, redCards: 0)
        }
        return SoccerMatch(id: match.id, competitionID: "42", season: "", matchWeek: nil, phase: nil,
            kickoff: match.date, status: match.state == .final ? .fullTime : match.state == .live ? .firstHalf : .scheduled,
            clock: nil, home: side(match.home, id: homeID), away: side(match.away, id: awayID),
            ground: match.venue, attendance: nil, resultType: nil)
    }
}
