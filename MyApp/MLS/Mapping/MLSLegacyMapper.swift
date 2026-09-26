import Foundation

/// Bridges the canonical Soccer domain into the app-wide legacy models (`Match`,
/// `Team`, `StandingsGroup`, `RosterAthlete`) that `MatchesView`, `HomeView`,
/// `LiveView`, and the tvOS surfaces already consume via `SportsRepository` —
/// mirrors `EPLLegacyMapper`'s shape exactly.
nonisolated enum MLSLegacyMapper {
    static let league = League(name: "MLS", shortName: "MLS", path: "soccer/usa.1", group: .soccer)

    static func match(_ match: SoccerMatch) -> Match {
        func side(_ state: SoccerTeamMatchState) -> TeamSide {
            let isWinner = match.status == .fullTime && (state.score ?? -1) > (state.team.id == match.home.team.id ? match.away.score ?? -1 : match.home.score ?? -1)
            return TeamSide(displayName: state.team.name, shortName: state.team.shortName, abbreviation: state.team.abbreviation,
                logoURL: MLSAssetResolver.logoURL(teamID: state.team.id), score: state.score.map(String.init), record: nil, isWinner: isWinner,
                teamID: state.team.id, canonicalIDString: "team:\(league.bannerKey):mls:\(state.team.id)")
        }
        let state: GameState = match.status == .fullTime ? .final : match.status.isLive ? .live : .pre
        let context = MatchLiveContext(soccer: SoccerSituation(minute: match.clock?.minute.map(String.init), stoppageTime: match.clock?.addedMinute.map(String.init),
            aggregateScore: nil, homeRedCards: match.home.redCards, awayRedCards: match.away.redCards, latestEvent: nil))
        var result = Match(id: match.id, league: league, date: match.kickoff, name: "\(match.away.team.name) at \(match.home.team.name)",
            shortName: "\(match.away.team.abbreviation) @ \(match.home.team.abbreviation)", state: state,
            statusDetail: match.clock?.display ?? pregameDetail(match.kickoff), home: side(match.home), away: side(match.away),
            broadcasts: [], venue: match.ground, liveContext: context)
        result.canonicalID = "game:\(league.bannerKey):mls:\(match.id)"
        return result
    }

    private static func pregameDetail(_ kickoff: Date) -> String {
        kickoff.formatted(date: .abbreviated, time: .shortened)
    }

    static func team(_ team: SoccerTeam) -> Team {
        Team(id: team.id, displayName: team.name, shortDisplayName: team.shortName, abbreviation: team.abbreviation,
             logoURL: MLSAssetResolver.logoURL(teamID: team.id), canonicalIDString: "team:\(league.bannerKey):mls:\(team.id)")
    }

    /// One `StandingsGroup` per table — the caller passes every table it fetched
    /// (Eastern + Western when split by conference, or a single combined table),
    /// each keeping its own `groupLabel` as the display name.
    static func standingsGroups(_ tables: [SoccerStandingsTable]) -> [StandingsGroup] {
        tables.map { table in
            let rows = table.entries.sorted { ($0.overall.position ?? Int.max) < ($1.overall.position ?? Int.max) }.map { entry -> StandingRow in
                StandingRow(teamID: entry.team.id, displayName: entry.team.name, abbreviation: entry.team.abbreviation, logoURL: MLSAssetResolver.logoURL(teamID: entry.team.id),
                    record: [entry.overall.won, entry.overall.drawn, entry.overall.lost].compactMap { $0.map(String.init) }.joined(separator: "-"),
                    wins: entry.overall.won.map(String.init), losses: entry.overall.lost.map(String.init), ties: entry.overall.drawn.map(String.init),
                    winPercent: nil, gamesBack: nil, streak: nil, pointsFor: entry.overall.goalsFor.map(String.init), pointsAgainst: entry.overall.goalsAgainst.map(String.init),
                    leaguePoints: entry.overall.points.map(String.init), gamesPlayed: entry.overall.played.map(String.init), goalDiff: entry.overall.goalDifference.map(String.init))
            }
            let baseName = table.groupLabel ?? "MLS"
            let name = table.isLive ? "\(baseName) (Live)" : baseName
            let slug = (table.groupLabel ?? "overall").lowercased().replacingOccurrences(of: " ", with: "-")
            return StandingsGroup(id: "mls-\(slug)-\(table.isLive ? "live" : "official")", name: name, rows: rows)
        }
    }

    static func athlete(_ player: SoccerRosterPlayer) -> RosterAthlete {
        var result = RosterAthlete(id: player.reference.id, displayName: player.reference.fullName, jersey: player.shirtNumber, position: player.position,
            positionName: player.position, headshotURL: nil, age: player.dateOfBirth.map { Calendar.current.dateComponents([.year], from: $0, to: Date()).year ?? 0 },
            displayHeight: nil, displayWeight: nil, college: nil, experienceYears: nil, birthPlace: player.nationality, isInjured: false)
        result.canonicalID = "player:\(league.bannerKey):mls:\(player.reference.id)"
        return result
    }

    /// Lightweight convenience for Game Centre tap targets (goal scorer, carded
    /// player, lineup slot) that only have a name/id in hand — mirrors
    /// `EPLLegacyMapper.athlete(id:name:jersey:position:)`.
    static func athlete(id: String, name: String, jersey: String? = nil, position: String? = nil) -> RosterAthlete {
        var result = RosterAthlete(id: id, displayName: name, jersey: jersey, position: position, positionName: position,
            headshotURL: nil, age: nil, displayHeight: nil, displayWeight: nil, college: nil, experienceYears: nil, birthPlace: nil, isInjured: false)
        result.canonicalID = "player:\(league.bannerKey):mls:\(id)"
        return result
    }

    /// A minimal `SoccerMatch` from the already-available legacy `Match` so
    /// `SoccerGameCentreView`'s score hero has something to show before the first
    /// MLS response arrives.
    static func seed(from match: Match) -> SoccerMatch? {
        guard let homeID = match.home.teamID, let awayID = match.away.teamID else { return nil }
        func state(_ side: TeamSide, id: String) -> SoccerTeamMatchState {
            SoccerTeamMatchState(team: SoccerTeam(id: id, name: side.displayName, shortName: side.shortName, abbreviation: side.abbreviation),
                score: side.score.flatMap(Int.init), halfTimeScore: nil, redCards: 0)
        }
        return SoccerMatch(id: match.id, competitionID: MLSSeasonResolver.regularSeasonCompetitionID, season: String(Calendar.current.component(.year, from: match.date)),
            matchWeek: nil, phase: nil, kickoff: match.date, status: match.state == .final ? .fullTime : .scheduled, clock: nil,
            home: state(match.home, id: homeID), away: state(match.away, id: awayID), ground: match.venue, attendance: nil, resultType: nil)
    }
}
