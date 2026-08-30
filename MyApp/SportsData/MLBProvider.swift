import Foundation

struct MLBProvider: ScoreProvider, ScheduleProvider, StandingsProvider, TeamProvider, RosterProvider, GameDetailsProvider, BoxScoreProvider, PlayByPlayProvider, TeamStatsProvider, PlayerStatsProvider {
    let metadata: SportsDataProviderMetadata

    private let client: MLBClient
    private let identityResolver: SportsIdentityResolver

    init(client: MLBClient = MLBClient(), identityResolver: SportsIdentityResolver = SportsIdentityResolver()) {
        self.client = client
        self.identityResolver = identityResolver
        self.metadata = SportsDataProviderMetadata(
            id: .mlb,
            name: "MLB StatsAPI",
            supportLevel: .official,
            supportedSports: [.baseball],
            supportedLeagues: [SportsProviderRouteConfiguration.leagueKey(forLegacyPath: "baseball/mlb"), "baseball/mlb"],
            capabilities: [.liveScores, .schedule, .gameStatus, .gameDetails, .playByPlay, .boxScore, .standings, .teams, .rosters, .playerStats, .teamStats],
            authenticationType: .none,
            isEnabled: AppConfiguration.isMLBProviderEnabled,
            requestTimeout: 8
        )
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try ensureMLB(league)
        let today = MLBDateFormatter.dayString(from: Date())
        let response = try await client.schedule(startDate: today, endDate: today)
        return (response.dates?.flatMap { $0.games ?? [] }.compactMap { mapGame($0, league: league) } ?? [])
            .filter { $0.status == .live || Calendar.current.isDate($0.scheduledStart, inSameDayAs: Date()) }
            .sorted { $0.scheduledStart < $1.scheduledStart }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        try ensureMLB(league)
        let response = try await client.schedule(
            startDate: MLBDateFormatter.dayString(from: range.start),
            endDate: MLBDateFormatter.dayString(from: range.end)
        )
        let games = (response.dates?.flatMap { $0.games ?? [] } ?? [])
            .compactMap { mapGame($0, league: league) }
            .filter { $0.scheduledStart >= range.start && $0.scheduledStart <= range.end }
            .sorted { $0.scheduledStart < $1.scheduledStart }
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:mlb:\(league.stadiaKey):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: games,
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: nil, confidence: 0.94)
        )
    }

    func gameDetails(for league: League, gameID: StadiaEntityID) async throws -> StadiaGame {
        try ensureMLB(league)
        let gamePk = try resolvedMLBGameID(from: gameID)
        let response = try await client.liveFeed(gamePk: gamePk)
        guard let game = mapLiveFeedGame(response, league: league, fallbackGameID: gamePk) else { throw SportsDataError.invalidResponse }
        return game
    }

    func teams(for league: League) async throws -> [StadiaTeam] {
        try ensureMLB(league)
        let response = try await client.teams()
        return (response.teams ?? []).compactMap { mapTeam($0, league: league) }
    }

    func standings(for league: League) async throws -> [StadiaStandingGroup] {
        try ensureMLB(league)
        let season = Calendar.current.component(.year, from: Date())
        let response = try await client.standings(season: season)
        return (response.records ?? []).map { record in
            let groupName = record.division?.name ?? record.league?.name ?? "MLB"
            return StadiaStandingGroup(
                id: StadiaEntityID(rawValue: "standings:mlb:\(SportsIdentityResolver.slug(groupName))"),
                name: groupName,
                standings: (record.teamRecords ?? []).enumerated().compactMap { index, row in
                    guard let team = row.team, let mappedTeam = mapTeam(team, league: league) else { return nil }
                    let displayRecord = [row.wins, row.losses].compactMap { $0.map(String.init) }.joined(separator: "-")
                    return StadiaStanding(
                        id: StadiaEntityID(rawValue: "standing:\(mappedTeam.id.rawValue)"),
                        teamID: mappedTeam.id,
                        teamDisplayName: mappedTeam.displayName,
                        teamAbbreviation: mappedTeam.abbreviation,
                        teamLogoURL: mappedTeam.logoURL,
                        groupName: groupName,
                        rank: row.divisionRank.flatMap(Int.init) ?? row.leagueRank.flatMap(Int.init) ?? index + 1,
                        wins: row.wins.map(String.init),
                        losses: row.losses.map(String.init),
                        ties: nil,
                        points: nil,
                        gamesPlayed: row.gamesPlayed.map(String.init),
                        displayRecord: displayRecord,
                        provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: team.id.map(String.init), confidence: 0.92)
                    )
                }
            )
        }
    }

    func roster(for league: League, teamID: StadiaEntityID) async throws -> StadiaRoster {
        try ensureMLB(league)
        guard let teamIDValue = SportsIdentityResolver.providerID(from: teamID, provider: .mlb) ?? numericSuffix(from: teamID.rawValue) else {
            throw SportsDataError.invalidResponse
        }
        let response = try await client.roster(teamID: teamIDValue)
        let players = (response.roster ?? []).compactMap { entry -> StadiaPlayer? in
            guard let person = entry.person, let playerID = person.id.map(String.init) else { return nil }
            let fullName = person.fullName ?? playerID
            return StadiaPlayer(
                id: identityResolver.canonicalPlayerID(league: league, provider: .mlb, providerPlayerID: playerID, fullName: fullName, teamAbbreviation: nil),
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                fullName: fullName,
                displayName: person.useName ?? person.fullName ?? playerID,
                teamID: teamID,
                teamAbbreviation: nil,
                position: entry.position?.abbreviation ?? entry.position?.name,
                jerseyNumber: entry.jerseyNumber,
                birthDate: nil,
                headshotURL: MLBAssetURL.headshot(personID: playerID),
                aliases: [ProviderEntityAlias(provider: .mlb, id: playerID)],
                provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: playerID, confidence: 0.9)
            )
        }
        return StadiaRoster(
            id: StadiaEntityID(rawValue: "roster:mlb:\(teamID.rawValue)"),
            teamID: teamID,
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            players: players,
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: teamIDValue, confidence: 0.9)
        )
    }

    func boxScore(for league: League, gameID: StadiaEntityID) async throws -> StadiaBoxScore {
        try ensureMLB(league)
        let gamePk = try resolvedMLBGameID(from: gameID)
        let response = try await client.liveFeed(gamePk: gamePk)
        let boxscore = response.liveData?.boxscore
        let awayTeam = boxscore?.teams?.away?.team ?? response.gameData?.teams?.away
        let homeTeam = boxscore?.teams?.home?.team ?? response.gameData?.teams?.home
        let teamStats = [
            mapTeamBoxScore(boxscore?.teams?.away, team: awayTeam, side: "away", league: league, gameID: gameID),
            mapTeamBoxScore(boxscore?.teams?.home, team: homeTeam, side: "home", league: league, gameID: gameID)
        ].compactMap { $0 }
        let playerStats = [
            mapPlayerBoxScore(boxscore?.teams?.away, team: awayTeam, league: league, gameID: gameID),
            mapPlayerBoxScore(boxscore?.teams?.home, team: homeTeam, league: league, gameID: gameID)
        ].flatMap { $0 }
        return StadiaBoxScore(
            id: StadiaEntityID(rawValue: "boxScore:mlb:\(gamePk)"),
            gameID: gameID,
            teamStats: teamStats,
            playerStats: playerStats,
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: gamePk, confidence: 0.9)
        )
    }

    func playByPlay(for league: League, gameID: StadiaEntityID) async throws -> StadiaPlayByPlay {
        try ensureMLB(league)
        let gamePk = try resolvedMLBGameID(from: gameID)
        let response = try await client.liveFeed(gamePk: gamePk)
        let plays = (response.liveData?.plays?.allPlays ?? []).compactMap { mapPlay($0, league: league, gameID: gameID) }
        return StadiaPlayByPlay(
            id: StadiaEntityID(rawValue: "pbp:mlb:\(gamePk)"),
            gameID: gameID,
            plays: plays,
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: gamePk, confidence: 0.9)
        )
    }

    func teamStats(for league: League, teamIDs: Set<StadiaEntityID>, range: SportsDateRange?) async throws -> [StadiaTeamStat] {
        try await standings(for: league).flatMap(\.standings).compactMap { standing in
            guard teamIDs.isEmpty || teamIDs.contains(standing.teamID) else { return nil }
            let stats = [
                stat("games_played", "GP", standing.gamesPlayed),
                stat("wins", "W", standing.wins),
                stat("losses", "L", standing.losses),
                stat("record", "Record", standing.displayRecord)
            ].compactMap { $0 }
            return StadiaTeamStat(
                id: StadiaEntityID(rawValue: "teamStat:mlb:\(standing.teamID.rawValue):standings"),
                teamID: standing.teamID,
                seasonID: nil,
                stats: stats,
                provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: SportsIdentityResolver.providerID(from: standing.teamID, provider: .mlb), confidence: 0.86)
            )
        }
    }

    func playerStats(for league: League, playerIDs: Set<StadiaEntityID>, range: SportsDateRange?) async throws -> [StadiaPlayerStat] {
        try ensureMLB(league)
        guard !playerIDs.isEmpty else { return [] }
        var stats: [StadiaPlayerStat] = []
        for playerID in playerIDs {
            guard let providerID = SportsIdentityResolver.providerID(from: playerID, provider: .mlb) ?? numericSuffix(from: playerID.rawValue) else { continue }
            let response = try await client.playerStats(personID: providerID, season: Calendar.current.component(.year, from: Date()))
            if let stat = mapSeasonPlayerStat(response, playerID: playerID, providerID: providerID) {
                stats.append(stat)
            }
        }
        return stats
    }

    private func ensureMLB(_ league: League) throws {
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.mlb) }
        guard league.path == "baseball/mlb" else { throw SportsDataError.unsupportedCapability(.liveScores) }
    }

    private func resolvedMLBGameID(from gameID: StadiaEntityID) throws -> String {
        if let providerID = SportsIdentityResolver.providerID(from: gameID, provider: .mlb) { return providerID }
        if let raw = numericSuffix(from: gameID.rawValue) { return raw }
        throw SportsDataError.invalidResponse
    }

    private func mapGame(_ dto: MLBScheduleGameDTO, league: League) -> StadiaGame? {
        guard let gamePk = dto.gamePk.map(String.init), let homeDTO = dto.teams?.home, let awayDTO = dto.teams?.away, let homeTeamDTO = homeDTO.team, let awayTeamDTO = awayDTO.team else { return nil }
        let start = MLBDateFormatter.date(from: dto.gameDate) ?? Date()
        let status = StadiaGameStatus(mlbAbstractState: dto.status?.abstractGameState, detailedState: dto.status?.detailedState, statusCode: dto.status?.statusCode)
        guard let homeTeam = mapTeam(homeTeamDTO, league: league), let awayTeam = mapTeam(awayTeamDTO, league: league) else { return nil }
        let linescore = dto.linescore
        return StadiaGame(
            id: identityResolver.canonicalGameID(league: league, provider: .mlb, providerGameID: gamePk, home: homeTeam, away: awayTeam, scheduledStart: start),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            scheduledStart: start,
            name: dto.description ?? "\(awayTeam.displayName) at \(homeTeam.displayName)",
            shortName: "\(awayTeam.abbreviation) @ \(homeTeam.abbreviation)",
            status: status,
            statusDetail: MLBStatusFormatter.detail(status: status, detailedState: dto.status?.detailedState, linescore: linescore, start: start),
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            score: StadiaScore(home: homeDTO.score.map(String.init), away: awayDTO.score.map(String.init)),
            clock: MLBStatusFormatter.clock(status: status, detailedState: dto.status?.detailedState, linescore: linescore),
            period: linescore?.currentInning.map { StadiaPeriod(number: $0, displayName: MLBStatusFormatter.inningDisplay(number: $0, half: linescore?.inningHalf)) },
            venue: mapVenue(dto.venue),
            broadcasts: (dto.broadcasts ?? []).compactMap { broadcast in
                guard let name = broadcast.name, !name.isEmpty else { return nil }
                return StadiaBroadcast(network: name, type: broadcast.type, countryCode: nil)
            },
            aliases: [ProviderEntityAlias(provider: .mlb, id: gamePk)],
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: gamePk, confidence: 0.94)
        )
    }

    private func mapLiveFeedGame(_ dto: MLBLiveFeedDTO, league: League, fallbackGameID: String) -> StadiaGame? {
        let gameData = dto.gameData
        let linescore = dto.liveData?.linescore
        let schedule = MLBScheduleGameDTO(
            gamePk: Int(fallbackGameID),
            gameDate: gameData?.datetime?.dateTime,
            officialDate: gameData?.datetime?.officialDate,
            description: gameData?.game?.description,
            status: gameData?.status,
            teams: MLBGameTeamsDTO(
                away: MLBGameTeamSideDTO(team: gameData?.teams?.away, score: linescore?.teams?.away?.runs, isWinner: nil, leagueRecord: nil),
                home: MLBGameTeamSideDTO(team: gameData?.teams?.home, score: linescore?.teams?.home?.runs, isWinner: nil, leagueRecord: nil)
            ),
            venue: gameData?.venue,
            broadcasts: nil,
            linescore: linescore
        )
        return mapGame(schedule, league: league)
    }

    private func mapTeam(_ dto: MLBTeamDTO, league: League) -> StadiaTeam? {
        guard let id = dto.id.map(String.init) else { return nil }
        let abbreviation = dto.abbreviation ?? dto.fileCode?.uppercased() ?? dto.teamCode?.uppercased() ?? dto.name ?? id
        let displayName = dto.name ?? [dto.locationName, dto.teamName].compactMap { $0 }.joined(separator: " ")
        let shortName = dto.teamName ?? dto.clubName ?? dto.name ?? abbreviation
        return StadiaTeam(
            id: identityResolver.canonicalTeamID(league: league, provider: .mlb, providerTeamID: id, abbreviation: abbreviation, displayName: displayName.isEmpty ? abbreviation : displayName),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: displayName.isEmpty ? abbreviation : displayName,
            shortName: shortName,
            abbreviation: abbreviation,
            logoURL: TeamLogoAssetResolver.mlbAssetURL(abbreviation: abbreviation, displayName: displayName.isEmpty ? abbreviation : displayName, providerTeamID: id) ?? MLBAssetURL.teamLogo(teamID: id),
            aliases: [ProviderEntityAlias(provider: .mlb, id: id)],
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: id, confidence: 0.93)
        )
    }

    private func mapVenue(_ dto: MLBVenueDTO?) -> StadiaVenue? {
        guard let name = dto?.name, !name.isEmpty else { return nil }
        return StadiaVenue(
            id: dto?.id.map { StadiaEntityID(rawValue: "venue:mlb:\($0)") } ?? StadiaEntityID(rawValue: "venue:mlb:\(SportsIdentityResolver.slug(name))"),
            name: name,
            city: dto?.location?.city,
            state: dto?.location?.state,
            country: dto?.location?.country,
            aliases: dto?.id.map { [ProviderEntityAlias(provider: .mlb, id: String($0))] } ?? []
        )
    }

    private func mapTeamBoxScore(_ dto: MLBBoxScoreTeamDTO?, team: MLBTeamDTO?, side: String, league: League, gameID: StadiaEntityID) -> StadiaTeamStat? {
        guard let mappedTeam = team.flatMap({ mapTeam($0, league: league) }) else { return nil }
        let batting = dto?.teamStats?.batting
        let pitching = dto?.teamStats?.pitching
        let fielding = dto?.teamStats?.fielding
        let stats = [
            stat("runs", "R", batting?.runs),
            stat("hits", "H", batting?.hits),
            stat("errors", "E", fielding?.errors),
            stat("home_runs", "HR", batting?.homeRuns),
            stat("rbi", "RBI", batting?.rbi),
            stat("left_on_base", "LOB", batting?.leftOnBase),
            stat("strikeouts", "SO", batting?.strikeOuts),
            stat("walks", "BB", batting?.baseOnBalls),
            stat("avg", "AVG", batting?.avg),
            stat("era", "ERA", pitching?.era),
            stat("pitch_strikes", "P-S", pitching?.pitchesStrikes)
        ].compactMap { $0 }
        return StadiaTeamStat(
            id: StadiaEntityID(rawValue: "teamStat:mlb:\(gameID.rawValue):\(side)"),
            teamID: mappedTeam.id,
            seasonID: nil,
            stats: stats,
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: team?.id.map(String.init), confidence: 0.9)
        )
    }

    private func mapPlayerBoxScore(_ dto: MLBBoxScoreTeamDTO?, team: MLBTeamDTO?, league: League, gameID: StadiaEntityID) -> [StadiaPlayerStat] {
        guard let players = dto?.players else { return [] }
        let mappedTeam = team.flatMap { mapTeam($0, league: league) }
        return players.values.compactMap { player in
            guard let person = player.person, let playerID = person.id.map(String.init) else { return nil }
            let displayName = person.fullName ?? playerID
            let stats = player.stats?.flattenedStats() ?? []
            guard !stats.isEmpty else { return nil }
            return StadiaPlayerStat(
                id: StadiaEntityID(rawValue: "playerStat:mlb:\(gameID.rawValue):\(playerID)"),
                playerID: identityResolver.canonicalPlayerID(league: league, provider: .mlb, providerPlayerID: playerID, fullName: displayName, teamAbbreviation: mappedTeam?.abbreviation),
                playerDisplayName: displayName,
                teamAbbreviation: mappedTeam?.abbreviation,
                headshotURL: MLBAssetURL.headshot(personID: playerID),
                teamID: mappedTeam?.id,
                seasonID: nil,
                stats: stats,
                provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: playerID, confidence: 0.88)
            )
        }
    }

    private func mapSeasonPlayerStat(_ response: MLBPersonStatsResponseDTO, playerID: StadiaEntityID, providerID: String) -> StadiaPlayerStat? {
        guard let person = response.people?.first else { return nil }
        let stats = person.stats?.flatMap { group in group.splits?.flatMap { $0.stat?.flattenedStats(prefix: nil) ?? [] } ?? [] } ?? []
        guard !stats.isEmpty else { return nil }
        return StadiaPlayerStat(
            id: StadiaEntityID(rawValue: "playerStat:mlb:season:\(providerID)"),
            playerID: playerID,
            playerDisplayName: person.fullName,
            teamAbbreviation: nil,
            headshotURL: MLBAssetURL.headshot(personID: providerID),
            teamID: nil,
            seasonID: nil,
            stats: stats,
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: providerID, confidence: 0.84)
        )
    }

    private func mapPlay(_ dto: MLBPlayDTO, league: League, gameID: StadiaEntityID) -> StadiaPlay? {
        let eventID = dto.about?.atBatIndex.map(String.init) ?? dto.result?.event ?? UUID().uuidString
        let inning = dto.about?.inning
        let half = dto.about?.halfInning
        let text = [dto.result?.event, dto.result?.description].compactMap { $0 }.joined(separator: ": ")
        return StadiaPlay(
            id: StadiaEntityID(rawValue: "play:mlb:\(gameID.rawValue):\(eventID)"),
            sequence: dto.about?.atBatIndex,
            period: inning.map { StadiaPeriod(number: $0, displayName: MLBStatusFormatter.inningDisplay(number: $0, half: half)) },
            clock: nil,
            text: text.isEmpty ? "Play" : text,
            teamID: nil,
            awayScore: dto.result?.awayScore.map(String.init),
            homeScore: dto.result?.homeScore.map(String.init),
            isScoringPlay: dto.result?.rbi.map { $0 > 0 } ?? false,
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: eventID, confidence: 0.86)
        )
    }

    private func stat(_ key: String, _ displayName: String, _ value: CustomStringConvertible?) -> StadiaStatValue? {
        guard let value else { return nil }
        let string = value.description
        guard !string.isEmpty else { return nil }
        return StadiaStatValue(key: key, displayName: displayName, value: string)
    }
}

struct MLBClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "https://statsapi.mlb.com/api")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func schedule(startDate: String, endDate: String) async throws -> MLBScheduleResponseDTO {
        try await get("v1/schedule", queryItems: [
            URLQueryItem(name: "sportId", value: "1"),
            URLQueryItem(name: "startDate", value: startDate),
            URLQueryItem(name: "endDate", value: endDate),
            URLQueryItem(name: "hydrate", value: "team,venue,broadcasts,linescore")
        ])
    }

    func liveFeed(gamePk: String) async throws -> MLBLiveFeedDTO {
        try await get("v1.1/game/\(gamePk)/feed/live", queryItems: [])
    }

    func teams() async throws -> MLBTeamsResponseDTO {
        try await get("v1/teams", queryItems: [
            URLQueryItem(name: "sportId", value: "1"),
            URLQueryItem(name: "activeStatus", value: "Y"),
            URLQueryItem(name: "hydrate", value: "venue")
        ])
    }

    func standings(season: Int) async throws -> MLBStandingsResponseDTO {
        try await get("v1/standings", queryItems: [
            URLQueryItem(name: "leagueId", value: "103,104"),
            URLQueryItem(name: "season", value: String(season)),
            URLQueryItem(name: "standingsTypes", value: "regularSeason"),
            URLQueryItem(name: "hydrate", value: "team")
        ])
    }

    func roster(teamID: String) async throws -> MLBRosterResponseDTO {
        try await get("v1/teams/\(teamID)/roster", queryItems: [
            URLQueryItem(name: "rosterType", value: "active")
        ])
    }

    func playerStats(personID: String, season: Int) async throws -> MLBPersonStatsResponseDTO {
        try await get("v1/people/\(personID)", queryItems: [
            URLQueryItem(name: "hydrate", value: "stats(group=[hitting,pitching],type=[season],season=\(season))")
        ])
    }

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw SportsDataError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("StadiaTV/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SportsDataError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                return try MLBJSONDecoder.decoder.decode(T.self, from: data)
            case 401, 403:
                throw SportsDataError.authenticationFailed
            case 429:
                throw SportsDataError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
            case 500..<600:
                throw SportsDataError.unavailable
            default:
                throw SportsDataError.invalidResponse
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

struct MLBScheduleResponseDTO: Decodable, Sendable {
    let dates: [MLBScheduleDateDTO]?
}

struct MLBScheduleDateDTO: Decodable, Sendable {
    let date: String?
    let games: [MLBScheduleGameDTO]?
}

struct MLBScheduleGameDTO: Decodable, Sendable {
    let gamePk: Int?
    let gameDate: String?
    let officialDate: String?
    let description: String?
    let status: MLBStatusDTO?
    let teams: MLBGameTeamsDTO?
    let venue: MLBVenueDTO?
    let broadcasts: [MLBBroadcastDTO]?
    let linescore: MLBLinescoreDTO?
}

struct MLBStatusDTO: Decodable, Sendable {
    let abstractGameState: String?
    let detailedState: String?
    let statusCode: String?
}

struct MLBGameTeamsDTO: Decodable, Sendable {
    let away: MLBGameTeamSideDTO?
    let home: MLBGameTeamSideDTO?
}

struct MLBGameTeamSideDTO: Decodable, Sendable {
    let team: MLBTeamDTO?
    let score: Int?
    let isWinner: Bool?
    let leagueRecord: MLBLeagueRecordDTO?
}

struct MLBLeagueRecordDTO: Decodable, Sendable {
    let wins: Int?
    let losses: Int?
    let pct: String?
}

struct MLBTeamDTO: Decodable, Sendable {
    let id: Int?
    let name: String?
    let teamName: String?
    let locationName: String?
    let clubName: String?
    let abbreviation: String?
    let teamCode: String?
    let fileCode: String?
    let venue: MLBVenueDTO?
}

struct MLBVenueDTO: Decodable, Sendable {
    let id: Int?
    let name: String?
    let location: MLBVenueLocationDTO?
}

struct MLBVenueLocationDTO: Decodable, Sendable {
    let city: String?
    let state: String?
    let country: String?
}

struct MLBBroadcastDTO: Decodable, Sendable {
    let id: Int?
    let name: String?
    let type: String?
}

struct MLBLinescoreDTO: Decodable, Sendable {
    let currentInning: Int?
    let currentInningOrdinal: String?
    let inningState: String?
    let inningHalf: String?
    let balls: Int?
    let strikes: Int?
    let outs: Int?
    let teams: MLBLineScoreTeamsDTO?
}

struct MLBLineScoreTeamsDTO: Decodable, Sendable {
    let away: MLBLineScoreTeamDTO?
    let home: MLBLineScoreTeamDTO?
}

struct MLBLineScoreTeamDTO: Decodable, Sendable {
    let runs: Int?
    let hits: Int?
    let errors: Int?
    let leftOnBase: Int?
}

struct MLBTeamsResponseDTO: Decodable, Sendable {
    let teams: [MLBTeamDTO]?
}

struct MLBStandingsResponseDTO: Decodable, Sendable {
    let records: [MLBStandingRecordDTO]?
}

struct MLBStandingRecordDTO: Decodable, Sendable {
    let standingsType: String?
    let league: MLBNamedIDDTO?
    let division: MLBNamedIDDTO?
    let teamRecords: [MLBTeamRecordDTO]?
}

struct MLBTeamRecordDTO: Decodable, Sendable {
    let team: MLBTeamDTO?
    let gamesPlayed: Int?
    let wins: Int?
    let losses: Int?
    let winningPercentage: String?
    let divisionRank: String?
    let leagueRank: String?
    let gamesBack: String?
    let wildCardGamesBack: String?
}

struct MLBNamedIDDTO: Decodable, Sendable {
    let id: Int?
    let name: String?
}

struct MLBRosterResponseDTO: Decodable, Sendable {
    let roster: [MLBRosterEntryDTO]?
}

struct MLBRosterEntryDTO: Decodable, Sendable {
    let person: MLBPersonDTO?
    let jerseyNumber: String?
    let position: MLBPositionDTO?
    let status: MLBCodeDescriptionDTO?
}

struct MLBPersonDTO: Decodable, Sendable {
    let id: Int?
    let fullName: String?
    let useName: String?
    let boxscoreName: String?
}

struct MLBPositionDTO: Decodable, Sendable {
    let code: String?
    let name: String?
    let type: String?
    let abbreviation: String?
}

struct MLBCodeDescriptionDTO: Decodable, Sendable {
    let code: String?
    let description: String?
}

struct MLBLiveFeedDTO: Decodable, Sendable {
    let gamePk: Int?
    let gameData: MLBGameDataDTO?
    let liveData: MLBLiveDataDTO?
}

struct MLBGameDataDTO: Decodable, Sendable {
    let game: MLBGameInfoDTO?
    let datetime: MLBGameDateTimeDTO?
    let status: MLBStatusDTO?
    let teams: MLBGameDataTeamsDTO?
    let venue: MLBVenueDTO?
}

struct MLBGameInfoDTO: Decodable, Sendable {
    let pk: Int?
    let type: String?
    let doubleHeader: String?
    let id: String?
    let gamedayType: String?
    let tiebreaker: String?
    let gameNumber: Int?
    let calendarEventID: String?
    let season: String?
    let seasonDisplay: String?
    let description: String?
}

struct MLBGameDateTimeDTO: Decodable, Sendable {
    let dateTime: String?
    let originalDate: String?
    let officialDate: String?
}

struct MLBGameDataTeamsDTO: Decodable, Sendable {
    let away: MLBTeamDTO?
    let home: MLBTeamDTO?
}

struct MLBLiveDataDTO: Decodable, Sendable {
    let linescore: MLBLinescoreDTO?
    let boxscore: MLBBoxScoreDTO?
    let plays: MLBPlaysDTO?
}

struct MLBBoxScoreDTO: Decodable, Sendable {
    let teams: MLBBoxScoreTeamsDTO?
}

struct MLBBoxScoreTeamsDTO: Decodable, Sendable {
    let away: MLBBoxScoreTeamDTO?
    let home: MLBBoxScoreTeamDTO?
}

struct MLBBoxScoreTeamDTO: Decodable, Sendable {
    let team: MLBTeamDTO?
    let teamStats: MLBBoxScoreTeamStatsDTO?
    let players: [String: MLBBoxScorePlayerDTO]?
}

struct MLBBoxScoreTeamStatsDTO: Decodable, Sendable {
    let batting: MLBStatDTO?
    let pitching: MLBStatDTO?
    let fielding: MLBStatDTO?
}

struct MLBBoxScorePlayerDTO: Decodable, Sendable {
    let person: MLBPersonDTO?
    let jerseyNumber: String?
    let position: MLBPositionDTO?
    let stats: MLBPlayerBoxStatsDTO?
}

struct MLBPlayerBoxStatsDTO: Decodable, Sendable {
    let batting: MLBStatDTO?
    let pitching: MLBStatDTO?
    let fielding: MLBStatDTO?

    func flattenedStats() -> [StadiaStatValue] {
        (batting?.flattenedStats(prefix: nil) ?? [])
            + (pitching?.flattenedStats(prefix: nil) ?? [])
            + (fielding?.flattenedStats(prefix: nil) ?? [])
    }
}

struct MLBStatDTO: Decodable, Sendable {
    let runs: Int?
    let hits: Int?
    let doubles: Int?
    let triples: Int?
    let homeRuns: Int?
    let rbi: Int?
    let baseOnBalls: Int?
    let strikeOuts: Int?
    let stolenBases: Int?
    let leftOnBase: Int?
    let atBats: Int?
    let avg: String?
    let obp: String?
    let slg: String?
    let ops: String?
    let inningsPitched: String?
    let earnedRuns: Int?
    let battersFaced: Int?
    let pitchesThrown: Int?
    let strikes: Int?
    let pitchesStrikes: String?
    let era: String?
    let errors: Int?
    let assists: Int?
    let putOuts: Int?

    func flattenedStats(prefix: String?) -> [StadiaStatValue] {
        let statPrefix = prefix.map { "\($0)_" } ?? ""
        return [
            value("\(statPrefix)runs", "R", runs),
            value("\(statPrefix)hits", "H", hits),
            value("\(statPrefix)doubles", "2B", doubles),
            value("\(statPrefix)triples", "3B", triples),
            value("\(statPrefix)home_runs", "HR", homeRuns),
            value("\(statPrefix)rbi", "RBI", rbi),
            value("\(statPrefix)walks", "BB", baseOnBalls),
            value("\(statPrefix)strikeouts", "SO", strikeOuts),
            value("\(statPrefix)stolen_bases", "SB", stolenBases),
            value("\(statPrefix)left_on_base", "LOB", leftOnBase),
            value("\(statPrefix)at_bats", "AB", atBats),
            value("\(statPrefix)avg", "AVG", avg),
            value("\(statPrefix)obp", "OBP", obp),
            value("\(statPrefix)slg", "SLG", slg),
            value("\(statPrefix)ops", "OPS", ops),
            value("\(statPrefix)innings_pitched", "IP", inningsPitched),
            value("\(statPrefix)earned_runs", "ER", earnedRuns),
            value("\(statPrefix)batters_faced", "BF", battersFaced),
            value("\(statPrefix)pitches", "P", pitchesThrown),
            value("\(statPrefix)strikes", "S", strikes),
            value("\(statPrefix)pitch_strikes", "P-S", pitchesStrikes),
            value("\(statPrefix)era", "ERA", era),
            value("\(statPrefix)errors", "E", errors),
            value("\(statPrefix)assists", "A", assists),
            value("\(statPrefix)putouts", "PO", putOuts)
        ].compactMap { $0 }
    }

    private func value(_ key: String, _ displayName: String, _ value: CustomStringConvertible?) -> StadiaStatValue? {
        guard let value else { return nil }
        let string = value.description
        guard !string.isEmpty else { return nil }
        return StadiaStatValue(key: key, displayName: displayName, value: string)
    }
}

struct MLBPlaysDTO: Decodable, Sendable {
    let allPlays: [MLBPlayDTO]?
}

struct MLBPlayDTO: Decodable, Sendable {
    let result: MLBPlayResultDTO?
    let about: MLBPlayAboutDTO?
}

struct MLBPlayResultDTO: Decodable, Sendable {
    let type: String?
    let event: String?
    let eventType: String?
    let description: String?
    let rbi: Int?
    let awayScore: Int?
    let homeScore: Int?
}

struct MLBPlayAboutDTO: Decodable, Sendable {
    let atBatIndex: Int?
    let inning: Int?
    let halfInning: String?
    let isTopInning: Bool?
    let startTime: String?
    let endTime: String?
}

struct MLBPersonStatsResponseDTO: Decodable, Sendable {
    let people: [MLBPersonWithStatsDTO]?
}

struct MLBPersonWithStatsDTO: Decodable, Sendable {
    let id: Int?
    let fullName: String?
    let stats: [MLBPersonStatGroupDTO]?
}

struct MLBPersonStatGroupDTO: Decodable, Sendable {
    let group: MLBDisplayNameDTO?
    let type: MLBDisplayNameDTO?
    let splits: [MLBPersonStatSplitDTO]?
}

struct MLBPersonStatSplitDTO: Decodable, Sendable {
    let season: String?
    let stat: MLBStatDTO?
}

struct MLBDisplayNameDTO: Decodable, Sendable {
    let displayName: String?
}

enum MLBJSONDecoder {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum MLBDateFormatter {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return isoFormatter.date(from: string) ?? fallbackISOFormatter.date(from: string) ?? dayFormatter.date(from: string)
    }
}

enum MLBStatusFormatter {
    static func detail(status: StadiaGameStatus, detailedState: String?, linescore: MLBLinescoreDTO?, start: Date) -> String {
        if status == .live, let inning = linescore?.currentInning {
            let half = linescore?.inningHalf ?? linescore?.inningState
            let inningText = inningDisplay(number: inning, half: half)
            let outs = linescore?.outs.map { "\($0) out\($0 == 1 ? "" : "s")" }
            return [inningText, outs].compactMap { $0 }.joined(separator: " · ")
        }
        if status == .final { return detailedState ?? "Final" }
        if let detailedState, ["Postponed", "Delayed", "Suspended"].contains(detailedState) { return detailedState }
        return start.formatted(date: .omitted, time: .shortened)
    }

    static func clock(status: StadiaGameStatus, detailedState: String?, linescore: MLBLinescoreDTO?) -> StadiaGameClock? {
        guard status == .live else { return detailedState.map { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: nil) } }
        let count = [linescore?.balls.map { "B\($0)" }, linescore?.strikes.map { "S\($0)" }, linescore?.outs.map { "O\($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
        return count.isEmpty ? nil : StadiaGameClock(displayValue: count, remainingSeconds: nil, isRunning: true)
    }

    static func inningDisplay(number: Int, half: String?) -> String {
        let prefix: String
        switch half?.lowercased() {
        case "top": prefix = "Top"
        case "bottom": prefix = "Bot"
        case "middle": prefix = "Mid"
        case "end": prefix = "End"
        default: prefix = "Inning"
        }
        return "\(prefix) \(ordinal(number))"
    }

    private static func ordinal(_ number: Int) -> String {
        let suffix: String
        switch number % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch number % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(number)\(suffix)"
    }
}

extension StadiaGameStatus {
    init(mlbAbstractState: String?, detailedState: String?, statusCode: String?) {
        let abstract = mlbAbstractState?.lowercased()
        let detailed = detailedState?.lowercased() ?? ""

        if detailed.contains("postponed") {
            self = .postponed
        } else if detailed.contains("delayed") {
            self = .delayed
        } else if detailed.contains("suspended") {
            self = .suspended
        } else if abstract == "live" || ["I", "M", "N"].contains(statusCode) || detailed.contains("in progress") || detailed.contains("middle") || detailed.contains("top") || detailed.contains("bottom") {
            self = .live
        } else if abstract == "final" || detailed.contains("final") || detailed.contains("completed") || detailed.contains("game over") {
            self = .final
        } else if abstract == "preview" || abstract == "pre-game" || ["P", "S"].contains(statusCode) {
            self = .scheduled
        } else {
            self = .unknown
        }
    }
}

enum MLBAssetURL {
    static func teamLogo(teamID: String) -> URL? {
        URL(string: "https://www.mlbstatic.com/team-logos/\(teamID).svg")
    }

    static func headshot(personID: String) -> URL? {
        URL(string: "https://img.mlbstatic.com/mlb-photos/image/upload/w_120,q_auto:best/v1/people/\(personID)/headshot/67/current")
    }
}

private func numericSuffix(from rawValue: String) -> String? {
    let parts = rawValue.split(separator: ":").map(String.init)
    if let last = parts.last, !last.isEmpty, last.allSatisfy(\.isNumber) { return last }
    if rawValue.allSatisfy(\.isNumber) { return rawValue }
    return nil
}
