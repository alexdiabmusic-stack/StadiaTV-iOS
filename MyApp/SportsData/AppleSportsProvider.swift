import Foundation

struct AppleSportsProvider: ScoreProvider, ScheduleProvider, StandingsProvider, TeamProvider, GameDetailsProvider, BoxScoreProvider, TeamStatsProvider, PlayerStatsProvider, LeagueLeaderProvider {
    let metadata: SportsDataProviderMetadata

    private let manifestService: AppleSportsManifestService
    private let client: AppleSportsClient
    private let identityResolver: SportsIdentityResolver

    init(
        manifestService: AppleSportsManifestService = AppleSportsManifestService(client: AppleSportsClient()),
        client: AppleSportsClient = AppleSportsClient(),
        identityResolver: SportsIdentityResolver = SportsIdentityResolver()
    ) {
        self.manifestService = manifestService
        self.client = client
        self.identityResolver = identityResolver
        self.metadata = SportsDataProviderMetadata(
            id: .appleSports,
            name: "Apple Sports",
            supportLevel: .experimental,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: Set(AppleSportsLeagueMapping.supportedLeaguePaths),
            capabilities: [.liveScores, .schedule, .gameStatus, .gameDetails, .boxScore, .standings, .teams, .playerStats, .teamStats, .leagueLeaders],
            authenticationType: .none,
            isEnabled: AppConfiguration.isAppleSportsProviderEnabled,
            requestTimeout: 6
        )
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try ensureEnabled()
        let document = try await document(for: league)
        let today = SportsDateRange.today()
        return document.content.events.compactMap { mapEvent($0, league: league, manifest: document.manifest) }
            .filter { game in
                Calendar.current.isDate(game.scheduledStart, inSameDayAs: today.start) || game.status == .live
            }
            .sorted { $0.scheduledStart < $1.scheduledStart }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        try ensureEnabled()
        let document = try await document(for: league)
        let games = document.content.events.compactMap { mapEvent($0, league: league, manifest: document.manifest) }
            .filter { $0.scheduledStart >= range.start && $0.scheduledStart <= range.end }
            .sorted { $0.scheduledStart < $1.scheduledStart }
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:appleSports:\(league.path):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: games,
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: document.group.cdnID, confidence: 0.7)
        )
    }

    func standings(for league: League) async throws -> [StadiaStandingGroup] {
        try ensureEnabled()
        let document = try await document(for: league)
        if let group = mapLeagueMembersStandings(document: document, league: league) {
            return [group]
        }
        if let group = mapEventLeaderboard(document: document, league: league) {
            return [group]
        }
        throw SportsDataError.unsupportedCapability(.standings)
    }

    func teams(for league: League) async throws -> [StadiaTeam] {
        try ensureEnabled()
        let manifest = try await manifestService.manifest(locale: AppleSportsLocale.defaultIdentifier)
        guard let group = manifest.group(for: league), let groupID = group.canonicalID else { throw SportsDataError.noProviderAvailable(.teams, league.path) }
        return manifest.teams.values
            .filter { $0.leagueIDs.contains(groupID) || $0.groupIDs.contains(groupID) }
            .map { mapTeam(canonicalID: $0.canonicalID, manifestTeam: $0, league: league) }
            .sorted { $0.displayName < $1.displayName }
    }

    func gameDetails(for league: League, gameID: StadiaEntityID) async throws -> StadiaGame {
        try ensureEnabled()
        let document = try await document(for: league)
        let appleEventID = SportsIdentityResolver.providerID(from: gameID, provider: .appleSports) ?? gameID.rawValue
        guard let event = document.content.events.first(where: { $0.canonicalID == appleEventID }), let game = mapEvent(event, league: league, manifest: document.manifest) else {
            throw SportsDataError.invalidResponse
        }
        return game
    }

    func boxScore(for league: League, gameID: StadiaEntityID) async throws -> StadiaBoxScore {
        try ensureEnabled()
        let document = try await document(for: league)
        let appleEventID = SportsIdentityResolver.providerID(from: gameID, provider: .appleSports) ?? gameID.rawValue
        guard let event = document.content.events.first(where: { $0.canonicalID == appleEventID }) else {
            throw SportsDataError.invalidResponse
        }
        let teamStats = event.competitors.compactMap { mapTeamStat(entry: $0, event: event, league: league, manifest: document.manifest) }
        let playerStats = event.competitors.compactMap { mapPlayerStat(entry: $0, event: event, league: league, manifest: document.manifest) }
        guard !teamStats.isEmpty || !playerStats.isEmpty else { throw SportsDataError.unsupportedCapability(.boxScore) }
        return StadiaBoxScore(
            id: StadiaEntityID(rawValue: "boxScore:appleSports:\(appleEventID)"),
            gameID: gameID,
            teamStats: teamStats,
            playerStats: playerStats,
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: appleEventID, confidence: 0.62)
        )
    }

    func teamStats(for league: League, teamIDs: Set<StadiaEntityID>, range: SportsDateRange?) async throws -> [StadiaTeamStat] {
        try ensureEnabled()
        let document = try await document(for: league)
        let stats = document.content.events.flatMap { event in
            event.competitors.compactMap { mapTeamStat(entry: $0, event: event, league: league, manifest: document.manifest) }
        }
        let filtered = teamIDs.isEmpty ? stats : stats.filter { teamIDs.contains($0.teamID) }
        guard !filtered.isEmpty else { throw SportsDataError.unsupportedCapability(.teamStats) }
        return filtered
    }

    func playerStats(for league: League, playerIDs: Set<StadiaEntityID>, range: SportsDateRange?) async throws -> [StadiaPlayerStat] {
        try ensureEnabled()
        let document = try await document(for: league)
        let stats = document.content.events.flatMap { event in
            event.competitors.compactMap { mapPlayerStat(entry: $0, event: event, league: league, manifest: document.manifest) }
        }
        let filtered = playerIDs.isEmpty ? stats : stats.filter { playerIDs.contains($0.playerID) }
        guard !filtered.isEmpty else { throw SportsDataError.unsupportedCapability(.playerStats) }
        return filtered
    }

    func leaders(for league: League) async throws -> [StadiaLeader] {
        try ensureEnabled()
        let document = try await document(for: league)
        let leaderStats = document.content.events.flatMap { event in
            event.competitors.compactMap { mapPlayerStat(entry: $0, event: event, league: league, manifest: document.manifest) }
        }
        let grouped = Dictionary(grouping: leaderStats.flatMap(\.stats)) { $0.key }
        let leaders = grouped.compactMap { key, values -> StadiaLeader? in
            guard let first = values.first else { return nil }
            let players = leaderStats.filter { playerStat in playerStat.stats.contains { $0.key == key } }
            guard !players.isEmpty else { return nil }
            return StadiaLeader(
                id: StadiaEntityID(rawValue: "leader:appleSports:\(league.path):\(key)"),
                statKey: key,
                displayName: first.displayName,
                players: players,
                provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: key, confidence: 0.55)
            )
        }
        guard !leaders.isEmpty else { throw SportsDataError.unsupportedCapability(.leagueLeaders) }
        return leaders
    }

    private func ensureEnabled() throws {
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.appleSports) }
    }

    private func document(for league: League) async throws -> AppleSportsLeagueDocumentContext {
        let manifest = try await manifestService.manifest(locale: AppleSportsLocale.defaultIdentifier)
        guard let group = manifest.group(for: league), let cdnID = group.cdnID else {
            throw SportsDataError.noProviderAvailable(.liveScores, league.path)
        }
        let document = try await client.leagueDocument(cdnBaseURL: manifest.cdnBaseURL, cdnID: cdnID)
        return AppleSportsLeagueDocumentContext(manifest: manifest, group: group, content: document.content)
    }

    private func mapEvent(_ event: AppleSportsEventDTO, league: League, manifest: AppleSportsManifest) -> StadiaGame? {
        guard let eventID = event.canonicalID else { return nil }
        let competitors = event.competitors
        let homeEntry = competitors.first { $0.competitor?.qualifier?.lowercased() == "home" } ?? competitors.first
        let awayEntry = competitors.first { $0.competitor?.qualifier?.lowercased() == "away" } ?? competitors.dropFirst().first
        let home = mapCompetitor(homeEntry, fallbackName: "Home", league: league, manifest: manifest)
        let away = mapCompetitor(awayEntry, fallbackName: "Away", league: league, manifest: manifest)
        let start = AppleSportsDateParser.date(fromEpochSeconds: event.schedule?.duration?.start) ?? Date()
        let status = StadiaGameStatus(appleProgressStatus: event.progressStatus)
        let period = event.clock?.current?.period.map { StadiaPeriod(number: $0.index, displayName: $0.displayName) }
        let clock = event.clock.flatMap { clock -> StadiaGameClock? in
            guard clock.displayValue != nil || clock.current?.period?.index != nil else { return nil }
            return StadiaGameClock(displayValue: clock.displayValue, remainingSeconds: nil, isRunning: status == .live)
        }
        let shortName = event.shortName ?? "\(away.abbreviation) @ \(home.abbreviation)"
        let venue = event.venues.first.map(mapVenue)
        return StadiaGame(
            id: identityResolver.canonicalGameID(league: league, provider: .appleSports, providerGameID: eventID, home: home, away: away, scheduledStart: start),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            scheduledStart: start,
            name: event.shortName ?? "\(away.displayName) at \(home.displayName)",
            shortName: shortName,
            status: status,
            statusDetail: AppleSportsStatusFormatter.detail(status: status, clock: clock, period: period, start: start),
            homeTeam: home,
            awayTeam: away,
            score: StadiaScore(home: homeEntry?.score?.displayScore, away: awayEntry?.score?.displayScore),
            clock: clock,
            period: period,
            venue: venue,
            broadcasts: [],
            aliases: [ProviderEntityAlias(provider: .appleSports, id: eventID)],
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: eventID, confidence: 0.72)
        )
    }

    private func mapCompetitor(_ entry: AppleSportsCompetitorEntryDTO?, fallbackName: String, league: League, manifest: AppleSportsManifest) -> StadiaTeam {
        let appleID = entry?.competitor?.canonicalID ?? fallbackName
        let manifestTeam = manifest.teams[appleID]
        return mapTeam(canonicalID: appleID, manifestTeam: manifestTeam, league: league, fallbackName: fallbackName)
    }

    private func mapTeam(canonicalID: String, manifestTeam: AppleSportsManifestTeamDTO?, league: League, fallbackName: String? = nil) -> StadiaTeam {
        let displayName = manifestTeam?.fullName ?? manifestTeam?.name ?? fallbackName ?? canonicalID
        let shortName = manifestTeam?.name ?? displayName
        let abbreviation = manifestTeam?.abbr ?? String(shortName.prefix(4)).uppercased()
        return StadiaTeam(
            id: identityResolver.canonicalTeamID(league: league, provider: .appleSports, providerTeamID: canonicalID, abbreviation: abbreviation, displayName: displayName),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: displayName,
            shortName: shortName,
            abbreviation: abbreviation,
            logoURL: AppleSportsImageResolver.logoURL(token: manifestTeam?.logoToken),
            aliases: [ProviderEntityAlias(provider: .appleSports, id: canonicalID)],
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: canonicalID, confidence: manifestTeam == nil ? 0.5 : 0.78)
        )
    }

    private func mapVenue(_ venue: AppleSportsVenueDTO) -> StadiaVenue {
        StadiaVenue(
            id: venue.canonicalID.map { StadiaEntityID(rawValue: "venue:appleSports:\($0)") },
            name: venue.name ?? venue.location?.name ?? "Venue",
            city: venue.location?.city,
            state: venue.location?.state,
            country: venue.location?.country,
            aliases: venue.canonicalID.map { [ProviderEntityAlias(provider: .appleSports, id: $0)] } ?? []
        )
    }

    private func mapTeamStat(entry: AppleSportsCompetitorEntryDTO, event: AppleSportsEventDTO, league: League, manifest: AppleSportsManifest) -> StadiaTeamStat? {
        guard entry.competitor?.isTeam == true else { return nil }
        let team = mapCompetitor(entry, fallbackName: "Team", league: league, manifest: manifest)
        let stats = entry.allStats(prefix: "event")
        guard !stats.isEmpty else { return nil }
        return StadiaTeamStat(
            id: StadiaEntityID(rawValue: "teamStat:appleSports:\(event.canonicalID ?? league.path):\(team.id.rawValue)"),
            teamID: team.id,
            seasonID: nil,
            stats: stats,
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: entry.competitor?.canonicalID, confidence: 0.62)
        )
    }

    private func mapPlayerStat(entry: AppleSportsCompetitorEntryDTO, event: AppleSportsEventDTO, league: League, manifest: AppleSportsManifest) -> StadiaPlayerStat? {
        guard entry.competitor?.isTeam != true, let playerID = entry.competitor?.canonicalID else { return nil }
        let stats = entry.allStats(prefix: "event")
        guard !stats.isEmpty else { return nil }
        let displayName = entry.competitor?.displayName ?? playerID
        let canonicalPlayerID = identityResolver.canonicalPlayerID(league: league, provider: .appleSports, providerPlayerID: playerID, fullName: displayName)
        return StadiaPlayerStat(
            id: StadiaEntityID(rawValue: "playerStat:appleSports:\(event.canonicalID ?? league.path):\(canonicalPlayerID.rawValue)"),
            playerID: canonicalPlayerID,
            playerDisplayName: displayName,
            teamAbbreviation: nil,
            headshotURL: nil,
            teamID: nil,
            seasonID: nil,
            stats: stats,
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: playerID, confidence: 0.58)
        )
    }

    private func mapLeagueMembersStandings(document: AppleSportsLeagueDocumentContext, league: League) -> StadiaStandingGroup? {
        guard let leagueDTO = document.content.leagues.first, !leagueDTO.members.isEmpty else { return nil }
        let standings = leagueDTO.members.enumerated().map { index, member -> StadiaStanding in
            let team = mapTeam(canonicalID: member.canonicalID ?? "member-\(index)", manifestTeam: member.canonicalID.flatMap { document.manifest.teams[$0] }, league: league)
            let wins = member.stat(named: "Wins")
            let losses = member.stat(named: "Losses")
            let ties = member.stat(named: "Ties")
            let overtimeLosses = member.stat(named: "OvertimeLosses")
            let points = member.stat(named: "Points")
            let record = [wins, losses, ties ?? overtimeLosses].compactMap { $0 }.joined(separator: "-")
            return StadiaStanding(
                id: StadiaEntityID(rawValue: "standing:appleSports:\(team.id.rawValue)"),
                teamID: team.id,
                teamDisplayName: team.displayName,
                teamAbbreviation: team.abbreviation,
                teamLogoURL: team.logoURL,
                groupName: league.name,
                rank: index + 1,
                wins: wins,
                losses: losses,
                ties: ties ?? overtimeLosses,
                points: points,
                gamesPlayed: member.stat(named: "GamesPlayed"),
                displayRecord: record.isEmpty ? "--" : record,
                provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: member.canonicalID, confidence: 0.65)
            )
        }
        return StadiaStandingGroup(id: StadiaEntityID(rawValue: "standings:appleSports:\(league.path)"), name: league.name, standings: standings)
    }

    private func mapEventLeaderboard(document: AppleSportsLeagueDocumentContext, league: League) -> StadiaStandingGroup? {
        guard let event = document.content.events.first(where: { !$0.competitors.isEmpty }) else { return nil }
        let standings = event.competitors.enumerated().map { index, entry -> StadiaStanding in
            let team = mapCompetitor(entry, fallbackName: "Competitor \(index + 1)", league: league, manifest: document.manifest)
            let score = entry.score?.displayScore
            return StadiaStanding(
                id: StadiaEntityID(rawValue: "standing:appleSports:\(event.canonicalID ?? league.path):\(index)"),
                teamID: team.id,
                teamDisplayName: team.displayName,
                teamAbbreviation: team.abbreviation,
                teamLogoURL: team.logoURL,
                groupName: event.shortName ?? league.name,
                rank: index + 1,
                wins: nil,
                losses: nil,
                ties: nil,
                points: score,
                gamesPlayed: nil,
                displayRecord: score ?? "--",
                provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: event.canonicalID, confidence: 0.58)
            )
        }
        return StadiaStandingGroup(id: StadiaEntityID(rawValue: "leaderboard:appleSports:\(league.path)"), name: event.shortName ?? league.name, standings: standings)
    }
}

actor AppleSportsManifestService {
    private let client: AppleSportsClient
    private var cachedManifest: AppleSportsManifest?

    init(client: AppleSportsClient) {
        self.client = client
    }

    func manifest(locale: String) async throws -> AppleSportsManifest {
        if let cachedManifest { return cachedManifest }
        let response = try await client.manifest(locale: locale)
        let manifest = AppleSportsManifest(response: response)
        cachedManifest = manifest
        return manifest
    }
}

struct AppleSportsClient: Sendable {
    private let originBaseURL: URL
    private let session: URLSession

    nonisolated init(originBaseURL: URL = URL(string: "https://api.sports.apple.com")!, session: URLSession = .shared) {
        self.originBaseURL = originBaseURL
        self.session = session
    }

    func manifest(locale: String) async throws -> AppleSportsManifestResponseDTO {
        try await get(originBaseURL.appendingPathComponent("v3/\(locale)/manifest/3.0.0"))
    }

    func leagueDocument(cdnBaseURL: URL, cdnID: String) async throws -> AppleSportsDocumentDTO {
        try await get(cdnBaseURL.appendingPathComponent(cdnID))
    }

    func globalUpdates(cdnBaseURL: URL) async throws -> AppleSportsRawJSON {
        try await get(cdnBaseURL.appendingPathComponent("updates/SPORTS"))
    }

    func documentUpdates(cdnBaseURL: URL, cdnID: String, timestampMilliseconds: Int64) async throws -> AppleSportsRawJSON {
        var components = URLComponents(url: cdnBaseURL.appendingPathComponent("updates/\(cdnID)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "timestamp", value: String(timestampMilliseconds))]
        guard let url = components?.url else { throw SportsDataError.invalidResponse }
        return try await get(url)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("StadiaTV/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SportsDataError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                return try AppleSportsJSONDecoder.decoder.decode(T.self, from: data)
            case 401, 403:
                throw SportsDataError.authenticationFailed
            case 404:
                throw SportsDataError.unsupportedCapability(.liveScores)
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

struct AppleSportsManifest: Sendable {
    let version: String?
    let cdnBaseURL: URL
    let imageServiceURL: URL?
    let groups: [String: AppleSportsManifestGroupDTO]
    let teams: [String: AppleSportsManifestTeamDTO]

    nonisolated init(response: AppleSportsManifestResponseDTO) {
        version = response.version
        cdnBaseURL = response.cdnBaseURL ?? URL(string: "https://api-sports.cdn-apple.com/v3/query")!
        imageServiceURL = response.imageServiceURL
        groups = response.groups
        teams = response.teams
    }

    func group(for league: League) -> AppleSportsManifestGroupDTO? {
        guard let identifiers = AppleSportsLeagueMapping.appleIdentifiers[league.path] else { return nil }
        return groups.values.first { group in
            identifiers.abbreviations.contains(group.abbr ?? "") || identifiers.names.contains(group.name ?? "")
        }
    }
}

struct AppleSportsLeagueDocumentContext: Sendable {
    let manifest: AppleSportsManifest
    let group: AppleSportsManifestGroupDTO
    let content: AppleSportsDocumentContentDTO
}

struct AppleSportsManifestResponseDTO: Decodable, Sendable {
    let version: String?
    let cdnBaseURL: URL?
    let imageServiceURL: URL?
    let groups: [String: AppleSportsManifestGroupDTO]
    let teams: [String: AppleSportsManifestTeamDTO]

    enum CodingKeys: String, CodingKey {
        case version
        case cdnBaseURL = "cdn_base_url"
        case imageServiceURL = "image_service_url"
        case groups
        case teams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        cdnBaseURL = try container.decodeIfPresent(URL.self, forKey: .cdnBaseURL)
        imageServiceURL = try container.decodeIfPresent(URL.self, forKey: .imageServiceURL)
        groups = try container.decodeIfPresent([String: AppleSportsManifestGroupDTO].self, forKey: .groups) ?? [:]
        teams = try container.decodeIfPresent([String: AppleSportsManifestTeamDTO].self, forKey: .teams) ?? [:]
    }
}

struct AppleSportsManifestGroupDTO: Decodable, Sendable {
    let canonicalID: String?
    let name: String?
    let fullName: String?
    let abbr: String?
    let cdnID: String?

    enum CodingKeys: String, CodingKey {
        case canonicalID = "canonical_id"
        case name
        case fullName = "full_name"
        case abbr
        case cdnID = "cdn_id"
    }

    init(from decoder: Decoder) throws {
        canonicalID = decoder.codingPath.last?.stringValue
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        abbr = try container.decodeIfPresent(String.self, forKey: .abbr)
        cdnID = try container.decodeIfPresent(String.self, forKey: .cdnID)
    }
}

struct AppleSportsManifestTeamDTO: Decodable, Sendable {
    let canonicalID: String
    let leagueIDs: [String]
    let groupIDs: [String]
    let name: String?
    let fullName: String?
    let logoToken: String?
    let abbr: String?

    enum CodingKeys: String, CodingKey {
        case leagueIDs = "league_ids"
        case groupIDs = "group_ids"
        case name
        case fullName = "full_name"
        case logoToken = "logo_token"
        case abbr
    }

    init(from decoder: Decoder) throws {
        canonicalID = decoder.codingPath.last?.stringValue ?? UUID().uuidString
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leagueIDs = try container.decodeIfPresent([String].self, forKey: .leagueIDs) ?? []
        groupIDs = try container.decodeIfPresent([String].self, forKey: .groupIDs) ?? []
        name = try container.decodeIfPresent(String.self, forKey: .name)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        logoToken = try container.decodeIfPresent(String.self, forKey: .logoToken)
        abbr = try container.decodeIfPresent(String.self, forKey: .abbr)
    }
}

struct AppleSportsDocumentDTO: Decodable, Sendable {
    let content: AppleSportsDocumentContentDTO
}

struct AppleSportsDocumentContentDTO: Decodable, Sendable {
    let leagues: [AppleSportsDocumentLeagueDTO]
    let events: [AppleSportsEventDTO]

    enum CodingKeys: String, CodingKey {
        case leagues
        case events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leagues = try container.decodeIfPresent([AppleSportsDocumentLeagueDTO].self, forKey: .leagues) ?? []
        events = try container.decodeIfPresent([AppleSportsEventDTO].self, forKey: .events) ?? []
    }
}

struct AppleSportsDocumentLeagueDTO: Decodable, Sendable {
    let canonicalID: String?
    let members: [AppleSportsLeagueMemberDTO]

    enum CodingKeys: String, CodingKey {
        case canonicalID
        case members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalID = try container.decodeIfPresent(String.self, forKey: .canonicalID)
        members = try container.decodeIfPresent([AppleSportsLeagueMemberDTO].self, forKey: .members) ?? []
    }
}

struct AppleSportsLeagueMemberDTO: Decodable, Sendable {
    let canonicalID: String?
    let statistics: [AppleSportsStatisticDTO]

    enum CodingKeys: String, CodingKey {
        case canonicalID
        case statistics
    }

    func stat(named name: String) -> String? {
        statistics.first { $0.statisticType?.name == name }?.displayValue
    }
}

struct AppleSportsEventDTO: Decodable, Sendable {
    let canonicalID: String?
    let progressStatus: String?
    let shortName: String?
    let schedule: AppleSportsScheduleDTO?
    let venues: [AppleSportsVenueDTO]
    let clock: AppleSportsClockDTO?
    let competitors: [AppleSportsCompetitorEntryDTO]

    enum CodingKeys: String, CodingKey {
        case canonicalID
        case progressStatus
        case shortName
        case schedule
        case venues
        case clock
        case competitors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalID = try container.decodeIfPresent(String.self, forKey: .canonicalID)
        progressStatus = try container.decodeIfPresent(String.self, forKey: .progressStatus)
        shortName = try container.decodeIfPresent(String.self, forKey: .shortName)
        schedule = try container.decodeIfPresent(AppleSportsScheduleDTO.self, forKey: .schedule)
        venues = try container.decodeIfPresent([AppleSportsVenueDTO].self, forKey: .venues) ?? []
        clock = try container.decodeIfPresent(AppleSportsClockDTO.self, forKey: .clock)
        competitors = try container.decodeIfPresent([AppleSportsCompetitorEntryDTO].self, forKey: .competitors) ?? []
    }
}

struct AppleSportsScheduleDTO: Decodable, Sendable {
    let duration: AppleSportsDurationDTO?
    let isTba: Bool?
    let eventTimeInfo: String?
}

struct AppleSportsDurationDTO: Decodable, Sendable {
    let start: Double?
}

struct AppleSportsVenueDTO: Decodable, Sendable {
    let canonicalID: String?
    let name: String?
    let location: AppleSportsLocationDTO?
}

struct AppleSportsLocationDTO: Decodable, Sendable {
    let name: String?
    let city: String?
    let state: String?
    let country: String?

    enum CodingKeys: String, CodingKey {
        case name
        case city
        case state
        case country
        case localizedState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? AppleSportsLocalizedText.first(from: container, key: .localizedState)
    }
}

struct AppleSportsClockDTO: Decodable, Sendable {
    let current: AppleSportsClockSideDTO?
    let total: AppleSportsClockSideDTO?
    let displayValue: String?

    enum CodingKeys: String, CodingKey {
        case current
        case total
        case displayValue
        case timeRemaining
        case timeElapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = try container.decodeIfPresent(AppleSportsClockSideDTO.self, forKey: .current)
        total = try container.decodeIfPresent(AppleSportsClockSideDTO.self, forKey: .total)
        let explicitDisplay = try container.decodeIfPresent(String.self, forKey: .displayValue)
        let remaining = try container.decodeIfPresent(String.self, forKey: .timeRemaining)
        let elapsed = try container.decodeIfPresent(String.self, forKey: .timeElapsed)
        displayValue = explicitDisplay ?? remaining ?? elapsed
    }
}

struct AppleSportsClockSideDTO: Decodable, Sendable {
    let period: AppleSportsPeriodDTO?
}

struct AppleSportsPeriodDTO: Decodable, Sendable {
    let type: String?
    let index: Int?

    var displayName: String? {
        guard let index else { return type }
        if let type, !type.isEmpty { return "\(type) \(index)" }
        return "Period \(index)"
    }

    var statKey: String {
        [type, index.map(String.init)].compactMap { $0 }.joined(separator: "_").lowercased()
    }
}

struct AppleSportsCompetitorEntryDTO: Decodable, Sendable {
    let competitor: AppleSportsCompetitorDTO?
    let score: AppleSportsScoreDTO?

    func allStats(prefix: String) -> [StadiaStatValue] {
        score?.allStats(prefix: prefix) ?? []
    }
}

struct AppleSportsCompetitorDTO: Decodable, Sendable {
    let canonicalID: String?
    let qualifier: String?
    let typeName: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case canonicalID
        case qualifier
        case typeName = "__typename"
        case status
    }

    var isTeam: Bool {
        typeName?.localizedCaseInsensitiveContains("Team") == true || qualifier != nil
    }

    var displayName: String? {
        status
    }
}

struct AppleSportsScoreDTO: Decodable, Sendable {
    let scoreEntries: [AppleSportsStatisticDTO]
    let lineScore: [AppleSportsLineScoreDTO]

    enum CodingKeys: String, CodingKey {
        case scoreEntries
        case lineScore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scoreEntries = try container.decodeIfPresent([AppleSportsStatisticDTO].self, forKey: .scoreEntries) ?? []
        lineScore = try container.decodeIfPresent([AppleSportsLineScoreDTO].self, forKey: .lineScore) ?? []
    }

    var displayScore: String? {
        scoreEntries.first { $0.statisticType?.name == "Score" }?.displayValue ?? scoreEntries.first?.displayValue
    }

    func allStats(prefix: String) -> [StadiaStatValue] {
        var values = scoreEntries.compactMap { $0.statValue(prefix: prefix) }
        values += lineScore.flatMap(\.statValues)
        return values.uniquedByKey()
    }
}

struct AppleSportsLineScoreDTO: Decodable, Sendable {
    let period: AppleSportsPeriodDTO?
    let score: [AppleSportsStatisticDTO]

    enum CodingKeys: String, CodingKey {
        case period
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        period = try container.decodeIfPresent(AppleSportsPeriodDTO.self, forKey: .period)
        score = try container.decodeIfPresent([AppleSportsStatisticDTO].self, forKey: .score) ?? []
    }

    var statValues: [StadiaStatValue] {
        let periodKey = period?.statKey ?? "period"
        return score.compactMap { statistic in
            guard let value = statistic.displayValue else { return nil }
            let label = [period?.displayName, statistic.statisticType?.name].compactMap { $0 }.joined(separator: " ")
            return StadiaStatValue(key: "line_\(periodKey)_\(SportsIdentityResolver.slug(statistic.statisticType?.name ?? "score"))", displayName: label.isEmpty ? "Line Score" : label, value: value)
        }
    }
}

struct AppleSportsStatisticDTO: Decodable, Sendable {
    let statisticType: AppleSportsStatisticTypeDTO?
    let value: Double?
    let displayValue: String?

    enum CodingKeys: String, CodingKey {
        case statisticType
        case value
        case displayValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statisticType = try container.decodeIfPresent(AppleSportsStatisticTypeDTO.self, forKey: .statisticType)
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        displayValue = try container.decodeIfPresent(String.self, forKey: .displayValue)
            ?? value.map { value in
                value.rounded() == value ? String(Int(value)) : String(value)
            }
    }

    func statValue(prefix: String) -> StadiaStatValue? {
        guard let name = statisticType?.name, let displayValue else { return nil }
        return StadiaStatValue(key: "\(prefix)_\(SportsIdentityResolver.slug(name))", displayName: name, value: displayValue)
    }
}

struct AppleSportsStatisticTypeDTO: Decodable, Sendable {
    let name: String?
}

struct AppleSportsRawJSON: Decodable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        value = decoder.codingPath.map(\.stringValue).joined(separator: ".")
    }
}

struct AppleSportsLeagueIdentifiers: Sendable {
    let names: Set<String>
    let abbreviations: Set<String>
}

enum AppleSportsLeagueMapping {
    nonisolated static let appleIdentifiers: [String: AppleSportsLeagueIdentifiers] = [
        "football/college-football": AppleSportsLeagueIdentifiers(names: ["FBS"], abbreviations: ["FBS", "CFB"]),
        "basketball/mens-college-basketball": AppleSportsLeagueIdentifiers(names: ["Men’s College Basketball", "Men's College Basketball"], abbreviations: ["CBK"]),
        "basketball/womens-college-basketball": AppleSportsLeagueIdentifiers(names: ["Women’s College Basketball", "Women's College Basketball"], abbreviations: ["WCBK"]),
        "basketball/wnba": AppleSportsLeagueIdentifiers(names: ["WNBA"], abbreviations: ["WNBA"]),
        "hockey/nhl": AppleSportsLeagueIdentifiers(names: ["NHL"], abbreviations: ["NHL"]),
        "baseball/mlb": AppleSportsLeagueIdentifiers(names: ["MLB"], abbreviations: ["MLB"]),
        "basketball/nba": AppleSportsLeagueIdentifiers(names: ["NBA"], abbreviations: ["NBA"]),
        "football/nfl": AppleSportsLeagueIdentifiers(names: ["NFL"], abbreviations: ["NFL"]),
        "soccer/eng.1": AppleSportsLeagueIdentifiers(names: ["Premier League"], abbreviations: ["EPL"]),
        "soccer/eng.2": AppleSportsLeagueIdentifiers(names: ["EFL Championship"], abbreviations: ["CHAMP"]),
        "soccer/usa.1": AppleSportsLeagueIdentifiers(names: ["MLS"], abbreviations: ["MLS"]),
        "soccer/usa.nwsl": AppleSportsLeagueIdentifiers(names: ["NWSL"], abbreviations: ["NWSL"]),
        "soccer/esp.1": AppleSportsLeagueIdentifiers(names: ["LaLiga", "La Liga"], abbreviations: ["LA_LIGA"]),
        "soccer/ita.1": AppleSportsLeagueIdentifiers(names: ["Serie A"], abbreviations: ["ITSA"]),
        "soccer/ger.1": AppleSportsLeagueIdentifiers(names: ["Bundesliga"], abbreviations: ["BUND"]),
        "soccer/fra.1": AppleSportsLeagueIdentifiers(names: ["Ligue 1"], abbreviations: ["FXL1"]),
        "soccer/mex.1": AppleSportsLeagueIdentifiers(names: ["LIGA MX", "Liga MX"], abbreviations: ["LMX"]),
        "soccer/ned.1": AppleSportsLeagueIdentifiers(names: ["Eredivisie"], abbreviations: ["ERE"]),
        "soccer/por.1": AppleSportsLeagueIdentifiers(names: ["Primeira Liga"], abbreviations: ["PORT"]),
        "soccer/ksa.1": AppleSportsLeagueIdentifiers(names: ["Saudi Pro League"], abbreviations: ["SPL"]),
        "soccer/uefa.champions": AppleSportsLeagueIdentifiers(names: ["Champions League"], abbreviations: ["UEFA_CL"]),
        "soccer/uefa.europa": AppleSportsLeagueIdentifiers(names: ["Europa League"], abbreviations: ["UEFA_EU"]),
        "soccer/fifa.world": AppleSportsLeagueIdentifiers(names: ["FIFA World Cup"], abbreviations: ["WC"]),
        "soccer/fifa.wwc": AppleSportsLeagueIdentifiers(names: ["Women’s World Cup", "Women's World Cup"], abbreviations: ["WWC"]),
        "tennis/atp": AppleSportsLeagueIdentifiers(names: ["ATP", "Men’s Tennis", "Men's Tennis"], abbreviations: ["ATP", "MEN_TENNIS"]),
        "tennis/wta": AppleSportsLeagueIdentifiers(names: ["WTA", "Women’s Tennis", "Women's Tennis"], abbreviations: ["WTA", "WOMEN_TENNIS"]),
        "golf/pga": AppleSportsLeagueIdentifiers(names: ["PGA Tour"], abbreviations: ["PGA"]),
        "golf/lpga": AppleSportsLeagueIdentifiers(names: ["LPGA Tour"], abbreviations: ["LPGA"]),
        "racing/f1": AppleSportsLeagueIdentifiers(names: ["Formula 1"], abbreviations: ["FORMULA1"]),
        "racing/nascar-premier": AppleSportsLeagueIdentifiers(names: ["NASCAR"], abbreviations: ["NASCAR"])
    ]

    nonisolated static var supportedLeaguePaths: [String] {
        Array(appleIdentifiers.keys)
    }
}

enum AppleSportsLocale {
    nonisolated static let defaultIdentifier = "en-us"
}

enum AppleSportsImageResolver {
    nonisolated static func logoURL(token: String?) -> URL? {
        guard let token, !token.isEmpty else { return nil }
        return URL(string: "https://is1-ssl.mzstatic.com/image/thumb/\(token)/256x0.png")
    }
}

enum AppleSportsDateParser {
    nonisolated static func date(fromEpochSeconds value: Double?) -> Date? {
        value.map { Date(timeIntervalSince1970: $0) }
    }
}

enum AppleSportsStatusFormatter {
    nonisolated static func detail(status: StadiaGameStatus, clock: StadiaGameClock?, period: StadiaPeriod?, start: Date) -> String {
        switch status {
        case .live:
            let text = [period?.displayName, clock?.displayValue].compactMap { $0 }.joined(separator: " ")
            return text.isEmpty ? "Live" : text
        case .final:
            return "Final"
        case .postponed:
            return "Postponed"
        case .cancelled:
            return "Cancelled"
        case .delayed:
            return "Delayed"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter.string(from: start)
        }
    }
}

enum AppleSportsJSONDecoder {
    nonisolated static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

extension Array where Element == StadiaStatValue {
    func uniquedByKey() -> [StadiaStatValue] {
        var seen = Set<String>()
        var output: [StadiaStatValue] = []
        for value in self where seen.insert(value.key).inserted {
            output.append(value)
        }
        return output
    }
}

extension StadiaGameStatus {
    init(appleProgressStatus: String?) {
        switch appleProgressStatus?.lowercased() {
        case "pregame", "pre_game", "scheduled":
            self = .scheduled
        case "inprogress", "in_progress", "live":
            self = .live
        case "final", "completed", "postgame", "post_game":
            self = .final
        case "postponed":
            self = .postponed
        case "cancelled", "canceled":
            self = .cancelled
        case "delayed":
            self = .delayed
        default:
            self = .unknown
        }
    }
}

extension KeyedDecodingContainer {
    func decodeIfPresent(_ type: URL.Type, forKey key: Key) throws -> URL? {
        guard let value = try decodeIfPresent(String.self, forKey: key) else { return nil }
        return URL(string: value)
    }
}

enum AppleSportsLocalizedText {
    struct Value: Decodable {
        let text: String?
    }

    nonisolated static func first<Key: CodingKey>(from container: KeyedDecodingContainer<Key>, key: Key) -> String? {
        guard let values = try? container.decodeIfPresent([Value].self, forKey: key) else { return nil }
        return values.first?.text
    }
}
