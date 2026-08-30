import Foundation

struct NBAProvider: ScoreProvider, ScheduleProvider, GameDetailsProvider, BoxScoreProvider, PlayByPlayProvider, TeamProvider, StandingsProvider, RosterProvider, TeamStatsProvider, PlayerStatsProvider, LeagueLeaderProvider {
    let metadata: SportsDataProviderMetadata
    private let client: NBAClient

    init(client: NBAClient = NBAClient()) {
        self.client = client
        self.metadata = SportsDataProviderMetadata(
            id: .nba,
            name: "NBA CDN/Stats",
            supportLevel: .firstPartyWeb,
            supportedSports: [.basketball],
            supportedLeagues: ["basketball/nba", SportsProviderRouteConfiguration.leagueKey(forLegacyPath: "basketball/nba")],
            capabilities: [.liveScores, .schedule, .gameStatus, .gameDetails, .playByPlay, .boxScore, .teams, .standings, .rosters, .playerStats, .teamStats, .leagueLeaders],
            authenticationType: .publicWebHeaders,
            isEnabled: AppConfiguration.isNBAProviderEnabled,
            requestTimeout: 8
        )
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try ensureNBA(league)
        let games: [StadiaGame]
        do {
            let response = try await client.todayScoreboard()
            games = (response.scoreboard?.games ?? []).compactMap { mapGame($0, league: league) }
        } catch {
            let response = try await client.scoreboardV3(date: NBADateFormatter.statsDayString(from: Date()))
            games = mapScoreboardV3(response, league: league)
        }
        return games
            .filter { Calendar.current.isDate($0.scheduledStart, inSameDayAs: Date()) || $0.status == .live }
            .sorted { $0.scheduledStart < $1.scheduledStart }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        try ensureNBA(league)
        var games: [StadiaGame] = []
        for day in NBASeason.days(in: range) {
            if Calendar.current.isDate(day, inSameDayAs: Date()) {
                do {
                    let response = try await client.todayScoreboard()
                    games.append(contentsOf: (response.scoreboard?.games ?? []).compactMap { mapGame($0, league: league) })
                } catch {
                    let response = try await client.scoreboardV3(date: NBADateFormatter.statsDayString(from: day))
                    games.append(contentsOf: mapScoreboardV3(response, league: league))
                }
            } else {
                let response = try await client.scoreboardV3(date: NBADateFormatter.statsDayString(from: day))
                games.append(contentsOf: mapScoreboardV3(response, league: league))
            }
        }
        var seen = Set<StadiaEntityID>()
        games = games.filter { seen.insert($0.id).inserted }
            .filter { $0.scheduledStart >= range.start && $0.scheduledStart <= range.end }
            .sorted { $0.scheduledStart < $1.scheduledStart }
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:nba:\(league.stadiaKey):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: games,
            provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: nil, confidence: 0.88)
        )
    }

    func gameDetails(for league: League, gameID: StadiaEntityID) async throws -> StadiaGame {
        try ensureNBA(league)
        let providerGameID = try resolvedNBAGameID(from: gameID)
        let response = try await client.boxScore(gameID: providerGameID)
        guard let game = response.game.flatMap({ mapGame($0, league: league) }) else { throw SportsDataError.invalidResponse }
        return game
    }

    func boxScore(for league: League, gameID: StadiaEntityID) async throws -> StadiaBoxScore {
        try ensureNBA(league)
        let providerGameID = try resolvedNBAGameID(from: gameID)
        do {
            let response = try await client.boxScore(gameID: providerGameID)
            guard let game = response.game else { throw SportsDataError.invalidResponse }
            let teams = [game.homeTeam, game.awayTeam].compactMap { $0 }
            let teamStats = teams.compactMap { mapTeamStat($0, league: league, gameID: gameID) }
            let playerStats = teams.flatMap { team in
                (team.players ?? []).compactMap { mapPlayerStat($0, team: team, league: league, gameID: gameID) }
            }
            guard !teamStats.isEmpty || !playerStats.isEmpty else { throw SportsDataError.unsupportedCapability(.boxScore) }
            return StadiaBoxScore(
                id: StadiaEntityID(rawValue: "boxScore:nba:\(providerGameID)"),
                gameID: gameID,
                teamStats: teamStats,
                playerStats: playerStats,
                provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.86)
            )
        } catch {
            let response = try await client.boxScoreTraditionalV3(gameID: providerGameID)
            return try mapStatsBoxScore(response, league: league, gameID: gameID, providerGameID: providerGameID)
        }
    }

    func playByPlay(for league: League, gameID: StadiaEntityID) async throws -> StadiaPlayByPlay {
        try ensureNBA(league)
        let providerGameID = try resolvedNBAGameID(from: gameID)
        let plays: [StadiaPlay]
        do {
            let response = try await client.playByPlay(gameID: providerGameID)
            plays = (response.game?.actions ?? []).enumerated().compactMap { index, action -> StadiaPlay? in
                guard let text = action.description, !text.isEmpty else { return nil }
                return mapPlay(actionNumber: action.actionNumber ?? index, period: action.period, clock: action.clock, text: text, teamID: action.teamIDValue, awayScore: action.scoreAway, homeScore: action.scoreHome, isScoringPlay: action.isScoringPlay, league: league, providerGameID: providerGameID)
            }
        } catch {
            let response = try await client.playByPlayV3(gameID: providerGameID)
            plays = mapStatsPlayByPlay(response, league: league, providerGameID: providerGameID)
        }
        guard !plays.isEmpty else { throw SportsDataError.unsupportedCapability(.playByPlay) }
        return StadiaPlayByPlay(
            id: StadiaEntityID(rawValue: "pbp:nba:\(providerGameID)"),
            gameID: gameID,
            plays: plays,
            provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.84)
        )
    }

    func teams(for league: League) async throws -> [StadiaTeam] {
        try ensureNBA(league)
        return NBATeamDirectory.teams.map { mapDirectoryTeam($0, league: league) }
    }

    func standings(for league: League) async throws -> [StadiaStandingGroup] {
        try ensureNBA(league)
        let response = try await client.leagueStandings(season: NBASeason.currentStatsSeason)
        let rows = response.firstResultSet(named: "Standings")?.rowsByHeader ?? response.firstResultSet()?.rowsByHeader ?? []
        let standings = rows.enumerated().compactMap { index, row -> StadiaStanding? in
            guard let teamID = row.string("TeamID", "TEAM_ID"), let team = NBATeamDirectory.team(id: teamID) else { return nil }
            let mapped = mapDirectoryTeam(team, league: league)
            let wins = row.string("WINS", "Wins")
            let losses = row.string("LOSSES", "Losses")
            let group = row.string("Conference", "CONF_NAME", "Division", "DIVISION_NAME") ?? "NBA"
            return StadiaStanding(
                id: StadiaEntityID(rawValue: "standing:nba:\(teamID)"),
                teamID: mapped.id,
                teamDisplayName: mapped.displayName,
                teamAbbreviation: mapped.abbreviation,
                teamLogoURL: mapped.logoURL,
                groupName: group,
                rank: row.int("ConferenceRank", "CONF_RANK", "PlayoffRank", "PLAYOFF_RANK") ?? index + 1,
                wins: wins,
                losses: losses,
                ties: nil,
                points: row.string("WinPCT", "WinPCT") ?? row.string("W_PCT"),
                gamesPlayed: row.string("G", "GP"),
                displayRecord: [wins, losses].compactMap { $0 }.joined(separator: "-"),
                provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: teamID, confidence: 0.82)
            )
        }
        guard !standings.isEmpty else { throw SportsDataError.invalidResponse }
        let grouped = Dictionary(grouping: standings) { $0.groupName ?? "NBA" }
        return grouped.keys.sorted().map { key in
            StadiaStandingGroup(
                id: StadiaEntityID(rawValue: "standings:nba:\(SportsIdentityResolver.slug(key))"),
                name: key,
                standings: (grouped[key] ?? []).sorted { ($0.rank ?? Int.max) < ($1.rank ?? Int.max) }
            )
        }
    }

    func roster(for league: League, teamID: StadiaEntityID) async throws -> StadiaRoster {
        try ensureNBA(league)
        let providerTeamID = SportsIdentityResolver.providerID(from: teamID, provider: .nba) ?? NBAEntityIDParser.numericSuffix(from: teamID.rawValue)
        guard let providerTeamID else { throw SportsDataError.invalidResponse }
        let response = try await client.commonTeamRoster(teamID: providerTeamID, season: NBASeason.currentStatsSeason)
        let players = response.firstResultSet()?.rowsByHeader.compactMap { mapRosterPlayer($0, league: league, teamID: teamID, teamAbbreviation: NBATeamDirectory.team(id: providerTeamID)?.abbreviation) } ?? []
        guard !players.isEmpty else { throw SportsDataError.invalidResponse }
        return StadiaRoster(
            id: StadiaEntityID(rawValue: "roster:nba:\(providerTeamID)"),
            teamID: teamID,
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            players: players,
            provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerTeamID, confidence: 0.82)
        )
    }

    func teamStats(for league: League, teamIDs: Set<StadiaEntityID>, range: SportsDateRange?) async throws -> [StadiaTeamStat] {
        try ensureNBA(league)
        let response = try await client.teamStats(season: NBASeason.currentStatsSeason)
        let rows = response.firstResultSet()?.rowsByHeader ?? []
        return rows.compactMap { row in
            guard let providerTeamID = row.string("TEAM_ID"), let team = NBATeamDirectory.team(id: providerTeamID) else { return nil }
            let mappedTeam = mapDirectoryTeam(team, league: league)
            guard teamIDs.isEmpty || teamIDs.contains(mappedTeam.id) else { return nil }
            let stats = [
                stat("wins", "Wins", row.string("W")),
                stat("losses", "Losses", row.string("L")),
                stat("points", "PTS", row.string("PTS")),
                stat("rebounds", "REB", row.string("REB")),
                stat("assists", "AST", row.string("AST")),
                stat("fg_pct", "FG%", row.string("FG_PCT")),
                stat("three_pct", "3P%", row.string("FG3_PCT")),
                stat("turnovers", "Turnovers", row.string("TOV"))
            ].compactMap { $0 }
            guard !stats.isEmpty else { return nil }
            return StadiaTeamStat(id: StadiaEntityID(rawValue: "teamStat:nba:\(providerTeamID):season"), teamID: mappedTeam.id, seasonID: StadiaEntityID(rawValue: "season:nba:\(NBASeason.currentStatsSeason)"), stats: stats, provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerTeamID, confidence: 0.78))
        }
    }

    func playerStats(for league: League, playerIDs: Set<StadiaEntityID>, range: SportsDateRange?) async throws -> [StadiaPlayerStat] {
        try ensureNBA(league)
        let response = try await client.playerStats(season: NBASeason.currentStatsSeason)
        let rows = response.firstResultSet()?.rowsByHeader ?? []
        return rows.compactMap { row in
            guard let providerPlayerID = row.string("PLAYER_ID"), let name = row.string("PLAYER_NAME") else { return nil }
            let teamID = row.string("TEAM_ID").flatMap { mapTeamID($0, league: league) }
            let playerID = StadiaEntityID(rawValue: "player:\(league.stadiaKey):nba:\(providerPlayerID)")
            guard playerIDs.isEmpty || playerIDs.contains(playerID) else { return nil }
            let stats = [
                stat("points", "PTS", row.string("PTS")),
                stat("rebounds", "REB", row.string("REB")),
                stat("assists", "AST", row.string("AST")),
                stat("steals", "STL", row.string("STL")),
                stat("blocks", "BLK", row.string("BLK")),
                stat("fg_pct", "FG%", row.string("FG_PCT")),
                stat("three_pct", "3P%", row.string("FG3_PCT"))
            ].compactMap { $0 }
            guard !stats.isEmpty else { return nil }
            return StadiaPlayerStat(id: StadiaEntityID(rawValue: "playerStat:nba:\(providerPlayerID):season"), playerID: playerID, playerDisplayName: name, teamAbbreviation: row.string("TEAM_ABBREVIATION"), headshotURL: nil, teamID: teamID, seasonID: StadiaEntityID(rawValue: "season:nba:\(NBASeason.currentStatsSeason)"), stats: stats, provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerPlayerID, confidence: 0.78))
        }
    }

    func leaders(for league: League) async throws -> [StadiaLeader] {
        try ensureNBA(league)
        let response = try await client.leagueLeaders(season: NBASeason.currentStatsSeason)
        let rows = response.firstResultSet()?.rowsByHeader ?? []
        let players = rows.prefix(25).compactMap { row -> StadiaPlayerStat? in
            guard let providerPlayerID = row.string("PLAYER_ID"), let name = row.string("PLAYER") ?? row.string("PLAYER_NAME") else { return nil }
            let playerID = StadiaEntityID(rawValue: "player:\(league.stadiaKey):nba:\(providerPlayerID)")
            return StadiaPlayerStat(id: StadiaEntityID(rawValue: "leader:nba:pts:\(providerPlayerID)"), playerID: playerID, playerDisplayName: name, teamAbbreviation: row.string("TEAM"), headshotURL: nil, teamID: nil, seasonID: StadiaEntityID(rawValue: "season:nba:\(NBASeason.currentStatsSeason)"), stats: [StadiaStatValue(key: "points", displayName: "PTS", value: row.string("PTS") ?? row.string("VALUE") ?? "-")], provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerPlayerID, confidence: 0.76))
        }
        guard !players.isEmpty else { throw SportsDataError.invalidResponse }
        return [StadiaLeader(id: StadiaEntityID(rawValue: "leader:nba:points"), statKey: "points", displayName: "Points", players: players, provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: "PTS", confidence: 0.76))]
    }

    private func ensureNBA(_ league: League) throws {
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.nba) }
        guard league.path == "basketball/nba" else { throw SportsDataError.unsupportedCapability(.liveScores) }
    }

    private func resolvedNBAGameID(from gameID: StadiaEntityID) throws -> String {
        if let providerID = SportsIdentityResolver.providerID(from: gameID, provider: .nba) { return providerID }
        let raw = gameID.rawValue
        if raw.count == 10, raw.allSatisfy(\.isNumber) { return raw }
        if let value = raw.split(separator: ":").last.map(String.init), value.count == 10, value.allSatisfy(\.isNumber) { return value }
        throw SportsDataError.invalidResponse
    }

    private func mapGame(_ dto: NBALiveGameDTO, league: League) -> StadiaGame? {
        guard let providerGameID = dto.gameIDValue, let homeDTO = dto.homeTeam, let awayDTO = dto.awayTeam else { return nil }
        let home = mapTeam(homeDTO, league: league)
        let away = mapTeam(awayDTO, league: league)
        let start = NBADateFormatter.date(from: dto.gameTimeUTC ?? dto.gameTimeLocal ?? dto.gameEt) ?? Date()
        let status = StadiaGameStatus(nbaStatusCode: dto.gameStatus, text: dto.gameStatusText, start: start)
        let detail = NBAStatusFormatter.detail(status: status, text: dto.gameStatusText, start: start)
        return StadiaGame(
            id: StadiaEntityID(rawValue: "game:\(league.stadiaKey):nba:\(providerGameID)"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            scheduledStart: start,
            name: dto.gameLabel ?? "\(away.displayName) at \(home.displayName)",
            shortName: dto.gameCode?.split(separator: "/").last.map(String.init) ?? "\(away.abbreviation) @ \(home.abbreviation)",
            status: status,
            statusDetail: detail,
            homeTeam: home,
            awayTeam: away,
            score: StadiaScore(home: homeDTO.score.map(String.init), away: awayDTO.score.map(String.init)),
            clock: dto.gameClock.flatMap { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: status == .live) },
            period: dto.period.map { StadiaPeriod(number: $0, displayName: NBAPeriodFormatter.displayName(for: $0)) },
            venue: dto.stadiaVenue,
            broadcasts: dto.stadiaBroadcasts,
            aliases: [ProviderEntityAlias(provider: .nba, id: providerGameID)],
            provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.88)
        )
    }

    private func mapScoreboardV3(_ response: NBAStatsResponseDTO, league: League) -> [StadiaGame] {
        let rows = response.firstResultSet(named: "GameHeader")?.rowsByHeader ?? response.firstResultSet()?.rowsByHeader ?? []
        return rows.compactMap { row in
            guard let providerGameID = row.string("GAME_ID"),
                  let homeTeamID = row.string("HOME_TEAM_ID"),
                  let awayTeamID = row.string("VISITOR_TEAM_ID", "AWAY_TEAM_ID"),
                  let homeDir = NBATeamDirectory.team(id: homeTeamID),
                  let awayDir = NBATeamDirectory.team(id: awayTeamID) else { return nil }
            let home = mapDirectoryTeam(homeDir, league: league)
            let away = mapDirectoryTeam(awayDir, league: league)
            let date = NBADateFormatter.date(from: row.string("GAME_DATE_EST", "GAME_DATE")) ?? Date()
            let text = row.string("GAME_STATUS_TEXT")
            let status = StadiaGameStatus(nbaStatusCode: row.int("GAME_STATUS_ID", "GAME_STATUS"), text: text, start: date)
            return StadiaGame(
                id: StadiaEntityID(rawValue: "game:\(league.stadiaKey):nba:\(providerGameID)"),
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                scheduledStart: date,
                name: "\(away.displayName) at \(home.displayName)",
                shortName: "\(away.abbreviation) @ \(home.abbreviation)",
                status: status,
                statusDetail: NBAStatusFormatter.detail(status: status, text: text, start: date),
                homeTeam: home,
                awayTeam: away,
                score: StadiaScore(home: row.string("HOME_TEAM_SCORE", "PTS_HOME"), away: row.string("VISITOR_TEAM_SCORE", "PTS_AWAY")),
                clock: nil,
                period: row.int("PERIOD").map { StadiaPeriod(number: $0, displayName: NBAPeriodFormatter.displayName(for: $0)) },
                venue: nil,
                broadcasts: [],
                aliases: [ProviderEntityAlias(provider: .nba, id: providerGameID)],
                provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.8)
            )
        }
    }

    private func mapStatsBoxScore(_ response: NBAStatsResponseDTO, league: League, gameID: StadiaEntityID, providerGameID: String) throws -> StadiaBoxScore {
        let teamRows = response.firstResultSet(named: "TeamStats")?.rowsByHeader ?? []
        let playerRows = response.firstResultSet(named: "PlayerStats")?.rowsByHeader ?? response.firstResultSet()?.rowsByHeader ?? []
        let teamStats = teamRows.compactMap { row -> StadiaTeamStat? in
            guard let providerTeamID = row.string("teamId", "TEAM_ID"), let team = NBATeamDirectory.team(id: providerTeamID) else { return nil }
            let mapped = mapDirectoryTeam(team, league: league)
            let stats = [
                stat("score", "Score", row.string("points", "PTS")),
                stat("rebounds", "Rebounds", row.string("reboundsTotal", "REB")),
                stat("assists", "Assists", row.string("assists", "AST")),
                stat("turnovers", "Turnovers", row.string("turnovers", "TOV")),
                stat("steals", "Steals", row.string("steals", "STL")),
                stat("blocks", "Blocks", row.string("blocks", "BLK")),
                stat("fg_pct", "FG%", row.string("fieldGoalsPercentage", "FG_PCT")),
                stat("three_pct", "3P%", row.string("threePointersPercentage", "FG3_PCT"))
            ].compactMap { $0 }
            guard !stats.isEmpty else { return nil }
            return StadiaTeamStat(id: StadiaEntityID(rawValue: "teamStat:nba:\(providerGameID):\(providerTeamID)"), teamID: mapped.id, seasonID: nil, stats: stats, provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerTeamID, confidence: 0.78))
        }
        let playerStats = playerRows.compactMap { row -> StadiaPlayerStat? in
            guard let providerPlayerID = row.string("personId", "PLAYER_ID"), let name = row.string("name", "nameI", "PLAYER_NAME") else { return nil }
            let providerTeamID = row.string("teamId", "TEAM_ID")
            let teamID = providerTeamID.flatMap { mapTeamID($0, league: league) }
            let stats = [
                stat("minutes", "MIN", row.string("minutes", "MIN")),
                stat("points", "PTS", row.string("points", "PTS")),
                stat("rebounds", "REB", row.string("reboundsTotal", "REB")),
                stat("assists", "AST", row.string("assists", "AST")),
                stat("steals", "STL", row.string("steals", "STL")),
                stat("blocks", "BLK", row.string("blocks", "BLK")),
                stat("turnovers", "TO", row.string("turnovers", "TOV")),
                stat("plus_minus", "+/-", row.string("plusMinusPoints", "PLUS_MINUS"))
            ].compactMap { $0 }
            guard !stats.isEmpty else { return nil }
            return StadiaPlayerStat(id: StadiaEntityID(rawValue: "playerStat:nba:\(providerGameID):\(providerPlayerID)"), playerID: StadiaEntityID(rawValue: "player:\(league.stadiaKey):nba:\(providerPlayerID)"), playerDisplayName: name, teamAbbreviation: row.string("teamTricode", "TEAM_ABBREVIATION"), headshotURL: nil, teamID: teamID, seasonID: nil, stats: stats, provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerPlayerID, confidence: 0.78))
        }
        guard !teamStats.isEmpty || !playerStats.isEmpty else { throw SportsDataError.unsupportedCapability(.boxScore) }
        return StadiaBoxScore(id: StadiaEntityID(rawValue: "boxScore:nba:\(providerGameID)"), gameID: gameID, teamStats: teamStats, playerStats: playerStats, provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.78))
    }

    private func mapStatsPlayByPlay(_ response: NBAStatsResponseDTO, league: League, providerGameID: String) -> [StadiaPlay] {
        let rows = response.firstResultSet(named: "PlayByPlay")?.rowsByHeader ?? response.firstResultSet()?.rowsByHeader ?? []
        return rows.enumerated().compactMap { index, row in
            guard let text = row.string("description", "HOMEDESCRIPTION", "VISITORDESCRIPTION", "NEUTRALDESCRIPTION") else { return nil }
            return mapPlay(actionNumber: row.int("actionNumber", "EVENTNUM") ?? index, period: row.int("period", "PERIOD"), clock: row.string("clock", "PCTIMESTRING"), text: text, teamID: row.string("teamId", "TEAM_ID"), awayScore: row.string("scoreAway", "SCORE_AWAY"), homeScore: row.string("scoreHome", "SCORE_HOME"), isScoringPlay: text.lowercased().contains("makes") || text.lowercased().contains("made"), league: league, providerGameID: providerGameID)
        }
    }

    private func mapPlay(actionNumber: Int, period: Int?, clock: String?, text: String, teamID: String?, awayScore: String?, homeScore: String?, isScoringPlay: Bool, league: League, providerGameID: String) -> StadiaPlay {
        StadiaPlay(
            id: StadiaEntityID(rawValue: "play:nba:\(providerGameID):\(actionNumber)"),
            sequence: actionNumber,
            period: period.map { StadiaPeriod(number: $0, displayName: NBAPeriodFormatter.displayName(for: $0)) },
            clock: clock.map { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: nil) },
            text: text,
            teamID: teamID.flatMap { mapTeamID($0, league: league) },
            awayScore: awayScore,
            homeScore: homeScore,
            isScoringPlay: isScoringPlay,
            provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: String(actionNumber), confidence: 0.8)
        )
    }

    private func mapTeam(_ dto: NBATeamDTO, league: League) -> StadiaTeam {
        let providerID = dto.teamID.map(String.init) ?? dto.teamId.map(String.init) ?? dto.id.map(String.init) ?? dto.teamTricode ?? "nba"
        let abbreviation = dto.teamTricode ?? dto.triCode ?? dto.abbreviation ?? providerID
        let displayName = [dto.teamCity, dto.teamName].compactMap { $0 }.joined(separator: " ").nonEmpty ?? dto.teamName ?? dto.name ?? abbreviation
        return StadiaTeam(
            id: StadiaEntityID(rawValue: "team:\(league.stadiaKey):nba:\(providerID)"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: displayName,
            shortName: dto.teamName ?? dto.name ?? abbreviation,
            abbreviation: abbreviation,
            logoURL: NBATeamDirectory.team(id: providerID)?.logoURL,
            aliases: [ProviderEntityAlias(provider: .nba, id: providerID)],
            provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerID, confidence: 0.88)
        )
    }

    private func mapDirectoryTeam(_ team: NBADirectoryTeam, league: League) -> StadiaTeam {
        StadiaTeam(
            id: StadiaEntityID(rawValue: "team:\(league.stadiaKey):nba:\(team.id)"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: team.displayName,
            shortName: team.nickname,
            abbreviation: team.abbreviation,
            logoURL: team.logoURL,
            aliases: [ProviderEntityAlias(provider: .nba, id: team.id)],
            provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: team.id, confidence: 0.9)
        )
    }

    private func mapTeamID(_ providerTeamID: String, league: League) -> StadiaEntityID? {
        guard NBATeamDirectory.team(id: providerTeamID) != nil else { return nil }
        return StadiaEntityID(rawValue: "team:\(league.stadiaKey):nba:\(providerTeamID)")
    }

    private func mapRosterPlayer(_ row: [String: NBAStatsValue], league: League, teamID: StadiaEntityID, teamAbbreviation: String?) -> StadiaPlayer? {
        guard let providerPlayerID = row.string("PLAYER_ID", "PERSON_ID"), let name = row.string("PLAYER", "PLAYER_NAME") else { return nil }
        return StadiaPlayer(
            id: StadiaEntityID(rawValue: "player:\(league.stadiaKey):nba:\(providerPlayerID)"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            fullName: name,
            displayName: name,
            teamID: teamID,
            teamAbbreviation: teamAbbreviation,
            position: row.string("POSITION"),
            jerseyNumber: row.string("NUM", "JERSEY"),
            birthDate: nil,
            headshotURL: nil,
            aliases: [ProviderEntityAlias(provider: .nba, id: providerPlayerID)],
            provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerPlayerID, confidence: 0.82)
        )
    }

    private func mapTeamStat(_ team: NBATeamDTO, league: League, gameID: StadiaEntityID) -> StadiaTeamStat? {
        let mapped = mapTeam(team, league: league)
        let stats = [
            stat("score", "Score", team.score.map(String.init)),
            stat("fg_pct", "FG%", team.statistics?.fieldGoalsPercentage),
            stat("three_pct", "3P%", team.statistics?.threePointersPercentage),
            stat("ft_pct", "FT%", team.statistics?.freeThrowsPercentage),
            stat("rebounds", "Rebounds", team.statistics?.reboundsTotal.map(String.init)),
            stat("assists", "Assists", team.statistics?.assists.map(String.init)),
            stat("turnovers", "Turnovers", team.statistics?.turnovers.map(String.init)),
            stat("steals", "Steals", team.statistics?.steals.map(String.init)),
            stat("blocks", "Blocks", team.statistics?.blocks.map(String.init))
        ].compactMap { $0 }
        guard !stats.isEmpty else { return nil }
        return StadiaTeamStat(id: StadiaEntityID(rawValue: "teamStat:nba:\(gameID.rawValue):\(mapped.id.rawValue)"), teamID: mapped.id, seasonID: nil, stats: stats, provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: team.providerID, confidence: 0.84))
    }

    private func mapPlayerStat(_ player: NBAPlayerDTO, team: NBATeamDTO, league: League, gameID: StadiaEntityID) -> StadiaPlayerStat? {
        guard let providerPlayerID = player.personID.map(String.init) ?? player.personId.map(String.init) ?? player.playerID.map(String.init), let name = player.name ?? player.nameI else { return nil }
        let teamID = mapTeam(team, league: league).id
        let stats = [
            stat("minutes", "MIN", player.statistics?.minutes),
            stat("points", "PTS", player.statistics?.points.map(String.init)),
            stat("rebounds", "REB", player.statistics?.reboundsTotal.map(String.init)),
            stat("assists", "AST", player.statistics?.assists.map(String.init)),
            stat("steals", "STL", player.statistics?.steals.map(String.init)),
            stat("blocks", "BLK", player.statistics?.blocks.map(String.init)),
            stat("turnovers", "TO", player.statistics?.turnovers.map(String.init)),
            stat("plus_minus", "+/-", player.statistics?.plusMinusPoints.map(String.init))
        ].compactMap { $0 }
        guard !stats.isEmpty else { return nil }
        return StadiaPlayerStat(id: StadiaEntityID(rawValue: "playerStat:nba:\(gameID.rawValue):\(providerPlayerID)"), playerID: StadiaEntityID(rawValue: "player:\(league.stadiaKey):nba:\(providerPlayerID)"), playerDisplayName: name, teamAbbreviation: team.teamTricode ?? team.abbreviation, headshotURL: nil, teamID: teamID, seasonID: nil, stats: stats, provenance: DataProvenance(provider: .nba, fetchedAt: Date(), providerEntityID: providerPlayerID, confidence: 0.84))
    }

    private func stat(_ key: String, _ displayName: String, _ value: String?) -> StadiaStatValue? {
        guard let value, !value.isEmpty else { return nil }
        return StadiaStatValue(key: key, displayName: displayName, value: value)
    }
}

struct NBAClient: Sendable {
    private let liveDataBaseURL = URL(string: "https://cdn.nba.com/static/json/liveData")!
    private let statsBaseURL = URL(string: "https://stats.nba.com/stats")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func todayScoreboard() async throws -> NBAScoreboardResponseDTO {
        try await cdnGet(path: "scoreboard/todaysScoreboard_00.json")
    }

    func boxScore(gameID: String) async throws -> NBABoxScoreResponseDTO {
        try await cdnGet(path: "boxscore/boxscore_\(gameID).json")
    }

    func playByPlay(gameID: String) async throws -> NBAPlayByPlayResponseDTO {
        try await cdnGet(path: "playbyplay/playbyplay_\(gameID).json")
    }

    func boxScoreTraditionalV3(gameID: String) async throws -> NBAStatsResponseDTO {
        try await statsGet(path: "boxscoretraditionalv3", queryItems: [
            URLQueryItem(name: "GameID", value: gameID),
            URLQueryItem(name: "StartPeriod", value: "0"),
            URLQueryItem(name: "EndPeriod", value: "0"),
            URLQueryItem(name: "StartRange", value: "0"),
            URLQueryItem(name: "EndRange", value: "0"),
            URLQueryItem(name: "RangeType", value: "0")
        ])
    }

    func playByPlayV3(gameID: String) async throws -> NBAStatsResponseDTO {
        try await statsGet(path: "playbyplayv3", queryItems: [
            URLQueryItem(name: "GameID", value: gameID),
            URLQueryItem(name: "StartPeriod", value: "0"),
            URLQueryItem(name: "EndPeriod", value: "0")
        ])
    }

    func scoreboardV3(date: String) async throws -> NBAStatsResponseDTO {
        try await statsGet(path: "scoreboardv3", queryItems: [URLQueryItem(name: "GameDate", value: date), URLQueryItem(name: "LeagueID", value: "00")])
    }

    func leagueStandings(season: String) async throws -> NBAStatsResponseDTO {
        try await statsGet(path: "leaguestandingsv3", queryItems: [URLQueryItem(name: "LeagueID", value: "00"), URLQueryItem(name: "Season", value: season), URLQueryItem(name: "SeasonType", value: "Regular Season")])
    }

    func commonTeamRoster(teamID: String, season: String) async throws -> NBAStatsResponseDTO {
        try await statsGet(path: "commonteamroster", queryItems: [URLQueryItem(name: "LeagueID", value: "00"), URLQueryItem(name: "Season", value: season), URLQueryItem(name: "TeamID", value: teamID)])
    }

    func teamStats(season: String) async throws -> NBAStatsResponseDTO {
        try await statsGet(path: "leaguedashteamstats", queryItems: NBAStatsQuery.standardSeason(season: season))
    }

    func playerStats(season: String) async throws -> NBAStatsResponseDTO {
        try await statsGet(path: "leaguedashplayerstats", queryItems: NBAStatsQuery.standardSeason(season: season))
    }

    func leagueLeaders(season: String) async throws -> NBAStatsResponseDTO {
        try await statsGet(path: "leagueleaders", queryItems: [URLQueryItem(name: "LeagueID", value: "00"), URLQueryItem(name: "PerMode", value: "PerGame"), URLQueryItem(name: "Scope", value: "S"), URLQueryItem(name: "Season", value: season), URLQueryItem(name: "SeasonType", value: "Regular Season"), URLQueryItem(name: "StatCategory", value: "PTS")])
    }

    private func cdnGet<T: Decodable>(path: String) async throws -> T {
        var request = URLRequest(url: liveDataBaseURL.appendingPathComponent(path))
        request.timeoutInterval = 8
        NBAHeaders.applyCDN(to: &request)
        return try await send(request)
    }

    private func statsGet<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: statsBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw SportsDataError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        NBAHeaders.applyStats(to: &request)
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SportsDataError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                return try NBAJSONDecoder.decoder.decode(T.self, from: data)
            case 401, 403:
                throw SportsDataError.authenticationFailed
            case 429:
                throw SportsDataError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
            case 500..<600:
                throw SportsDataError.unavailable
            default:
                throw SportsDataError.network("NBA HTTP \(http.statusCode)")
            }
        } catch let error as SportsDataError {
            throw error
        } catch is DecodingError {
            throw SportsDataError.decodingFailed
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }
}

struct NBAScoreboardResponseDTO: Decodable, Sendable { let scoreboard: NBAScoreboardDTO? }
struct NBAScoreboardDTO: Decodable, Sendable { let games: [NBALiveGameDTO]? }
struct NBABoxScoreResponseDTO: Decodable, Sendable { let game: NBALiveGameDTO? }
struct NBAPlayByPlayResponseDTO: Decodable, Sendable { let game: NBAPlayByPlayGameDTO? }
struct NBAPlayByPlayGameDTO: Decodable, Sendable { let actions: [NBAActionDTO]? }

struct NBALiveGameDTO: Decodable, Sendable {
    let gameID: String?
    let gameId: String?
    let gameCode: String?
    let gameStatus: Int?
    let gameStatusText: String?
    let gameTimeUTC: String?
    let gameTimeLocal: String?
    let gameEt: String?
    let gameClock: String?
    let period: Int?
    let gameLabel: String?
    let arenaName: String?
    let arenaCity: String?
    let arenaState: String?
    let arenaCountry: String?
    let homeTeam: NBATeamDTO?
    let awayTeam: NBATeamDTO?
    let gameBroadcasters: NBABroadcastersDTO?

    enum CodingKeys: String, CodingKey {
        case gameID = "gameId"
        case gameId = "gameID"
        case gameCode, gameStatus, gameStatusText, gameTimeUTC, gameTimeLocal, gameEt, gameClock, period, gameLabel, arenaName, arenaCity, arenaState, arenaCountry, homeTeam, awayTeam
        case gameBroadcasters = "broadcasts"
    }

    var gameIDValue: String? { gameID ?? gameId }
    var stadiaBroadcasts: [StadiaBroadcast] { gameBroadcasters?.stadiaBroadcasts ?? [] }
    var stadiaVenue: StadiaVenue? {
        guard arenaName != nil || arenaCity != nil else { return nil }
        return StadiaVenue(id: nil, name: arenaName ?? "Arena", city: arenaCity, state: arenaState, country: arenaCountry, aliases: [])
    }
}

struct NBATeamDTO: Decodable, Sendable {
    let teamID: Int?
    let teamId: Int?
    let id: Int?
    let teamName: String?
    let teamCity: String?
    let teamTricode: String?
    let triCode: String?
    let abbreviation: String?
    let name: String?
    let score: Int?
    let statistics: NBAStatisticsDTO?
    let players: [NBAPlayerDTO]?

    enum CodingKeys: String, CodingKey {
        case teamID = "teamId"
        case teamId = "teamID"
        case id, teamName, teamCity, teamTricode, triCode, abbreviation, name, score, statistics, players
    }

    var providerID: String? { teamID.map(String.init) ?? teamId.map(String.init) ?? id.map(String.init) }
}

struct NBAPlayerDTO: Decodable, Sendable {
    let personID: Int?
    let personId: Int?
    let playerID: Int?
    let name: String?
    let nameI: String?
    let statistics: NBAStatisticsDTO?

    enum CodingKeys: String, CodingKey {
        case personID = "personId"
        case personId = "personID"
        case playerID = "playerId"
        case name, nameI, statistics
    }
}

struct NBAStatisticsDTO: Decodable, Sendable {
    let minutes: String?
    let points: Int?
    let assists: Int?
    let blocks: Int?
    let steals: Int?
    let turnovers: Int?
    let reboundsTotal: Int?
    let fieldGoalsPercentage: String?
    let threePointersPercentage: String?
    let freeThrowsPercentage: String?
    let plusMinusPoints: Int?
}

struct NBAActionDTO: Decodable, Sendable {
    let actionNumber: Int?
    let clock: String?
    let period: Int?
    let description: String?
    let teamID: String?
    let scoreHome: String?
    let scoreAway: String?
    let shotResult: String?
    let actionType: String?
    let subType: String?

    enum CodingKeys: String, CodingKey {
        case actionNumber, clock, period, description, teamId, teamID, scoreHome, scoreAway, shotResult, actionType, subType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actionNumber = try container.decodeIfPresent(Int.self, forKey: .actionNumber)
        clock = try container.decodeIfPresent(String.self, forKey: .clock)
        period = try container.decodeIfPresent(Int.self, forKey: .period)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        if let intID = try? container.decodeIfPresent(Int.self, forKey: .teamId) {
            teamID = String(intID)
        } else if let intID = try? container.decodeIfPresent(Int.self, forKey: .teamID) {
            teamID = String(intID)
        } else {
            let lowerCamelID = try container.decodeIfPresent(String.self, forKey: .teamId)
            let upperCamelID = try container.decodeIfPresent(String.self, forKey: .teamID)
            teamID = lowerCamelID ?? upperCamelID
        }
        scoreHome = try container.decodeIfPresent(String.self, forKey: .scoreHome)
        scoreAway = try container.decodeIfPresent(String.self, forKey: .scoreAway)
        shotResult = try container.decodeIfPresent(String.self, forKey: .shotResult)
        actionType = try container.decodeIfPresent(String.self, forKey: .actionType)
        subType = try container.decodeIfPresent(String.self, forKey: .subType)
    }

    var isScoringPlay: Bool {
        if let shotResult, shotResult.lowercased() == "made" { return true }
        let text = [actionType, subType, description].compactMap { $0 }.joined(separator: " ").lowercased()
        return text.contains("made") || text.contains("free throw")
    }

    var teamIDValue: String? { teamID }
}

struct NBABroadcastersDTO: Decodable, Sendable {
    let nationalTvBroadcasters: [NBABroadcastDTO]?
    let homeTvBroadcasters: [NBABroadcastDTO]?
    let awayTvBroadcasters: [NBABroadcastDTO]?

    var stadiaBroadcasts: [StadiaBroadcast] {
        let broadcasters = (nationalTvBroadcasters ?? []) + (homeTvBroadcasters ?? []) + (awayTvBroadcasters ?? [])
        var seen = Set<String>()
        return broadcasters.compactMap { item in
            guard let network = item.broadcasterDisplay ?? item.broadcasterName, !network.isEmpty, seen.insert(network).inserted else { return nil }
            return StadiaBroadcast(network: network, type: "TV", countryCode: nil)
        }
    }
}

struct NBABroadcastDTO: Decodable, Sendable { let broadcasterDisplay: String?; let broadcasterName: String? }

struct NBAStatsResponseDTO: Decodable, Sendable {
    let resultSets: [NBAStatsResultSetDTO]?
    let resultSet: NBAStatsResultSetDTO?

    func firstResultSet(named name: String? = nil) -> NBAStatsResultSetDTO? {
        if let name { return resultSets?.first { $0.name?.caseInsensitiveCompare(name) == .orderedSame } }
        return resultSets?.first ?? resultSet
    }
}

struct NBAStatsResultSetDTO: Decodable, Sendable {
    let name: String?
    let headers: [String]?
    let rowSet: [[NBAStatsValue]]?

    var rowsByHeader: [[String: NBAStatsValue]] {
        guard let headers, let rowSet else { return [] }
        return rowSet.map { row in
            Dictionary(uniqueKeysWithValues: zip(headers, row))
        }
    }
}

enum NBAStatsValue: Decodable, Sendable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { self = .string((try? container.decode(String.self)) ?? "") }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value.isEmpty ? nil : value
        case .double(let value): return String(value)
        case .int(let value): return String(value)
        case .bool(let value): return String(value)
        case .null: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }
}

struct NBADirectoryTeam: Sendable {
    let id: String
    let city: String
    let nickname: String
    let abbreviation: String

    var displayName: String { "\(city) \(nickname)" }
    var logoURL: URL? { TeamLogoAssetResolver.nbaAssetURL(abbreviation: abbreviation) ?? URL(string: "https://cdn.nba.com/logos/nba/\(id)/primary/L/logo.svg") }
}

enum NBATeamDirectory {
    nonisolated static let teams: [NBADirectoryTeam] = [
        .init(id: "1610612737", city: "Atlanta", nickname: "Hawks", abbreviation: "ATL"),
        .init(id: "1610612738", city: "Boston", nickname: "Celtics", abbreviation: "BOS"),
        .init(id: "1610612739", city: "Cleveland", nickname: "Cavaliers", abbreviation: "CLE"),
        .init(id: "1610612740", city: "New Orleans", nickname: "Pelicans", abbreviation: "NOP"),
        .init(id: "1610612741", city: "Chicago", nickname: "Bulls", abbreviation: "CHI"),
        .init(id: "1610612742", city: "Dallas", nickname: "Mavericks", abbreviation: "DAL"),
        .init(id: "1610612743", city: "Denver", nickname: "Nuggets", abbreviation: "DEN"),
        .init(id: "1610612744", city: "Golden State", nickname: "Warriors", abbreviation: "GSW"),
        .init(id: "1610612745", city: "Houston", nickname: "Rockets", abbreviation: "HOU"),
        .init(id: "1610612746", city: "LA", nickname: "Clippers", abbreviation: "LAC"),
        .init(id: "1610612747", city: "Los Angeles", nickname: "Lakers", abbreviation: "LAL"),
        .init(id: "1610612748", city: "Miami", nickname: "Heat", abbreviation: "MIA"),
        .init(id: "1610612749", city: "Milwaukee", nickname: "Bucks", abbreviation: "MIL"),
        .init(id: "1610612750", city: "Minnesota", nickname: "Timberwolves", abbreviation: "MIN"),
        .init(id: "1610612751", city: "Brooklyn", nickname: "Nets", abbreviation: "BKN"),
        .init(id: "1610612752", city: "New York", nickname: "Knicks", abbreviation: "NYK"),
        .init(id: "1610612753", city: "Orlando", nickname: "Magic", abbreviation: "ORL"),
        .init(id: "1610612754", city: "Indiana", nickname: "Pacers", abbreviation: "IND"),
        .init(id: "1610612755", city: "Philadelphia", nickname: "76ers", abbreviation: "PHI"),
        .init(id: "1610612756", city: "Phoenix", nickname: "Suns", abbreviation: "PHX"),
        .init(id: "1610612757", city: "Portland", nickname: "Trail Blazers", abbreviation: "POR"),
        .init(id: "1610612758", city: "Sacramento", nickname: "Kings", abbreviation: "SAC"),
        .init(id: "1610612759", city: "San Antonio", nickname: "Spurs", abbreviation: "SAS"),
        .init(id: "1610612760", city: "Oklahoma City", nickname: "Thunder", abbreviation: "OKC"),
        .init(id: "1610612761", city: "Toronto", nickname: "Raptors", abbreviation: "TOR"),
        .init(id: "1610612762", city: "Utah", nickname: "Jazz", abbreviation: "UTA"),
        .init(id: "1610612763", city: "Memphis", nickname: "Grizzlies", abbreviation: "MEM"),
        .init(id: "1610612764", city: "Washington", nickname: "Wizards", abbreviation: "WAS"),
        .init(id: "1610612765", city: "Detroit", nickname: "Pistons", abbreviation: "DET"),
        .init(id: "1610612766", city: "Charlotte", nickname: "Hornets", abbreviation: "CHA")
    ]

    nonisolated static func team(id: String) -> NBADirectoryTeam? { teams.first { $0.id == id } }
}

enum NBAHeaders {
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    nonisolated static func applyCDN(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.nba.com/", forHTTPHeaderField: "Referer")
    }

    nonisolated static func applyStats(to request: inout URLRequest) {
        applyCDN(to: &request)
        request.setValue("https://www.nba.com", forHTTPHeaderField: "Origin")
        request.setValue("stats", forHTTPHeaderField: "x-nba-stats-origin")
        request.setValue("true", forHTTPHeaderField: "x-nba-stats-token")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    }
}

enum NBAStatsQuery {
    nonisolated static func standardSeason(season: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "College", value: ""),
            URLQueryItem(name: "Conference", value: ""),
            URLQueryItem(name: "Country", value: ""),
            URLQueryItem(name: "DateFrom", value: ""),
            URLQueryItem(name: "DateTo", value: ""),
            URLQueryItem(name: "Division", value: ""),
            URLQueryItem(name: "DraftPick", value: ""),
            URLQueryItem(name: "DraftYear", value: ""),
            URLQueryItem(name: "GameScope", value: ""),
            URLQueryItem(name: "GameSegment", value: ""),
            URLQueryItem(name: "Height", value: ""),
            URLQueryItem(name: "LastNGames", value: "0"),
            URLQueryItem(name: "LeagueID", value: "00"),
            URLQueryItem(name: "Location", value: ""),
            URLQueryItem(name: "MeasureType", value: "Base"),
            URLQueryItem(name: "Month", value: "0"),
            URLQueryItem(name: "OpponentTeamID", value: "0"),
            URLQueryItem(name: "Outcome", value: ""),
            URLQueryItem(name: "PORound", value: "0"),
            URLQueryItem(name: "PaceAdjust", value: "N"),
            URLQueryItem(name: "PerMode", value: "PerGame"),
            URLQueryItem(name: "Period", value: "0"),
            URLQueryItem(name: "PlayerExperience", value: ""),
            URLQueryItem(name: "PlayerPosition", value: ""),
            URLQueryItem(name: "PlusMinus", value: "N"),
            URLQueryItem(name: "Rank", value: "N"),
            URLQueryItem(name: "Season", value: season),
            URLQueryItem(name: "SeasonSegment", value: ""),
            URLQueryItem(name: "SeasonType", value: "Regular Season"),
            URLQueryItem(name: "ShotClockRange", value: ""),
            URLQueryItem(name: "StarterBench", value: ""),
            URLQueryItem(name: "TeamID", value: "0"),
            URLQueryItem(name: "TwoWay", value: "0"),
            URLQueryItem(name: "VsConference", value: ""),
            URLQueryItem(name: "VsDivision", value: ""),
            URLQueryItem(name: "Weight", value: "")
        ]
    }
}

enum NBAJSONDecoder { nonisolated static var decoder: JSONDecoder { JSONDecoder() } }

enum NBADateFormatter {
    nonisolated static func statsDayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

enum NBASeason {
    nonisolated static var currentStatsSeason: String {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        let month = calendar.component(.month, from: Date())
        let startYear = month >= 10 ? year : year - 1
        let end = String(format: "%02d", (startYear + 1) % 100)
        return "\(startYear)-\(end)"
    }

    nonisolated static func days(in range: SportsDateRange) -> [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: range.start)
        let end = calendar.startOfDay(for: range.end)
        let count = min(max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1), 14)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

enum NBAEntityIDParser {
    nonisolated static func numericSuffix(from value: String) -> String? {
        value.split(separator: ":").last.map(String.init).flatMap { suffix in
            suffix.allSatisfy(\.isNumber) ? suffix : nil
        }
    }
}

enum NBAPeriodFormatter {
    nonisolated static func displayName(for period: Int) -> String {
        if period <= 4 { return "Q\(period)" }
        return "OT\(period - 4)"
    }
}

enum NBAStatusFormatter {
    nonisolated static func detail(status: StadiaGameStatus, text: String?, start: Date) -> String {
        if let text, !text.isEmpty { return text }
        if status == .final { return "Final" }
        if status == .live { return "In Progress" }
        return RelativeDateTimeFormatter().localizedString(for: start, relativeTo: Date())
    }
}

extension StadiaGameStatus {
    init(nbaStatusCode: Int?, text: String?, start: Date) {
        let normalized = (text ?? "").lowercased()
        if nbaStatusCode == 3 || normalized.contains("final") { self = .final }
        else if nbaStatusCode == 2 || normalized.contains("qtr") || normalized.contains("halftime") || normalized.contains("ot") || normalized.contains(":") { self = .live }
        else if normalized.contains("postpon") { self = .postponed }
        else if normalized.contains("delay") { self = .delayed }
        else if start.timeIntervalSinceNow < 900 && start.timeIntervalSinceNow > -900 { self = .pregame }
        else { self = .scheduled }
    }
}

private extension Dictionary where Key == String, Value == NBAStatsValue {
    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue { return value }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            if let value = self[key]?.intValue { return value }
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
