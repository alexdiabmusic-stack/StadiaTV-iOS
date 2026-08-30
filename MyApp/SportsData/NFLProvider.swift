import Foundation

// MARK: - NFL Shield adapter

struct NFLProvider: ScoreProvider, ScheduleProvider, GameDetailsProvider, PlayByPlayProvider, BoxScoreProvider, TeamProvider, StandingsProvider, RosterProvider, InjuryProvider {
    let metadata: SportsDataProviderMetadata
    private let client: NFLClient
    private let identityResolver: SportsIdentityResolver

    init(client: NFLClient = NFLClient(), identityResolver: SportsIdentityResolver = SportsIdentityResolver()) {
        self.client = client
        self.identityResolver = identityResolver
        self.metadata = SportsDataProviderMetadata(
            id: .nfl,
            name: "NFL Shield",
            supportLevel: .firstPartyWeb,
            supportedSports: [.football],
            supportedLeagues: ["football/nfl", SportsProviderRouteConfiguration.leagueKey(forLegacyPath: "football/nfl")],
            capabilities: [.liveScores, .schedule, .gameStatus, .gameDetails, .playByPlay, .boxScore, .teams, .standings, .rosters, .injuries],
            authenticationType: .anonymousBearerToken,
            isEnabled: AppConfiguration.isNFLProviderEnabled,
            requestTimeout: 7
        )
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try ensureNFL(league)
        let week = try await client.week(for: NFLDateFormatter.dayString(from: Date()))
        let response = try await client.gameSchedule(season: week.seasonValue, seasonType: week.seasonTypeValue, week: week.weekValue)
        return (response.games ?? []).compactMap { mapGame($0, league: league) }
            .filter { Calendar.current.isDate($0.scheduledStart, inSameDayAs: Date()) || $0.status == .live }
            .sorted { $0.scheduledStart < $1.scheduledStart }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        try ensureNFL(league)
        let refs = try await client.weekReferences(from: range.start, to: range.end)
        var games: [StadiaGame] = []
        for ref in refs {
            let response = try await client.gameSchedule(season: ref.season, seasonType: ref.seasonType, week: ref.week)
            games.append(contentsOf: (response.games ?? []).compactMap { mapGame($0, league: league) })
        }
        var seen = Set<StadiaEntityID>()
        games = games.filter { seen.insert($0.id).inserted }
            .filter { $0.scheduledStart >= range.start && $0.scheduledStart <= range.end }
            .sorted { $0.scheduledStart < $1.scheduledStart }
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:nfl:\(league.stadiaKey):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: games,
            provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: nil, confidence: 0.86)
        )
    }

    func gameDetails(for league: League, gameID: StadiaEntityID) async throws -> StadiaGame {
        try ensureNFL(league)
        let providerID = try resolvedNFLGameID(from: gameID)
        let detail = try await client.gameDetails(gameID: providerID)
        guard let game = mapGame(detail.toGame(), league: league) else { throw SportsDataError.invalidResponse }
        return game
    }

    func playByPlay(for league: League, gameID: StadiaEntityID) async throws -> StadiaPlayByPlay {
        try ensureNFL(league)
        let providerID = try resolvedNFLGameID(from: gameID)
        let detail = try await client.gameDetails(gameID: providerID)
        let plays = (detail.plays ?? []).enumerated().compactMap { index, play -> StadiaPlay? in
            guard let text = play.playDescription ?? play.description ?? play.shortDescription, !text.isEmpty else { return nil }
            let period = play.quarter ?? play.period
            return StadiaPlay(
                id: StadiaEntityID(rawValue: "play:nfl:\(providerID):\(play.playID ?? String(index))"),
                sequence: play.sequence ?? index,
                period: period.map { StadiaPeriod(number: $0, displayName: NFLPeriodFormatter.displayName(for: $0)) },
                clock: play.clock.map { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: nil) },
                text: text,
                teamID: play.possessionTeam.flatMap { mapTeam($0, league: league)?.id },
                awayScore: (play.awayScore ?? play.visitorScore).map(String.init),
                homeScore: play.homeScore.map(String.init),
                isScoringPlay: play.isScoringPlay ?? play.scoreValue.map { $0 > 0 } ?? false,
                provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: play.playID, confidence: 0.74)
            )
        }
        guard !plays.isEmpty else { throw SportsDataError.unsupportedCapability(.playByPlay) }
        return StadiaPlayByPlay(id: StadiaEntityID(rawValue: "pbp:nfl:\(providerID)"), gameID: gameID, plays: plays, provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: providerID, confidence: 0.78))
    }

    func boxScore(for league: League, gameID: StadiaEntityID) async throws -> StadiaBoxScore {
        try ensureNFL(league)
        let providerID = try resolvedNFLGameID(from: gameID)
        let detail = try await client.gameDetails(gameID: providerID)
        let stats = [mapTeamStats(detail.homeTeam, side: "home", league: league, gameID: gameID), mapTeamStats(detail.awayTeam ?? detail.visitorTeam, side: "away", league: league, gameID: gameID)].compactMap { $0 }
        guard !stats.isEmpty else { throw SportsDataError.unsupportedCapability(.boxScore) }
        return StadiaBoxScore(id: StadiaEntityID(rawValue: "boxScore:nfl:\(providerID)"), gameID: gameID, teamStats: stats, playerStats: [], provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: providerID, confidence: 0.78))
    }

    func teams(for league: League) async throws -> [StadiaTeam] {
        try ensureNFL(league)
        let response = try await client.teams(season: NFLSeason.currentYear)
        let teams = (response.teams ?? []).compactMap { mapTeam($0, league: league) }
        guard !teams.isEmpty else { throw SportsDataError.invalidResponse }
        return teams.sorted { $0.displayName < $1.displayName }
    }

    func standings(for league: League) async throws -> [StadiaStandingGroup] {
        try ensureNFL(league)
        let week = try await client.week(for: NFLDateFormatter.dayString(from: Date()))
        let response = try await client.standings(season: week.seasonValue, seasonType: week.seasonTypeValue, week: week.weekValue)
        let rows = (response.weeks ?? []).flatMap { $0.standings ?? [] }.enumerated().compactMap { index, row -> StadiaStanding? in
            guard let team = mapTeam(row.team, league: league) else { return nil }
            let record = [row.wins, row.losses, row.ties].compactMap { $0.map(String.init) }.joined(separator: "-")
            return StadiaStanding(id: StadiaEntityID(rawValue: "standing:nfl:\(team.id.rawValue)"), teamID: team.id, teamDisplayName: team.displayName, teamAbbreviation: team.abbreviation, teamLogoURL: team.logoURL, groupName: row.divisionName ?? row.conferenceName ?? "NFL", rank: row.rank ?? row.divisionRank ?? row.conferenceRank ?? index + 1, wins: row.wins.map(String.init), losses: row.losses.map(String.init), ties: row.ties.map(String.init), points: nil, gamesPlayed: row.gamesPlayed.map(String.init), displayRecord: record.isEmpty ? (row.record ?? "-") : record, provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: row.team?.providerID, confidence: 0.84))
        }
        guard !rows.isEmpty else { throw SportsDataError.invalidResponse }
        let grouped = Dictionary(grouping: rows) { $0.groupName ?? "NFL" }
        return grouped.keys.sorted().map { StadiaStandingGroup(id: StadiaEntityID(rawValue: "standings:nfl:\(SportsIdentityResolver.slug($0))"), name: $0, standings: (grouped[$0] ?? []).sorted { ($0.rank ?? Int.max) < ($1.rank ?? Int.max) }) }
    }

    func roster(for league: League, teamID: StadiaEntityID) async throws -> StadiaRoster {
        try ensureNFL(league)
        let providerTeamID = SportsIdentityResolver.providerID(from: teamID, provider: .nfl) ?? teamID.rawValue
        let response = try await client.rosters(season: NFLSeason.currentYear)
        let players = (response.rosters ?? [])
            .filter { $0.team?.providerID == providerTeamID || $0.teamID == providerTeamID || $0.team?.abbreviation == providerTeamID }
            .flatMap { $0.persons ?? $0.players ?? [] }
            .compactMap { mapPlayer($0, league: league, teamID: teamID) }
        guard !players.isEmpty else { throw SportsDataError.invalidResponse }
        return StadiaRoster(id: StadiaEntityID(rawValue: "roster:nfl:\(teamID.rawValue)"), teamID: teamID, leagueID: SportsIdentityResolver.canonicalLeagueID(for: league), players: players, provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: providerTeamID, confidence: 0.82))
    }

    func injuries(for league: League) async throws -> [StadiaInjury] {
        try ensureNFL(league)
        let week = try await client.week(for: NFLDateFormatter.dayString(from: Date()))
        let response = try await client.injuries(season: week.seasonValue, seasonType: week.seasonTypeValue, week: week.weekValue)
        let injuries = (response.injuries ?? []).compactMap { mapInjury($0, league: league) }
        guard !injuries.isEmpty else { throw SportsDataError.unsupportedCapability(.injuries) }
        return injuries
    }

    private func ensureNFL(_ league: League) throws {
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.nfl) }
        guard league.path == "football/nfl" else { throw SportsDataError.unsupportedCapability(.liveScores) }
    }

    private func resolvedNFLGameID(from gameID: StadiaEntityID) throws -> String {
        if let providerID = SportsIdentityResolver.providerID(from: gameID, provider: .nfl) { return providerID }
        if gameID.rawValue.contains("-") { return gameID.rawValue }
        throw SportsDataError.invalidResponse
    }

    private func mapGame(_ dto: NFLGameDTO, league: League) -> StadiaGame? {
        guard let providerGameID = dto.providerID, let homeDTO = dto.homeTeam, let awayDTO = dto.awayTeam ?? dto.visitorTeam, let home = mapTeam(homeDTO, league: league), let away = mapTeam(awayDTO, league: league) else { return nil }
        let start = NFLDateFormatter.date(from: dto.date ?? dto.gameDate ?? dto.startTime) ?? Date()
        let status = StadiaGameStatus(nflStatus: dto.status, start: start)
        let period = dto.status?.periodNumber.map { StadiaPeriod(number: $0, displayName: NFLPeriodFormatter.displayName(for: $0)) }
        let clock = dto.status?.clockDisplay.map { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: status == .live) }
        return StadiaGame(id: identityResolver.canonicalGameID(league: league, provider: .nfl, providerGameID: providerGameID, home: home, away: away, scheduledStart: start), leagueID: SportsIdentityResolver.canonicalLeagueID(for: league), scheduledStart: start, name: dto.name ?? "\(away.displayName) at \(home.displayName)", shortName: dto.shortName ?? "\(away.abbreviation) @ \(home.abbreviation)", status: status, statusDetail: NFLStatusFormatter.detail(status: status, dto: dto.status, start: start), homeTeam: home, awayTeam: away, score: StadiaScore(home: (dto.homeScore ?? homeDTO.score).map(String.init), away: (dto.awayScore ?? awayDTO.score).map(String.init)), clock: clock, period: period, venue: dto.venue?.stadiaVenue, broadcasts: dto.broadcasts?.compactMap { $0.stadiaBroadcast } ?? dto.network.map { [StadiaBroadcast(network: $0, type: "TV", countryCode: nil)] } ?? [], aliases: [ProviderEntityAlias(provider: .nfl, id: providerGameID)], provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.86))
    }

    private func mapTeam(_ dto: NFLTeamDTO?, league: League) -> StadiaTeam? {
        guard let dto else { return nil }
        let abbreviation = dto.abbreviation ?? dto.teamAbbreviation ?? dto.clubCode ?? dto.nickName ?? dto.providerID ?? "NFL"
        let displayName = dto.fullName ?? dto.displayName ?? [dto.cityStateRegion, dto.nickName].compactMap { $0 }.joined(separator: " ")
        guard !displayName.isEmpty else { return nil }
        let providerID = dto.providerID ?? abbreviation
        return StadiaTeam(id: identityResolver.canonicalTeamID(league: league, provider: .nfl, providerTeamID: providerID, abbreviation: abbreviation, displayName: displayName), leagueID: SportsIdentityResolver.canonicalLeagueID(for: league), displayName: displayName, shortName: dto.nickName ?? dto.displayName ?? abbreviation, abbreviation: abbreviation, logoURL: TeamLogoAssetResolver.nflAssetURL(abbreviation: abbreviation) ?? dto.logoURL, aliases: [ProviderEntityAlias(provider: .nfl, id: providerID)], provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: providerID, confidence: 0.86))
    }

    private func mapPlayer(_ dto: NFLPlayerDTO, league: League, teamID: StadiaEntityID?) -> StadiaPlayer? {
        guard let playerID = dto.providerID, let name = dto.displayName ?? dto.fullName else { return nil }
        return StadiaPlayer(id: identityResolver.canonicalPlayerID(league: league, provider: .nfl, providerPlayerID: playerID, fullName: name, teamAbbreviation: dto.teamAbbreviation), leagueID: SportsIdentityResolver.canonicalLeagueID(for: league), fullName: name, displayName: dto.displayName ?? name, teamID: teamID, teamAbbreviation: dto.teamAbbreviation, position: dto.position?.abbreviation ?? dto.position?.name ?? dto.positionGroup, jerseyNumber: dto.jerseyNumber.map(String.init) ?? dto.jersey, birthDate: nil, headshotURL: dto.headshotURL, aliases: [ProviderEntityAlias(provider: .nfl, id: playerID)], provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: playerID, confidence: 0.82))
    }

    private func mapTeamStats(_ team: NFLTeamDTO?, side: String, league: League, gameID: StadiaEntityID) -> StadiaTeamStat? {
        guard let mapped = mapTeam(team, league: league) else { return nil }
        let values = [stat("score", "Score", team?.score.map(String.init)), stat("total_yards", "Total Yards", team?.totalYards.map(String.init)), stat("passing_yards", "Pass Yards", team?.passingYards.map(String.init)), stat("rushing_yards", "Rush Yards", team?.rushingYards.map(String.init)), stat("first_downs", "First Downs", team?.firstDowns.map(String.init)), stat("turnovers", "Turnovers", team?.turnovers.map(String.init)), stat("possession", "Possession", team?.possessionTime)].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        return StadiaTeamStat(id: StadiaEntityID(rawValue: "teamStat:nfl:\(gameID.rawValue):\(side)"), teamID: mapped.id, seasonID: nil, stats: values, provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: team?.providerID, confidence: 0.76))
    }

    private func mapInjury(_ dto: NFLInjuryDTO, league: League) -> StadiaInjury? {
        let playerID = dto.person?.providerID ?? dto.playerID
        guard let playerName = dto.person?.displayName ?? dto.playerName else { return nil }
        let player = identityResolver.canonicalPlayerID(league: league, provider: .nfl, providerPlayerID: playerID ?? playerName, fullName: playerName, teamAbbreviation: dto.team?.abbreviation ?? dto.teamAbbreviation)
        return StadiaInjury(id: StadiaEntityID(rawValue: "injury:nfl:\(playerID ?? SportsIdentityResolver.slug(playerName))"), playerID: player, playerName: playerName, teamID: mapTeam(dto.team, league: league)?.id, status: dto.status ?? dto.gameStatus ?? dto.reportStatus ?? "Unknown", detail: dto.injuryDescription ?? dto.bodyPart, provenance: DataProvenance(provider: .nfl, fetchedAt: Date(), providerEntityID: playerID, confidence: 0.76))
    }

    private func stat(_ key: String, _ displayName: String, _ value: String?) -> StadiaStatValue? {
        guard let value, !value.isEmpty else { return nil }
        return StadiaStatValue(key: key, displayName: displayName, value: value)
    }
}

struct NFLClient: Sendable {
    private let baseURL = URL(string: "https://api.nfl.com")!
    private let session: URLSession
    private let tokenStore: NFLTokenStore

    init(session: URLSession = .shared, tokenStore: NFLTokenStore = .shared) {
        self.session = session
        self.tokenStore = tokenStore
    }

    func week(for date: String) async throws -> NFLWeekDTO { try await request(path: "/football/v2/weeks/date/\(date)", query: []) }
    func weeks(season: Int, seasonType: String) async throws -> NFLWeeksResponseDTO { try await request(path: "/football/v2/weeks/season/\(season)/seasonType/\(seasonType)", query: []) }
    func gameSchedule(season: Int, seasonType: String, week: Int) async throws -> NFLGameScheduleResponseDTO { try await request(path: "/football/v2/games/season/\(season)/seasonType/\(seasonType)/week/\(week)", query: [URLQueryItem(name: "withExternalIds", value: "true")]) }
    func teams(season: Int) async throws -> NFLTeamsResponseDTO { try await request(path: "/football/v2/teams/history", query: [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "limit", value: "40")]) }
    func standings(season: Int, seasonType: String, week: Int) async throws -> NFLStandingsResponseDTO { try await request(path: "/football/v2/standings", query: [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "seasonType", value: seasonType), URLQueryItem(name: "week", value: String(week)), URLQueryItem(name: "limit", value: "40")]) }
    func rosters(season: Int) async throws -> NFLRostersResponseDTO { try await request(path: "/football/v2/rosters", query: [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "limit", value: "40")]) }
    func injuries(season: Int, seasonType: String, week: Int) async throws -> NFLInjuriesResponseDTO { try await request(path: "/football/v2/injuries", query: [URLQueryItem(name: "season", value: String(season)), URLQueryItem(name: "seasonType", value: seasonType), URLQueryItem(name: "week", value: String(week))]) }

    func gameDetails(gameID: String) async throws -> NFLGameDetailDTO {
        let envelope: NFLGameDetailEnvelopeDTO = try await request(path: "/experience/v1/gamedetails/\(gameID)", query: [])
        guard let detail = envelope.data?.viewer?.gameDetail else { throw SportsDataError.invalidResponse }
        return detail
    }

    func weekReferences(from start: Date, to end: Date) async throws -> [NFLWeekReference] {
        let startWeek = try await week(for: NFLDateFormatter.dayString(from: start))
        let endWeek = try await week(for: NFLDateFormatter.dayString(from: end))
        if startWeek.reference == endWeek.reference { return [startWeek.reference] }
        let weeks = try await weeks(season: startWeek.seasonValue, seasonType: startWeek.seasonTypeValue).weeks ?? []
        let low = min(startWeek.weekValue, endWeek.weekValue)
        let high = max(startWeek.weekValue, endWeek.weekValue)
        let refs = weeks.filter { $0.weekValue >= low && $0.weekValue <= high }.map(\.reference)
        return refs.isEmpty ? [startWeek.reference, endWeek.reference] : Array(Set(refs)).sorted()
    }

    private func request<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        let token = try await tokenStore.token(session: session, baseURL: baseURL)
        var components = URLComponents(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw SportsDataError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        NFLHeaders.apply(to: &request, token: token)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SportsDataError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return try NFLJSONDecoder.decoder.decode(T.self, from: data)
        case 401, 403: await tokenStore.clear(); throw SportsDataError.authenticationFailed
        case 429: throw SportsDataError.rateLimited(retryAfter: nil)
        case 500..<600: throw SportsDataError.unavailable
        default: throw SportsDataError.network("NFL Shield HTTP \(http.statusCode)")
        }
    }
}

actor NFLTokenStore {
    static let shared = NFLTokenStore()
    private var cachedToken: String?
    private var expiration: Date?

    func token(session: URLSession, baseURL: URL) async throws -> String {
        if let cachedToken, let expiration, expiration.timeIntervalSinceNow > 120 { return cachedToken }
        var request = URLRequest(url: baseURL.appendingPathComponent("identity/v3/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 7
        request.setValue(NFLHeaders.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("100", forHTTPHeaderField: "X-Domain-Id")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = ["clientKey": NFLHeaders.publicClientKey, "clientSecret": NFLHeaders.publicClientSecret, "deviceId": UUID().uuidString, "deviceInfo": NFLHeaders.deviceInfo, "networkType": "other"]
        request.httpBody = body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SportsDataError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw http.statusCode == 401 || http.statusCode == 403 ? SportsDataError.authenticationFailed : SportsDataError.network("NFL token HTTP \(http.statusCode)") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = object["accessToken"] as? String, !token.isEmpty else { throw SportsDataError.authenticationFailed }
        cachedToken = token
        expiration = NFLJWT.expiration(token) ?? Date().addingTimeInterval(300)
        return token
    }

    func clear() {
        cachedToken = nil
        expiration = nil
    }
}

enum NFLHeaders {
    nonisolated static let publicClientKey = "4cFUW6DmwJpzT9L7LrG3qRAcABG5s04g"
    nonisolated static let publicClientSecret = "CZuvCL49d9OwfGsR"
    nonisolated static let deviceInfo = "eyJtb2RlbCI6ImRlc2t0b3AiLCJvc05hbWUiOiJXaW5kb3dzIiwib3NWZXJzaW9uIjoiMTAiLCJ2ZXJzaW9uIjoiQ2hyb21lIn0="
    nonisolated static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

    nonisolated static func apply(to request: inout URLRequest, token: String) {
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.nfl.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://www.nfl.com", forHTTPHeaderField: "Origin")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("100", forHTTPHeaderField: "X-Domain-Id")
    }
}

struct NFLGameScheduleResponseDTO: Decodable, Sendable { let games: [NFLGameDTO]? }
struct NFLTeamsResponseDTO: Decodable, Sendable { let teams: [NFLTeamDTO]? }
struct NFLStandingsResponseDTO: Decodable, Sendable { let weeks: [NFLStandingWeekDTO]? }
struct NFLStandingWeekDTO: Decodable, Sendable { let standings: [NFLStandingDTO]? }
struct NFLRostersResponseDTO: Decodable, Sendable { let rosters: [NFLRosterDTO]? }
struct NFLInjuriesResponseDTO: Decodable, Sendable { let injuries: [NFLInjuryDTO]? }
struct NFLWeeksResponseDTO: Decodable, Sendable { let weeks: [NFLWeekDTO]? }
struct NFLWeekReference: Hashable, Comparable, Sendable {
    let season: Int; let seasonType: String; let week: Int
    static func < (lhs: NFLWeekReference, rhs: NFLWeekReference) -> Bool { [lhs.season, NFLSeason.typeOrder(lhs.seasonType), lhs.week].lexicographicallyPrecedes([rhs.season, NFLSeason.typeOrder(rhs.seasonType), rhs.week]) }
}
struct NFLWeekDTO: Decodable, Sendable {
    let season: Int?; let seasonType: String?; let type: String?; let week: Int?; let weekNumber: Int?
    var seasonValue: Int { season ?? NFLSeason.currentYear }
    var seasonTypeValue: String { seasonType ?? type ?? NFLSeason.defaultType(for: Date()) }
    var weekValue: Int { week ?? weekNumber ?? 1 }
    var reference: NFLWeekReference { NFLWeekReference(season: seasonValue, seasonType: seasonTypeValue, week: weekValue) }
}
struct NFLGameDTO: Decodable, Sendable {
    let id: String?; let gameID: String?; let gsisID: String?; let date: String?; let gameDate: String?; let startTime: String?; let name: String?; let shortName: String?; let status: NFLStatusDTO?; let homeTeam: NFLTeamDTO?; let awayTeam: NFLTeamDTO?; let visitorTeam: NFLTeamDTO?; let homeScore: Int?; let awayScore: Int?; let venue: NFLVenueDTO?; let broadcasts: [NFLBroadcastDTO]?; let network: String?
    var providerID: String? { id ?? gameID ?? gsisID }
}
struct NFLGameDetailEnvelopeDTO: Decodable, Sendable { let data: NFLGameDetailDataDTO? }
struct NFLGameDetailDataDTO: Decodable, Sendable { let viewer: NFLGameDetailViewerDTO? }
struct NFLGameDetailViewerDTO: Decodable, Sendable { let gameDetail: NFLGameDetailDTO? }
struct NFLGameDetailDTO: Decodable, Sendable {
    let id: String?; let gameID: String?; let gsisID: String?; let date: String?; let gameDate: String?; let status: NFLStatusDTO?; let homeTeam: NFLTeamDTO?; let awayTeam: NFLTeamDTO?; let visitorTeam: NFLTeamDTO?; let homeScore: Int?; let awayScore: Int?; let venue: NFLVenueDTO?; let broadcasts: [NFLBroadcastDTO]?; let network: String?; let plays: [NFLPlayDTO]?
    func toGame() -> NFLGameDTO { NFLGameDTO(id: id, gameID: gameID, gsisID: gsisID, date: date, gameDate: gameDate, startTime: nil, name: nil, shortName: nil, status: status, homeTeam: homeTeam, awayTeam: awayTeam, visitorTeam: visitorTeam, homeScore: homeScore, awayScore: awayScore, venue: venue, broadcasts: broadcasts, network: network) }
}
struct NFLStatusDTO: Decodable, Sendable {
    let phase: String?; let state: String?; let type: String?; let name: String?; let description: String?; let shortDescription: String?; let displayStatus: String?; let clock: String?; let gameClock: String?; let quarter: Int?; let period: Int?; let isFinal: Bool?; let isLive: Bool?
    nonisolated var periodNumber: Int? { quarter ?? period }
    nonisolated var clockDisplay: String? { clock ?? gameClock }
    nonisolated var statusText: String { [phase, state, type, name, description, shortDescription, displayStatus].compactMap { $0 }.joined(separator: " ").lowercased() }
}
struct NFLTeamDTO: Decodable, Sendable {
    let id: String?; let teamID: String?; let gsisID: String?; let fullName: String?; let displayName: String?; let nickName: String?; let cityStateRegion: String?; let abbreviation: String?; let teamAbbreviation: String?; let clubCode: String?; let logo: String?; let logoURLString: String?; let score: Int?; let totalYards: Int?; let passingYards: Int?; let rushingYards: Int?; let firstDowns: Int?; let turnovers: Int?; let possessionTime: String?
    var providerID: String? { id ?? teamID ?? gsisID ?? abbreviation ?? clubCode }
    var logoURL: URL? { (logoURLString ?? logo).flatMap(URL.init(string:)) }
}
struct NFLStandingDTO: Decodable, Sendable { let team: NFLTeamDTO?; let rank: Int?; let divisionRank: Int?; let conferenceRank: Int?; let divisionName: String?; let conferenceName: String?; let wins: Int?; let losses: Int?; let ties: Int?; let gamesPlayed: Int?; let record: String? }
struct NFLRosterDTO: Decodable, Sendable { let team: NFLTeamDTO?; let teamID: String?; let persons: [NFLPlayerDTO]?; let players: [NFLPlayerDTO]? }
struct NFLPlayerDTO: Decodable, Sendable {
    let id: String?; let gsisID: String?; let playerID: String?; let fullName: String?; let displayName: String?; let jerseyNumber: Int?; let jersey: String?; let position: NFLPositionDTO?; let positionGroup: String?; let teamAbbreviation: String?; let headshot: String?; let headshotURLString: String?
    var providerID: String? { id ?? gsisID ?? playerID }
    var headshotURL: URL? { (headshotURLString ?? headshot).flatMap(URL.init(string:)) }
}
struct NFLPositionDTO: Decodable, Sendable { let abbreviation: String?; let name: String? }
struct NFLVenueDTO: Decodable, Sendable {
    let id: String?; let name: String?; let city: String?; let state: String?; let country: String?
    var stadiaVenue: StadiaVenue? { guard name != nil || city != nil else { return nil }; return StadiaVenue(id: id.map { StadiaEntityID(rawValue: "venue:nfl:\($0)") }, name: name ?? "Venue", city: city, state: state, country: country, aliases: id.map { [ProviderEntityAlias(provider: .nfl, id: $0)] } ?? []) }
}
struct NFLBroadcastDTO: Decodable, Sendable {
    let name: String?; let network: String?; let channel: String?; let type: String?; let countryCode: String?
    var stadiaBroadcast: StadiaBroadcast? { (name ?? network ?? channel).map { StadiaBroadcast(network: $0, type: type ?? "TV", countryCode: countryCode) } }
}
struct NFLPlayDTO: Decodable, Sendable { let playID: String?; let sequence: Int?; let quarter: Int?; let period: Int?; let clock: String?; let playDescription: String?; let description: String?; let shortDescription: String?; let possessionTeam: NFLTeamDTO?; let awayScore: Int?; let visitorScore: Int?; let homeScore: Int?; let isScoringPlay: Bool?; let scoreValue: Int? }
struct NFLInjuryDTO: Decodable, Sendable { let playerID: String?; let playerName: String?; let person: NFLPlayerDTO?; let team: NFLTeamDTO?; let teamAbbreviation: String?; let status: String?; let gameStatus: String?; let reportStatus: String?; let injuryDescription: String?; let bodyPart: String? }

enum NFLJSONDecoder { nonisolated static var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder } }
enum NFLDateFormatter {
    nonisolated static func dayString(from date: Date) -> String { let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date) }
    nonisolated static func date(from value: String?) -> Date? { guard let value else { return nil }; if let date = ISO8601DateFormatter().date(from: value) { return date }; return nil }
}
enum NFLSeason { nonisolated static var currentYear: Int { Calendar.current.component(.year, from: Date()) }; nonisolated static func defaultType(for date: Date) -> String { let month = Calendar.current.component(.month, from: date); if month == 8 { return "PRE" }; if month >= 9 || month == 1 { return "REG" }; return "POST" }; nonisolated static func typeOrder(_ type: String) -> Int { ["PRE": 0, "REG": 1, "POST": 2][type.uppercased()] ?? 3 } }
enum NFLJWT { nonisolated static func expiration(_ token: String) -> Date? { let parts = token.split(separator: "."); guard parts.count > 1 else { return nil }; var payload = String(parts[1]); payload += String(repeating: "=", count: (4 - payload.count % 4) % 4); guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let exp = object["exp"] as? TimeInterval else { return nil }; return Date(timeIntervalSince1970: exp) } }
enum NFLPeriodFormatter { nonisolated static func displayName(for period: Int) -> String { period == 1 ? "1st" : period == 2 ? "2nd" : period == 3 ? "3rd" : period == 4 ? "4th" : "OT" } }
enum NFLStatusFormatter { nonisolated static func detail(status: StadiaGameStatus, dto: NFLStatusDTO?, start: Date) -> String { if let value = dto?.displayStatus ?? dto?.shortDescription ?? dto?.description, !value.isEmpty { return value }; if status == .live { return [dto?.periodNumber.map(NFLPeriodFormatter.displayName), dto?.clockDisplay].compactMap { $0 }.joined(separator: " · ") }; if status == .final { return "Final" }; return RelativeDateTimeFormatter().localizedString(for: start, relativeTo: Date()) } }
extension StadiaGameStatus { init(nflStatus: NFLStatusDTO?, start: Date) { let text = nflStatus?.statusText ?? ""; if nflStatus?.isFinal == true || text.contains("final") || text.contains("complete") || text.contains("closed") { self = .final } else if nflStatus?.isLive == true || text.contains("live") || text.contains("progress") || text.contains("halftime") || text.contains("quarter") { self = .live } else if text.contains("postpon") { self = .postponed } else if text.contains("delay") { self = .delayed } else if text.contains("cancel") { self = .cancelled } else if start.timeIntervalSinceNow < 900 && start.timeIntervalSinceNow > -900 { self = .pregame } else { self = .scheduled } } }

