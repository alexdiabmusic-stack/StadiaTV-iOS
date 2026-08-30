import Foundation

struct CBSSportsProvider: ScoreProvider, ScheduleProvider, GameDetailsProvider {
    let metadata: SportsDataProviderMetadata
    private let client: WebSportsClient
    private let mapper: WebSportsEventMapper

    init(client: WebSportsClient = WebSportsClient(providerID: .cbsSports), identityResolver: SportsIdentityResolver = SportsIdentityResolver()) {
        self.client = client
        self.mapper = WebSportsEventMapper(providerID: .cbsSports, identityResolver: identityResolver)
        self.metadata = SportsDataProviderMetadata(
            id: .cbsSports,
            name: "CBS Sports",
            supportLevel: .undocumented,
            supportedSports: [.football, .basketball, .baseball, .hockey],
            supportedLeagues: Set(CBSSportsEndpoint.supportedLeaguePaths.flatMap { [$0, SportsProviderRouteConfiguration.leagueKey(forLegacyPath: $0)] }),
            capabilities: [.liveScores, .schedule, .gameStatus, .gameDetails],
            authenticationType: .publicWebHeaders,
            isEnabled: AppConfiguration.isCBSSportsProviderEnabled,
            requestTimeout: 6
        )
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try ensureSupported(league, capability: .liveScores)
        return try await games(for: league, range: .today())
            .filter { Calendar.current.isDate($0.scheduledStart, inSameDayAs: Date()) || $0.status == .live }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        try ensureSupported(league, capability: .schedule)
        let games = try await games(for: league, range: range)
            .filter { $0.scheduledStart >= range.start && $0.scheduledStart <= range.end }
            .sorted { $0.scheduledStart < $1.scheduledStart }
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:cbsSports:\(league.stadiaKey):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: games,
            provenance: DataProvenance(provider: .cbsSports, fetchedAt: Date(), providerEntityID: nil, confidence: 0.58)
        )
    }

    func gameDetails(for league: League, gameID: StadiaEntityID) async throws -> StadiaGame {
        try ensureSupported(league, capability: .gameDetails)
        let providerGameID = SportsIdentityResolver.providerID(from: gameID, provider: .cbsSports) ?? gameID.rawValue
        let payload = try await client.firstSuccessfulJSON(urls: CBSSportsEndpoint.detailsURLs(league: league, gameID: providerGameID))
        guard let game = mapper.games(from: payload, league: league).first else { throw SportsDataError.invalidResponse }
        return game
    }

    private func games(for league: League, range: SportsDateRange) async throws -> [StadiaGame] {
        try await firstMappedGames(urls: CBSSportsEndpoint.scoreboardURLs(league: league, range: range), league: league)
    }

    private func firstMappedGames(urls: [URL], league: League) async throws -> [StadiaGame] {
        var lastError: Error = SportsDataError.unavailable
        for url in urls {
            do {
                let games = mapper.games(from: try await client.json(url: url), league: league)
                if !games.isEmpty { return games }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func ensureSupported(_ league: League, capability: SportsDataCapability) throws {
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.cbsSports) }
        guard CBSSportsEndpoint.isSupported(league) else { throw SportsDataError.unsupportedCapability(capability) }
    }
}

struct YahooSportsProvider: ScoreProvider, ScheduleProvider, GameDetailsProvider, SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    private let client: WebSportsClient
    private let mapper: WebSportsEventMapper

    init(client: WebSportsClient = WebSportsClient(providerID: .yahooSports), identityResolver: SportsIdentityResolver = SportsIdentityResolver()) {
        self.client = client
        self.mapper = WebSportsEventMapper(providerID: .yahooSports, identityResolver: identityResolver)
        self.metadata = SportsDataProviderMetadata(
            id: .yahooSports,
            name: "Yahoo Sports",
            supportLevel: .undocumented,
            supportedSports: [.football],
            supportedLeagues: Set(YahooSportsEndpoint.supportedLeaguePaths.flatMap { [$0, SportsProviderRouteConfiguration.leagueKey(forLegacyPath: $0)] }),
            capabilities: [.liveScores, .schedule, .gameStatus, .gameDetails, .newsMetadata],
            authenticationType: .publicWebHeaders,
            isEnabled: AppConfiguration.isYahooSportsProviderEnabled,
            requestTimeout: 6
        )
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try ensureSupported(league, capability: .liveScores)
        return try await games(for: league, range: .today())
            .filter { Calendar.current.isDate($0.scheduledStart, inSameDayAs: Date()) || $0.status == .live }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        try ensureSupported(league, capability: .schedule)
        let games = try await games(for: league, range: range)
            .filter { $0.scheduledStart >= range.start && $0.scheduledStart <= range.end }
            .sorted { $0.scheduledStart < $1.scheduledStart }
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:yahooSports:\(league.stadiaKey):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: games,
            provenance: DataProvenance(provider: .yahooSports, fetchedAt: Date(), providerEntityID: nil, confidence: 0.55)
        )
    }

    func gameDetails(for league: League, gameID: StadiaEntityID) async throws -> StadiaGame {
        try ensureSupported(league, capability: .gameDetails)
        let providerGameID = SportsIdentityResolver.providerID(from: gameID, provider: .yahooSports) ?? gameID.rawValue
        let payload = try await client.firstSuccessfulJSON(urls: YahooSportsEndpoint.detailsURLs(league: league, gameID: providerGameID))
        guard let game = mapper.games(from: payload, league: league).first else { throw SportsDataError.invalidResponse }
        return game
    }

    func newsMetadata(for league: League, limit: Int) async throws -> [StadiaNewsArticle] {
        try ensureSupported(league, capability: .newsMetadata)
        let payload = try await client.firstSuccessfulJSON(urls: YahooSportsEndpoint.newsURLs(league: league, limit: limit))
        let articles = WebSportsNewsMapper(providerID: .yahooSports).articles(from: payload, league: league, limit: limit)
        guard !articles.isEmpty else { throw SportsDataError.unsupportedCapability(.newsMetadata) }
        return articles
    }

    private func games(for league: League, range: SportsDateRange) async throws -> [StadiaGame] {
        try await firstMappedGames(urls: YahooSportsEndpoint.scoreboardURLs(league: league, range: range), league: league)
    }

    private func firstMappedGames(urls: [URL], league: League) async throws -> [StadiaGame] {
        var lastError: Error = SportsDataError.unavailable
        for url in urls {
            do {
                let games = mapper.games(from: try await client.json(url: url), league: league)
                if !games.isEmpty { return games }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func ensureSupported(_ league: League, capability: SportsDataCapability) throws {
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.yahooSports) }
        guard YahooSportsEndpoint.isSupported(league) else { throw SportsDataError.unsupportedCapability(capability) }
    }
}

struct FoxSportsProvider: ScoreProvider, ScheduleProvider, GameDetailsProvider, BoxScoreProvider, PlayByPlayProvider, TeamProvider, StandingsProvider, RosterProvider, TeamStatsProvider {
    let metadata: SportsDataProviderMetadata
    private let client: WebSportsClient
    private let mapper: WebSportsEventMapper
    private let identityResolver: SportsIdentityResolver

    init(client: WebSportsClient = WebSportsClient(providerID: .foxSports), identityResolver: SportsIdentityResolver = SportsIdentityResolver()) {
        self.client = client
        self.mapper = WebSportsEventMapper(providerID: .foxSports, identityResolver: identityResolver)
        self.identityResolver = identityResolver
        self.metadata = SportsDataProviderMetadata(
            id: .foxSports,
            name: "FOX Sports Bifrost",
            supportLevel: .undocumented,
            supportedSports: [.football, .basketball, .baseball, .hockey],
            supportedLeagues: Set(FoxSportsEndpoint.supportedLeaguePaths.flatMap { [$0, SportsProviderRouteConfiguration.leagueKey(forLegacyPath: $0)] }),
            capabilities: [.liveScores, .schedule, .gameStatus, .gameDetails, .playByPlay, .boxScore, .standings, .teams, .rosters, .teamStats],
            authenticationType: .apiKey,
            isEnabled: AppConfiguration.isFoxSportsProviderEnabled,
            requestTimeout: 6
        )
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try ensureSupported(league, capability: .liveScores)
        return try await games(for: league, range: .today())
            .filter { Calendar.current.isDate($0.scheduledStart, inSameDayAs: Date()) || $0.status == .live }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        try ensureSupported(league, capability: .schedule)
        let games = try await games(for: league, range: range)
            .filter { $0.scheduledStart >= range.start && $0.scheduledStart <= range.end }
            .sorted { $0.scheduledStart < $1.scheduledStart }
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:foxSports:\(league.stadiaKey):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: games,
            provenance: DataProvenance(provider: .foxSports, fetchedAt: Date(), providerEntityID: nil, confidence: 0.62)
        )
    }

    func gameDetails(for league: League, gameID: StadiaEntityID) async throws -> StadiaGame {
        try ensureSupported(league, capability: .gameDetails)
        let providerGameID = SportsIdentityResolver.providerID(from: gameID, provider: .foxSports) ?? gameID.rawValue
        let payload = try await client.firstSuccessfulJSON(urls: FoxSportsEndpoint.detailsURLs(league: league, gameID: providerGameID))
        guard let game = mapper.games(from: payload, league: league).first else { throw SportsDataError.invalidResponse }
        return game
    }

    func boxScore(for league: League, gameID: StadiaEntityID) async throws -> StadiaBoxScore {
        try ensureSupported(league, capability: .boxScore)
        guard FoxSportsEndpoint.hasEventDataBoxScore(for: league) else { throw SportsDataError.unsupportedCapability(.boxScore) }
        let providerGameID = SportsIdentityResolver.providerID(from: gameID, provider: .foxSports) ?? gameID.rawValue
        let payload = try await client.firstSuccessfulJSON(urls: FoxSportsEndpoint.detailsURLs(league: league, gameID: providerGameID))
        let stats = WebSportsStatsMapper(providerID: .foxSports, identityResolver: identityResolver).teamStats(from: payload, league: league, gameID: gameID)
        guard !stats.isEmpty else { throw SportsDataError.unsupportedCapability(.boxScore) }
        return StadiaBoxScore(id: StadiaEntityID(rawValue: "boxScore:foxSports:\(providerGameID)"), gameID: gameID, teamStats: stats, playerStats: [], provenance: DataProvenance(provider: .foxSports, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.55))
    }

    func playByPlay(for league: League, gameID: StadiaEntityID) async throws -> StadiaPlayByPlay {
        try ensureSupported(league, capability: .playByPlay)
        guard FoxSportsEndpoint.hasEventDataPlayByPlay(for: league) else { throw SportsDataError.unsupportedCapability(.playByPlay) }
        let providerGameID = SportsIdentityResolver.providerID(from: gameID, provider: .foxSports) ?? gameID.rawValue
        let payload = try await client.firstSuccessfulJSON(urls: FoxSportsEndpoint.detailsURLs(league: league, gameID: providerGameID))
        let plays = WebSportsStatsMapper(providerID: .foxSports, identityResolver: identityResolver).plays(from: payload, gameID: gameID, providerGameID: providerGameID)
        guard !plays.isEmpty else { throw SportsDataError.unsupportedCapability(.playByPlay) }
        return StadiaPlayByPlay(id: StadiaEntityID(rawValue: "pbp:foxSports:\(providerGameID)"), gameID: gameID, plays: plays, provenance: DataProvenance(provider: .foxSports, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.58))
    }

    func teams(for league: League) async throws -> [StadiaTeam] {
        try ensureSupported(league, capability: .teams)
        let payload = try await client.firstSuccessfulJSON(urls: FoxSportsEndpoint.teamURLs(league: league))
        let teams = mapper.teams(from: payload, league: league)
        guard !teams.isEmpty else { throw SportsDataError.unsupportedCapability(.teams) }
        return teams
    }

    func standings(for league: League) async throws -> [StadiaStandingGroup] {
        try ensureSupported(league, capability: .standings)
        let payload = try await client.firstSuccessfulJSON(urls: FoxSportsEndpoint.standingsURLs(league: league))
        let standings = WebSportsStatsMapper(providerID: .foxSports, identityResolver: identityResolver).standings(from: payload, league: league)
        guard !standings.isEmpty else { throw SportsDataError.unsupportedCapability(.standings) }
        return standings
    }

    func roster(for league: League, teamID: StadiaEntityID) async throws -> StadiaRoster {
        try ensureSupported(league, capability: .rosters)
        let providerTeamID = SportsIdentityResolver.providerID(from: teamID, provider: .foxSports) ?? teamID.rawValue
        let payload = try await client.firstSuccessfulJSON(urls: FoxSportsEndpoint.rosterURLs(league: league, teamID: providerTeamID))
        let players = WebSportsStatsMapper(providerID: .foxSports, identityResolver: identityResolver).players(from: payload, league: league, teamID: teamID)
        guard !players.isEmpty else { throw SportsDataError.unsupportedCapability(.rosters) }
        return StadiaRoster(id: StadiaEntityID(rawValue: "roster:foxSports:\(providerTeamID)"), teamID: teamID, leagueID: SportsIdentityResolver.canonicalLeagueID(for: league), players: players, provenance: DataProvenance(provider: .foxSports, fetchedAt: Date(), providerEntityID: providerTeamID, confidence: 0.56))
    }

    func teamStats(for league: League, teamIDs: Set<StadiaEntityID>, range: SportsDateRange?) async throws -> [StadiaTeamStat] {
        try await standings(for: league).flatMap(\.standings).compactMap { row in
            guard teamIDs.isEmpty || teamIDs.contains(row.teamID) else { return nil }
            let stats = [stat("record", "Record", row.displayRecord), stat("wins", "W", row.wins), stat("losses", "L", row.losses), stat("points", "Pts", row.points)].compactMap { $0 }
            guard !stats.isEmpty else { return nil }
            return StadiaTeamStat(id: StadiaEntityID(rawValue: "teamStat:foxSports:\(row.teamID.rawValue)"), teamID: row.teamID, seasonID: nil, stats: stats, provenance: row.provenance)
        }
    }

    private func games(for league: League, range: SportsDateRange) async throws -> [StadiaGame] {
        try await firstMappedGames(urls: try await FoxSportsEndpoint.scoreboardURLs(league: league, range: range, client: client), league: league)
    }

    private func ensureSupported(_ league: League, capability: SportsDataCapability) throws {
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.foxSports) }
        guard FoxSportsEndpoint.slug(for: league) != nil else { throw SportsDataError.unsupportedCapability(capability) }
    }

    private func firstMappedGames(urls: [URL], league: League) async throws -> [StadiaGame] {
        var lastError: Error = SportsDataError.unavailable
        for url in urls {
            do {
                let games = mapper.games(from: try await client.json(url: url), league: league)
                if !games.isEmpty { return games }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func stat(_ key: String, _ displayName: String, _ value: String?) -> StadiaStatValue? {
        guard let value, !value.isEmpty else { return nil }
        return StadiaStatValue(key: key, displayName: displayName, value: value)
    }
}

struct WebSportsClient: Sendable {
    let providerID: SportsDataProviderID
    let session: URLSession

    init(providerID: SportsDataProviderID, session: URLSession = .shared) {
        self.providerID = providerID
        self.session = session
    }

    func firstSuccessfulJSON(urls: [URL]) async throws -> WebSportsJSON {
        var lastError: Error = SportsDataError.unavailable
        for url in urls {
            do {
                return try await json(url: url)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func json(url: URL) async throws -> WebSportsJSON {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        WebSportsHeaders.apply(to: &request, providerID: providerID)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SportsDataError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            return try JSONDecoder().decode(WebSportsJSON.self, from: data)
        case 401, 403:
            throw SportsDataError.authenticationFailed
        case 429:
            throw SportsDataError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        case 500..<600:
            throw SportsDataError.unavailable
        default:
            throw SportsDataError.network("\(providerID.rawValue) HTTP \(http.statusCode)")
        }
    }
}

indirect enum WebSportsJSON: Decodable, Sendable {
    case object([String: WebSportsJSON])
    case array([WebSportsJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode([String: WebSportsJSON].self) {
            self = .object(value)
        } else if let value = try? container.decode([WebSportsJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .null
        }
    }

    var objectValue: [String: WebSportsJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var arrayValue: [WebSportsJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .number(value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case let .bool(value): return String(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case let .number(value): return Int(value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }
}

struct WebSportsEventMapper: Sendable {
    let providerID: SportsDataProviderID
    let identityResolver: SportsIdentityResolver

    func games(from payload: WebSportsJSON, league: League) -> [StadiaGame] {
        var seen = Set<StadiaEntityID>()
        let mapped = foxScoreboardGames(from: payload, league: league) + yahooScoreboardGames(from: payload, league: league) + candidateEventObjects(from: payload).compactMap { mapEvent($0, league: league) }
        return mapped.filter { seen.insert($0.id).inserted }
    }

    func teams(from payload: WebSportsJSON, league: League) -> [StadiaTeam] {
        var seen = Set<StadiaEntityID>()
        return candidateTeamObjects(from: payload).compactMap { object in
            mapTeam(object, league: league)
        }.filter { seen.insert($0.id).inserted }
    }

    private func mapEvent(_ object: [String: WebSportsJSON], league: League) -> StadiaGame? {
        let competitors = object.array("competitors", "participants", "teams")?.compactMap(\.objectValue) ?? []
        let homeObject = competitors.first { $0.string("qualifier", "homeAway", "alignment", "side")?.lowercased() == "home" }
            ?? object.object("home", "homeTeam", "homeCompetitor")
            ?? competitors.first
        let awayObject = competitors.first { ["away", "visitor"].contains($0.string("qualifier", "homeAway", "alignment", "side")?.lowercased() ?? "") }
            ?? object.object("away", "awayTeam", "visitorTeam", "awayCompetitor")
            ?? competitors.dropFirst().first
        guard let homeObject, let awayObject else { return nil }
        let home = mapTeam(homeObject, league: league, fallback: "Home")
        let away = mapTeam(awayObject, league: league, fallback: "Away")
        let providerGameID = object.string("id", "eventId", "eventID", "gameId", "gameID", "uuid") ?? "\(away.abbreviation)-\(home.abbreviation)-\(object.string("startTime", "date", "gameDate") ?? UUID().uuidString)"
        let start = WebSportsDateParser.date(from: object.string("startTime", "startDate", "date", "gameDate", "scheduled", "scheduledStart")) ?? Date()
        let status = StadiaGameStatus(webStatus: object.string("status", "statusText", "gameState", "state", "phase"), start: start)
        return StadiaGame(
            id: identityResolver.canonicalGameID(league: league, provider: providerID, providerGameID: providerGameID, home: home, away: away, scheduledStart: start),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            scheduledStart: start,
            name: object.string("name", "title", "eventName") ?? "\(away.displayName) at \(home.displayName)",
            shortName: object.string("shortName", "shortTitle") ?? "\(away.abbreviation) @ \(home.abbreviation)",
            status: status,
            statusDetail: object.string("statusDetail", "statusText", "detail", "phase") ?? WebSportsStatusFormatter.detail(status: status, start: start),
            homeTeam: home,
            awayTeam: away,
            score: StadiaScore(home: score(from: homeObject), away: score(from: awayObject)),
            clock: object.string("clock", "gameClock", "displayClock").map { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: status == .live) },
            period: object.int("period", "quarter").map { StadiaPeriod(number: $0, displayName: nil) },
            venue: mapVenue(object.object("venue", "location")),
            broadcasts: object.broadcasts(),
            aliases: [ProviderEntityAlias(provider: providerID, id: providerGameID)],
            provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.55)
        )
    }

    private func mapTeam(_ object: [String: WebSportsJSON], league: League, fallback: String = "Team") -> StadiaTeam {
        let providerTeamID = object.string("id", "teamId", "teamID", "abbreviation", "abbr") ?? fallback
        let abbreviation = object.string("abbreviation", "abbr", "shortName") ?? providerTeamID
        let displayName = object.string("displayName", "fullName", "name", "teamName", "nickname") ?? fallback
        return StadiaTeam(
            id: identityResolver.canonicalTeamID(league: league, provider: providerID, providerTeamID: providerTeamID, abbreviation: abbreviation, displayName: displayName),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: displayName,
            shortName: object.string("shortName", "nickname", "name") ?? abbreviation,
            abbreviation: abbreviation,
            logoURL: object.url("logo", "logoUrl", "logoURL", "imageUrl", "imageURL") ?? TeamLogoAssetResolver.assetURL(leaguePath: league.path, abbreviation: abbreviation, displayName: displayName, providerTeamID: providerTeamID),
            aliases: [ProviderEntityAlias(provider: providerID, id: providerTeamID)],
            provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: providerTeamID, confidence: 0.55)
        )
    }

    private func score(from object: [String: WebSportsJSON]) -> String? {
        object.string("score", "points", "runs", "goals", "displayScore")
    }

    private func mapVenue(_ object: [String: WebSportsJSON]?) -> StadiaVenue? {
        guard let object, object.string("name", "venueName") != nil || object.string("city") != nil else { return nil }
        let providerVenueID = object.string("id", "venueId")
        return StadiaVenue(id: providerVenueID.map { StadiaEntityID(rawValue: "venue:\(providerID.rawValue):\($0)") }, name: object.string("name", "venueName") ?? "Venue", city: object.string("city"), state: object.string("state"), country: object.string("country"), aliases: providerVenueID.map { [ProviderEntityAlias(provider: providerID, id: $0)] } ?? [])
    }

    private func candidateEventObjects(from payload: WebSportsJSON) -> [[String: WebSportsJSON]] {
        payload.recursiveObjects().filter { object in
            object["competitors"]?.arrayValue != nil || object["participants"]?.arrayValue != nil || object["homeTeam"] != nil || object["awayTeam"] != nil || object["visitorTeam"] != nil
        }
    }

    private func foxScoreboardGames(from payload: WebSportsJSON, league: League) -> [StadiaGame] {
        guard providerID == .foxSports else { return [] }
        return payload.recursiveObjects().flatMap { object in
            object.array("events")?.compactMap(\.objectValue) ?? []
        }.compactMap { event in
            guard let upper = event.object("upperTeam"),
                  let lower = event.object("lowerTeam") else { return nil }
            let tokens = event.object("entityLink")?.object("layout")?.object("tokens") ?? [:]
            let upperURI = upper.string("uri", "entityUri", "teamUri")
            let lowerURI = lower.string("uri", "entityUri", "teamUri")
            let homeURI = tokens.string("homeUri")
            let awayURI = tokens.string("awayUri")
            let homeObject: [String: WebSportsJSON]
            let awayObject: [String: WebSportsJSON]
            if let homeURI, homeURI == upperURI {
                homeObject = upper
                awayObject = lower
            } else if let awayURI, awayURI == lowerURI {
                homeObject = upper
                awayObject = lower
            } else {
                homeObject = lower
                awayObject = upper
            }
            let home = mapFoxTeam(homeObject, league: league, fallback: "Home")
            let away = mapFoxTeam(awayObject, league: league, fallback: "Away")
            let providerGameID = tokens.string("id")
                ?? providerIDFromURI(event.string("contentUri", "uri"))
                ?? "\(away.abbreviation)-\(home.abbreviation)-\(event.string("eventTime") ?? UUID().uuidString)"
            let start = WebSportsDateParser.date(from: event.string("eventTime", "startTime", "date")) ?? Date()
            let statusText = event.string("statusLine", "status", "statusText")
            let status = StadiaGameStatus(webStatus: statusText, start: start)
            return StadiaGame(
                id: identityResolver.canonicalGameID(league: league, provider: providerID, providerGameID: providerGameID, home: home, away: away, scheduledStart: start),
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                scheduledStart: start,
                name: event.string("title", "name") ?? "\(away.displayName) at \(home.displayName)",
                shortName: event.string("shortName") ?? "\(away.abbreviation) @ \(home.abbreviation)",
                status: status,
                statusDetail: statusText ?? WebSportsStatusFormatter.detail(status: status, start: start),
                homeTeam: home,
                awayTeam: away,
                score: StadiaScore(home: score(from: homeObject), away: score(from: awayObject)),
                clock: nil,
                period: nil,
                venue: nil,
                broadcasts: event.broadcasts(),
                aliases: [ProviderEntityAlias(provider: providerID, id: providerGameID)],
                provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.65)
            )
        }
    }

    private func yahooScoreboardGames(from payload: WebSportsJSON, league: League) -> [StadiaGame] {
        guard providerID == .yahooSports else { return [] }
        return payload.recursiveObjects().compactMap { object -> StadiaGame? in
            let competitors = object.array("competitors", "teams")?.compactMap(\.objectValue) ?? []
            let homeCandidate = object.object("home_team", "homeTeam")
                ?? competitors.first { $0.string("type", "homeAway", "qualifier")?.lowercased() == "home" }
            let awayCandidate = object.object("away_team", "awayTeam", "visitorTeam")
                ?? competitors.first { ["away", "visitor"].contains($0.string("type", "homeAway", "qualifier")?.lowercased() ?? "") }
            guard let homeObject = homeCandidate, let awayObject = awayCandidate else { return nil }
            let home = mapTeam(homeObject, league: league, fallback: "Home")
            let away = mapTeam(awayObject, league: league, fallback: "Away")
            let providerGameID = object.string("game_id", "gameId", "id", "eventId") ?? "\(away.abbreviation)-\(home.abbreviation)-\(object.string("start_time", "startTime", "date") ?? UUID().uuidString)"
            let start = WebSportsDateParser.date(from: object.string("start_time", "startTime", "date", "game_time")) ?? Date()
            let status = StadiaGameStatus(webStatus: object.string("status", "status_type", "statusDisplayName"), start: start)
            return StadiaGame(
                id: identityResolver.canonicalGameID(league: league, provider: providerID, providerGameID: providerGameID, home: home, away: away, scheduledStart: start),
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                scheduledStart: start,
                name: object.string("name", "title") ?? "\(away.displayName) at \(home.displayName)",
                shortName: object.string("short_name", "shortName") ?? "\(away.abbreviation) @ \(home.abbreviation)",
                status: status,
                statusDetail: object.string("statusDisplayName", "status_detail", "status") ?? WebSportsStatusFormatter.detail(status: status, start: start),
                homeTeam: home,
                awayTeam: away,
                score: StadiaScore(home: score(from: homeObject), away: score(from: awayObject)),
                clock: object.string("clock").map { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: status == .live) },
                period: object.int("period", "quarter").map { StadiaPeriod(number: $0, displayName: nil) },
                venue: mapVenue(object.object("venue")),
                broadcasts: object.broadcasts(),
                aliases: [ProviderEntityAlias(provider: providerID, id: providerGameID)],
                provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 0.6)
            )
        }
    }

    private func mapFoxTeam(_ object: [String: WebSportsJSON], league: League, fallback: String) -> StadiaTeam {
        let providerTeamID = object.string("id", "teamId", "teamID")
            ?? providerIDFromURI(object.string("uri", "entityUri", "teamUri"))
            ?? object.string("abbreviation", "abbr")
            ?? fallback
        let top = object.string("stackedNameTop")
        let bottom = object.string("stackedNameBottom")
        let stackedName = [top, bottom].compactMap { $0 }.joined(separator: " ")
        let displayName = object.string("displayName", "fullName", "longName", "name")
            ?? (stackedName.isEmpty ? nil : stackedName)
            ?? fallback
        let abbreviation = object.string("abbreviation", "abbr", "shortName") ?? providerTeamID
        return StadiaTeam(
            id: identityResolver.canonicalTeamID(league: league, provider: providerID, providerTeamID: providerTeamID, abbreviation: abbreviation, displayName: displayName),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: displayName,
            shortName: object.string("shortName", "nickname", "name") ?? abbreviation,
            abbreviation: abbreviation,
            logoURL: object.url("logo", "logoUrl", "logoURL", "imageUrl", "imageURL") ?? TeamLogoAssetResolver.assetURL(leaguePath: league.path, abbreviation: abbreviation, displayName: displayName, providerTeamID: providerTeamID),
            aliases: [ProviderEntityAlias(provider: providerID, id: providerTeamID)],
            provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: providerTeamID, confidence: 0.6)
        )
    }

    private func providerIDFromURI(_ uri: String?) -> String? {
        uri?.split(separator: "/").last.map(String.init)
    }

    private func candidateTeamObjects(from payload: WebSportsJSON) -> [[String: WebSportsJSON]] {
        payload.recursiveObjects().filter { object in
            object.string("abbreviation", "abbr") != nil && object.string("displayName", "fullName", "name", "teamName") != nil
        }
    }
}

struct WebSportsStatsMapper: Sendable {
    let providerID: SportsDataProviderID
    let identityResolver: SportsIdentityResolver

    func teamStats(from payload: WebSportsJSON, league: League, gameID: StadiaEntityID) -> [StadiaTeamStat] {
        WebSportsEventMapper(providerID: providerID, identityResolver: identityResolver).teams(from: payload, league: league).compactMap { team in
            let stats = payload.recursiveObjects()
                .filter { $0.string("teamId", "teamID", "id") == SportsIdentityResolver.providerID(from: team.id, provider: providerID) || $0.string("abbreviation", "abbr") == team.abbreviation }
                .flatMap(statValues)
                .uniquedByKey()
            guard !stats.isEmpty else { return nil }
            return StadiaTeamStat(id: StadiaEntityID(rawValue: "teamStat:\(providerID.rawValue):\(gameID.rawValue):\(team.id.rawValue)"), teamID: team.id, seasonID: nil, stats: stats, provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: nil, confidence: 0.5))
        }
    }

    func standings(from payload: WebSportsJSON, league: League) -> [StadiaStandingGroup] {
        let rows = payload.recursiveObjects().enumerated().compactMap { index, object -> StadiaStanding? in
            guard let name = object.string("team", "teamName", "displayName", "name"), object.string("wins", "w", "losses", "l", "record") != nil else { return nil }
            let abbreviation = object.string("abbreviation", "abbr") ?? name
            let team = identityResolver.canonicalTeamID(league: league, provider: providerID, providerTeamID: object.string("teamId", "teamID", "id"), abbreviation: abbreviation, displayName: name)
            let wins = object.string("wins", "w")
            let losses = object.string("losses", "l")
            return StadiaStanding(id: StadiaEntityID(rawValue: "standing:\(providerID.rawValue):\(team.rawValue)"), teamID: team, teamDisplayName: name, teamAbbreviation: abbreviation, teamLogoURL: TeamLogoAssetResolver.assetURL(leaguePath: league.path, abbreviation: abbreviation, displayName: name, providerTeamID: object.string("teamId", "teamID", "id")), groupName: object.string("conference", "division", "group") ?? league.shortName, rank: object.int("rank", "position") ?? index + 1, wins: wins, losses: losses, ties: object.string("ties", "t"), points: object.string("points", "pts"), gamesPlayed: object.string("gamesPlayed", "gp"), displayRecord: object.string("record") ?? [wins, losses].compactMap { $0 }.joined(separator: "-"), provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: object.string("teamId", "teamID", "id"), confidence: 0.5))
        }
        guard !rows.isEmpty else { return [] }
        let grouped = Dictionary(grouping: rows) { $0.groupName ?? league.shortName }
        return grouped.keys.sorted().map { key in
            StadiaStandingGroup(id: StadiaEntityID(rawValue: "standings:\(providerID.rawValue):\(league.stadiaKey):\(SportsIdentityResolver.slug(key))"), name: key, standings: (grouped[key] ?? []).sorted { ($0.rank ?? Int.max) < ($1.rank ?? Int.max) })
        }
    }

    func players(from payload: WebSportsJSON, league: League, teamID: StadiaEntityID) -> [StadiaPlayer] {
        payload.recursiveObjects().compactMap { object -> StadiaPlayer? in
            guard let name = object.string("displayName", "fullName", "name", "player"), object.string("playerId", "athleteId", "id") != nil || object.string("position", "pos") != nil else { return nil }
            let providerPlayerID = object.string("playerId", "athleteId", "id") ?? name
            return StadiaPlayer(id: identityResolver.canonicalPlayerID(league: league, provider: providerID, providerPlayerID: providerPlayerID, fullName: name, teamAbbreviation: object.string("teamAbbreviation", "team")), leagueID: SportsIdentityResolver.canonicalLeagueID(for: league), fullName: name, displayName: name, teamID: teamID, teamAbbreviation: object.string("teamAbbreviation", "team"), position: object.string("position", "pos"), jerseyNumber: object.string("jersey", "jerseyNumber", "number"), birthDate: nil, headshotURL: object.url("headshot", "imageUrl", "imageURL"), aliases: [ProviderEntityAlias(provider: providerID, id: providerPlayerID)], provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: providerPlayerID, confidence: 0.5))
        }
    }

    func plays(from payload: WebSportsJSON, gameID: StadiaEntityID, providerGameID: String) -> [StadiaPlay] {
        payload.recursiveObjects().enumerated().compactMap { index, object -> StadiaPlay? in
            guard let text = object.string("description", "text", "playDescription", "shortDescription"), !text.isEmpty else { return nil }
            return StadiaPlay(id: StadiaEntityID(rawValue: "play:\(providerID.rawValue):\(providerGameID):\(object.string("id", "playId") ?? String(index))"), sequence: object.int("sequence", "sequenceNumber") ?? index, period: object.int("period", "quarter").map { StadiaPeriod(number: $0, displayName: nil) }, clock: object.string("clock", "gameClock").map { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: nil) }, text: text, teamID: nil, awayScore: object.string("awayScore", "visitorScore"), homeScore: object.string("homeScore"), isScoringPlay: object.string("scoringPlay", "isScoringPlay") == "true", provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: object.string("id", "playId"), confidence: 0.5))
        }
    }

    private func statValues(from object: [String: WebSportsJSON]) -> [StadiaStatValue] {
        object.compactMap { key, value in
            guard !["id", "teamId", "teamID", "name", "displayName", "abbreviation", "abbr"].contains(key), let string = value.stringValue, !string.isEmpty else { return nil }
            return StadiaStatValue(key: SportsIdentityResolver.slug(key), displayName: WebSportsText.titleized(key), value: string)
        }
    }
}

struct WebSportsNewsMapper: Sendable {
    let providerID: SportsDataProviderID

    func articles(from payload: WebSportsJSON, league: League, limit: Int) -> [StadiaNewsArticle] {
        payload.recursiveObjects().compactMap { object -> StadiaNewsArticle? in
            guard let title = object.string("title", "headline"), let url = object.url("url", "link") else { return nil }
            return StadiaNewsArticle(id: StadiaEntityID(rawValue: "article:\(providerID.rawValue):\(SportsIdentityResolver.slug(url.absoluteString))"), headline: title, description: object.string("summary", "description", "shortDescription") ?? "", published: WebSportsDateParser.date(from: object.string("published", "publishedAt", "date")), url: url, imageURL: object.url("image", "imageUrl", "thumbnail"), leagueID: SportsIdentityResolver.canonicalLeagueID(for: league), teamIDs: [], playerIDs: [], sourceName: "Yahoo Sports", provenance: DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: url.absoluteString, confidence: 0.52))
        }.prefix(limit).map { $0 }
    }
}

enum CBSSportsEndpoint {
    nonisolated static let supportedLeaguePaths = ["football/nfl", "football/college-football", "basketball/nba", "basketball/wnba", "basketball/mens-college-basketball", "baseball/mlb", "hockey/nhl"]

    nonisolated static func isSupported(_ league: League) -> Bool {
        supportedLeaguePaths.contains(league.path)
    }

    nonisolated static func scoreboardURLs(league: League, range: SportsDateRange) -> [URL] {
        let slug = cbsSlug(for: league)
        return [
            "https://api.cbssports.com/fantasy/league/scores/live?version=3.0&sport=\(slug)",
            "https://www.cbssports.com/\(slug)/scoreboard/",
            "https://sports.cbsimg.net/cbssports/scores/live/\(slug).json"
        ].compactMap(URL.init(string:))
    }

    nonisolated static func detailsURLs(league: League, gameID: String) -> [URL] {
        let slug = cbsSlug(for: league)
        return [
            "https://www.cbssports.com/\(slug)/gametracker/live/\(gameID)/",
            "https://sports.cbsimg.net/cbssports/scores/game/\(slug)/\(gameID).json"
        ].compactMap(URL.init(string:))
    }

    private nonisolated static func cbsSlug(for league: League) -> String {
        switch league.path {
        case "football/nfl": return "nfl"
        case "football/college-football": return "college-football"
        case "basketball/nba": return "nba"
        case "basketball/wnba": return "wnba"
        case "basketball/mens-college-basketball": return "college-basketball"
        case "baseball/mlb": return "mlb"
        case "hockey/nhl": return "nhl"
        default: return league.path.replacingOccurrences(of: "/", with: "-")
        }
    }
}

enum YahooSportsEndpoint {
    nonisolated static let supportedLeaguePaths = ["football/college-football"]

    nonisolated static func isSupported(_ league: League) -> Bool {
        supportedLeaguePaths.contains(league.path)
    }

    nonisolated static func scoreboardURLs(league: League, range: SportsDateRange) -> [URL] {
        let sport = yahooSport(for: league)
        let date = WebSportsDateParser.compactDayString(from: range.start)
        guard league.path == "football/college-football" else {
            return ["https://sports.yahoo.com/site/api/resource/sports.scoreboard;date=\(date);sport=\(sport)"].compactMap(URL.init(string:))
        }
        return collegeFootballWeekCandidates(for: range.start).flatMap { week in
            [
                "https://api-secure.sports.yahoo.com/v1/editorial/s/scoreboard?leagues=ncaaf&week=\(week)&season=\(seasonYear(for: range.start))&count=500&v=2&lang=en-US&region=US&tz=America/Chicago",
                "https://graphite-secure.sports.yahoo.com/v1/query/shangrila/yahoo_cfb_scoreboard?leagues=ncaaf&week=\(week)&season=\(seasonYear(for: range.start))&count=500&lang=en-US&region=US&tz=America/Chicago"
            ].compactMap(URL.init(string:))
        }
    }

    nonisolated static func detailsURLs(league: League, gameID: String) -> [URL] {
        guard league.path == "football/college-football" else {
            return ["https://sports.yahoo.com/site/api/resource/sports.game;id=\(gameID)"].compactMap(URL.init(string:))
        }
        return [
            "https://api-secure.sports.yahoo.com/v1/editorial/s/boxscore/\(gameID)?v=4&lang=en-US&region=US&tz=America/Chicago",
            "https://graphite-secure.sports.yahoo.com/v1/query/shangrila/yahoo_cfb_boxscore?game_id=\(gameID)&lang=en-US&region=US&tz=America/Chicago"
        ].compactMap(URL.init(string:))
    }

    nonisolated static func newsURLs(league: League, limit: Int) -> [URL] {
        let slug = yahooSport(for: league)
        return ["https://api-secure.sports.yahoo.com/v1/editorial/s/\(slug)?limit=\(limit)&lang=en-US&region=US&tz=America/New_York"].compactMap(URL.init(string:))
    }

    private nonisolated static func yahooSport(for league: League) -> String {
        switch league.path {
        case "football/nfl": return "nfl"
        case "football/college-football": return "ncaaf"
        case "basketball/nba": return "nba"
        case "basketball/mens-college-basketball": return "ncaab"
        case "basketball/wnba": return "wnba"
        case "baseball/mlb": return "mlb"
        case "hockey/nhl": return "nhl"
        default: return league.shortName.lowercased()
        }
    }

    private nonisolated static func collegeFootballWeekCandidates(for date: Date) -> [Int] {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year], from: date)
        guard let year = components.year,
              let weekZero = calendar.date(from: DateComponents(year: year, month: 8, day: 24)) else { return [1] }
        let days = max(0, calendar.dateComponents([.day], from: weekZero, to: date).day ?? 0)
        let estimated = min(17, max(1, days / 7 + 1))
        return [estimated, estimated - 1, estimated + 1].filter { (1...17).contains($0) }
    }

    private nonisolated static func seasonYear(for date: Date) -> Int {
        Calendar(identifier: .gregorian).component(.year, from: date)
    }
}

enum FoxSportsEndpoint {
    nonisolated static let dataKey = "jE7yBJVRNAwdDesMgTzTXUUSx1It41Fq"
    nonisolated static let supportedLeaguePaths = ["football/college-football", "basketball/nba", "basketball/mens-college-basketball", "basketball/womens-college-basketball", "basketball/wnba", "baseball/mlb", "hockey/nhl"]

    nonisolated static func slug(for league: League) -> String? {
        switch league.path {
        case "football/college-football": return "cfb"
        case "basketball/nba": return "nba"
        case "basketball/mens-college-basketball": return "cbk"
        case "basketball/womens-college-basketball": return "wcbk"
        case "basketball/wnba": return "wnba"
        case "baseball/mlb": return "mlb"
        case "hockey/nhl": return "nhl"
        default: return nil
        }
    }

    nonisolated static func scoreboardURLs(league: League, range: SportsDateRange, client: WebSportsClient) async throws -> [URL] {
        guard let slug = slug(for: league) else { return [] }
        if slug == "cfb" {
            let segmentIDs = await cfbSegmentIDs(range: range, client: client)
            return bifrostURLs(paths: segmentIDs.map { "cfb/league/scores-segment/\($0)?groupId=2" })
                + bifrostURLs(paths: ["cfb/scoreboard/main?groupId=2"])
        }
        return bifrostURLs(paths: ["\(slug)/league/scores", "\(slug)/scores", "\(slug)/league/schedule"])
    }

    nonisolated static func detailsURLs(league: League, gameID: String) -> [URL] {
        guard let slug = slug(for: league) else { return [] }
        return bifrostURLs(paths: ["\(slug)/event/\(gameID)/data", "\(slug)/event/\(gameID)/boxscore", "\(slug)/event/\(gameID)/pbp"])
    }

    nonisolated static func teamURLs(league: League) -> [URL] {
        guard let slug = slug(for: league) else { return [] }
        if slug == "cfb" { return bifrostURLs(paths: ["cfb/league/teamnav"]) }
        return bifrostURLs(paths: ["\(slug)/team/\(seedTeamID(for: slug))/standings"])
    }

    nonisolated static func standingsURLs(league: League) -> [URL] {
        guard let slug = slug(for: league) else { return [] }
        if slug == "cfb" { return bifrostURLs(paths: ["cfb/team/1/standings"]) }
        return bifrostURLs(paths: ["\(slug)/team/\(seedTeamID(for: slug))/standings"])
    }

    nonisolated static func rosterURLs(league: League, teamID: String) -> [URL] {
        guard let slug = slug(for: league) else { return [] }
        return bifrostURLs(paths: ["\(slug)/team/\(teamID)/roster"])
    }

    nonisolated static func hasEventDataBoxScore(for league: League) -> Bool {
        guard let slug = slug(for: league) else { return false }
        return slug != "mlb"
    }

    nonisolated static func hasEventDataPlayByPlay(for league: League) -> Bool {
        guard let slug = slug(for: league) else { return false }
        return slug != "mlb"
    }

    private nonisolated static func seedTeamID(for slug: String) -> String {
        switch slug {
        case "nba": return "5"
        case "wnba": return "11"
        case "nhl": return "1"
        case "mlb": return "1"
        case "cbk", "wcbk": return "1"
        default: return "1"
        }
    }

    private static func cfbSegmentIDs(range: SportsDateRange, client: WebSportsClient) async -> [String] {
        var ids: [String] = []
        if let main = try? await client.firstSuccessfulJSON(urls: bifrostURLs(paths: ["cfb/scoreboard/main?groupId=2"])) {
            ids += main.recursiveObjects().compactMap { $0.string("currentSelectionId", "selectionId", "id") }
                .filter { $0.contains("-") }
        }
        ids += collegeFootballSegmentCandidates(for: range.start)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private nonisolated static func collegeFootballSegmentCandidates(for date: Date) -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let start = calendar.date(from: DateComponents(year: year, month: 8, day: 24)) ?? date
        let days = max(0, calendar.dateComponents([.day], from: start, to: date).day ?? 0)
        let week = min(17, max(1, days / 7 + 1))
        return [week, week - 1, week + 1]
            .filter { (1...17).contains($0) }
            .map { "\(year)-\($0)-1" }
    }

    private nonisolated static func bifrostURLs(paths: [String]) -> [URL] {
        paths.compactMap { path in
            let separator = path.contains("?") ? "&" : "?"
            return URL(string: "https://api.foxsports.com/bifrost/v1/\(path)\(separator)apikey=\(dataKey)&api-version=1.1")
        }
    }
}

enum WebSportsHeaders {
    nonisolated static func apply(to request: inout URLRequest, providerID: SportsDataProviderID) {
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        switch providerID {
        case .foxSports:
            request.setValue("https://www.foxsports.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.foxsports.com/", forHTTPHeaderField: "Referer")
        case .yahooSports:
            request.setValue("https://sports.yahoo.com", forHTTPHeaderField: "Origin")
            request.setValue("https://sports.yahoo.com/", forHTTPHeaderField: "Referer")
        case .cbsSports:
            request.setValue("https://www.cbssports.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.cbssports.com/", forHTTPHeaderField: "Referer")
        default:
            break
        }
    }
}

enum WebSportsDateParser {
    nonisolated static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formats = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MM/dd/yyyy h:mm a"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    nonisolated static func compactDayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

enum WebSportsStatusFormatter {
    nonisolated static func detail(status: StadiaGameStatus, start: Date) -> String {
        switch status {
        case .live: return "Live"
        case .final: return "Final"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: start)
        }
    }
}

enum WebSportsText {
    nonisolated static func titleized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension WebSportsJSON {
    func recursiveObjects() -> [[String: WebSportsJSON]] {
        switch self {
        case let .object(object):
            return [object] + object.values.flatMap { $0.recursiveObjects() }
        case let .array(values):
            return values.flatMap { $0.recursiveObjects() }
        default:
            return []
        }
    }
}

extension Dictionary where Key == String, Value == WebSportsJSON {
    func string(_ keys: String...) -> String? {
        keys.lazy.compactMap { self[$0]?.stringValue }.first
    }

    func int(_ keys: String...) -> Int? {
        keys.lazy.compactMap { self[$0]?.intValue }.first
    }

    func object(_ keys: String...) -> [String: WebSportsJSON]? {
        keys.lazy.compactMap { self[$0]?.objectValue }.first
    }

    func array(_ keys: String...) -> [WebSportsJSON]? {
        keys.lazy.compactMap { self[$0]?.arrayValue }.first
    }

    func url(_ keys: String...) -> URL? {
        string(keys).flatMap(URL.init(string:))
    }

    func broadcasts() -> [StadiaBroadcast] {
        if let broadcasts = array("broadcasts", "networks") {
            return broadcasts.compactMap { value in
                if let object = value.objectValue, let network = object.string("name", "network", "channel") {
                    return StadiaBroadcast(network: network, type: object.string("type") ?? "TV", countryCode: object.string("countryCode"))
                }
                return value.stringValue.map { StadiaBroadcast(network: $0, type: "TV", countryCode: nil) }
            }
        }
        return string("network", "tvNetwork", "broadcast").map { [StadiaBroadcast(network: $0, type: "TV", countryCode: nil)] } ?? []
    }

    private func string(_ keys: [String]) -> String? {
        keys.lazy.compactMap { self[$0]?.stringValue }.first
    }
}

extension StadiaGameStatus {
    init(webStatus: String?, start: Date) {
        let value = webStatus?.lowercased() ?? ""
        if value.contains("final") || value.contains("complete") || value.contains("post") {
            self = .final
        } else if value.contains("live") || value.contains("progress") || value.contains("half") || value.contains("period") || value.contains("quarter") {
            self = .live
        } else if value.contains("postpon") {
            self = .postponed
        } else if value.contains("delay") {
            self = .delayed
        } else if value.contains("cancel") {
            self = .cancelled
        } else if start.timeIntervalSinceNow < 900 && start.timeIntervalSinceNow > -900 {
            self = .pregame
        } else {
            self = .scheduled
        }
    }
}
