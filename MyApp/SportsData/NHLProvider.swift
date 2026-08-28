import Foundation

struct NHLProvider: ScoreProvider, ScheduleProvider, StandingsProvider, TeamProvider, RosterProvider, GameDetailsProvider, PlayByPlayProvider {
    let metadata: SportsDataProviderMetadata

    private let client: NHLClient
    private let identityResolver: SportsIdentityResolver

    init(client: NHLClient = NHLClient(), identityResolver: SportsIdentityResolver = SportsIdentityResolver()) {
        self.client = client
        self.identityResolver = identityResolver
        self.metadata = SportsDataProviderMetadata(
            id: .nhl,
            name: "NHL Web API",
            supportLevel: .firstPartyWeb,
            supportedSports: [.hockey],
            supportedLeagues: ["hockey/nhl"],
            capabilities: [.liveScores, .schedule, .gameStatus, .gameDetails, .playByPlay, .standings, .teams, .rosters],
            authenticationType: .none,
            isEnabled: AppConfiguration.isNHLProviderEnabled,
            requestTimeout: 8
        )
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try ensureNHL(league)
        let response = try await client.score(date: nil)
        return response.games?.compactMap { mapGame($0, league: league) } ?? []
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        try ensureNHL(league)
        var gamesByID: [String: StadiaGame] = [:]
        let calendar = Calendar(identifier: .gregorian)
        var cursor = calendar.startOfDay(for: range.start)
        let end = calendar.startOfDay(for: range.end)

        while cursor <= end {
            let response = try await client.schedule(date: NHLDateFormatter.dayString(from: cursor))
            let games = response.gameWeek?.flatMap { $0.games ?? [] } ?? []
            for game in games.compactMap({ mapGame($0, league: league) }) where game.scheduledStart >= range.start && game.scheduledStart <= range.end {
                gamesByID[game.id.rawValue] = game
            }
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }

        let games = gamesByID.values.sorted { $0.scheduledStart < $1.scheduledStart }
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:nhl:\(league.path):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: games,
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: nil, confidence: 0.92)
        )
    }

    func standings(for league: League) async throws -> [StadiaStandingGroup] {
        try ensureNHL(league)
        let response = try await client.standings(date: nil)
        let rows = response.standings ?? []
        let grouped = Dictionary(grouping: rows) { row in
            [row.conferenceName?.value, row.divisionName?.value].compactMap { $0 }.joined(separator: " - ")
        }

        return grouped.sorted { $0.key < $1.key }.map { groupName, standings in
            StadiaStandingGroup(
                id: StadiaEntityID(rawValue: "standings:nhl:\(SportsIdentityResolver.slug(groupName.isEmpty ? "league" : groupName))"),
                name: groupName.isEmpty ? "NHL" : groupName,
                standings: standings.enumerated().compactMap { index, row in
                    guard let team = mapStandingTeam(row, league: league) else { return nil }
                    let displayRecord = [row.wins, row.losses, row.otLosses].compactMap { $0.map(String.init) }.joined(separator: "-")
                    return StadiaStanding(
                        id: StadiaEntityID(rawValue: "standing:\(team.id.rawValue)"),
                        teamID: team.id,
                        teamDisplayName: team.displayName,
                        teamAbbreviation: team.abbreviation,
                        teamLogoURL: team.logoURL,
                        groupName: groupName.isEmpty ? nil : groupName,
                        rank: row.conferenceSequence ?? row.divisionSequence ?? index + 1,
                        wins: row.wins.map(String.init),
                        losses: row.losses.map(String.init),
                        ties: row.otLosses.map(String.init),
                        points: row.points.map(String.init),
                        gamesPlayed: row.gamesPlayed.map(String.init),
                        displayRecord: displayRecord,
                        provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: row.teamAbbrev?.value, confidence: 0.9)
                    )
                }
            )
        }
    }

    func teams(for league: League) async throws -> [StadiaTeam] {
        try await standings(for: league).flatMap(\.standings).compactMap { standing in
            guard let nhlID = SportsIdentityResolver.providerID(from: standing.teamID, provider: .nhl) else { return nil }
            return StadiaTeam(
                id: standing.teamID,
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                displayName: nhlID,
                shortName: nhlID,
                abbreviation: nhlID,
                logoURL: nil,
                aliases: [ProviderEntityAlias(provider: .nhl, id: nhlID)],
                provenance: standing.provenance
            )
        }
    }

    func roster(for league: League, teamID: StadiaEntityID) async throws -> StadiaRoster {
        try ensureNHL(league)
        guard let abbreviation = SportsIdentityResolver.providerID(from: teamID, provider: .nhl) else {
            throw SportsDataError.invalidResponse
        }
        let response = try await client.roster(teamAbbreviation: abbreviation)
        let players = [
            ("F", response.forwards ?? []),
            ("D", response.defensemen ?? []),
            ("G", response.goalies ?? [])
        ].flatMap { positionGroup, players in
            players.compactMap { mapRosterPlayer($0, positionGroup: positionGroup, league: league, teamID: teamID, teamAbbreviation: abbreviation) }
        }

        return StadiaRoster(
            id: StadiaEntityID(rawValue: "roster:nhl:\(teamID.rawValue)"),
            teamID: teamID,
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            players: players,
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: abbreviation, confidence: 0.9)
        )
    }

    func gameDetails(for league: League, gameID: StadiaEntityID) async throws -> StadiaGame {
        try ensureNHL(league)
        let nhlGameID = try resolvedNHLGameID(from: gameID)
        let response = try await client.landing(gameID: nhlGameID)
        guard let game = mapGame(response, league: league) else { throw SportsDataError.invalidResponse }
        return game
    }

    func playByPlay(for league: League, gameID: StadiaEntityID) async throws -> StadiaPlayByPlay {
        try ensureNHL(league)
        let nhlGameID = try resolvedNHLGameID(from: gameID)
        let response = try await client.playByPlay(gameID: nhlGameID)
        let plays = response.plays?.compactMap { mapPlay($0, league: league, gameID: gameID) } ?? []
        return StadiaPlayByPlay(
            id: StadiaEntityID(rawValue: "pbp:nhl:\(nhlGameID)"),
            gameID: gameID,
            plays: plays,
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: nhlGameID, confidence: 0.86)
        )
    }

    private func ensureNHL(_ league: League) throws {
        guard metadata.isEnabled else { throw SportsDataError.providerDisabled(.nhl) }
        guard league.path == "hockey/nhl" else { throw SportsDataError.unsupportedCapability(.liveScores) }
    }

    private func resolvedNHLGameID(from gameID: StadiaEntityID) throws -> String {
        if let providerID = SportsIdentityResolver.providerID(from: gameID, provider: .nhl) {
            return providerID
        }
        let raw = gameID.rawValue
        if raw.allSatisfy(\.isNumber) { return raw }
        throw SportsDataError.invalidResponse
    }

    private func mapGame(_ dto: NHLGameDTO, league: League) -> StadiaGame? {
        guard let gameID = dto.id.map(String.init), let home = dto.homeTeam, let away = dto.awayTeam else { return nil }
        let provenance = DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: gameID, confidence: 0.92)
        let homeTeam = mapTeam(home, league: league)
        let awayTeam = mapTeam(away, league: league)
        let start = NHLDateFormatter.date(from: dto.startTimeUTC) ?? NHLDateFormatter.dateOnly(from: dto.gameDate) ?? Date()
        let status = StadiaGameStatus(nhlGameState: dto.gameState)
        let period = dto.periodDescriptor.map { StadiaPeriod(number: $0.number, displayName: $0.displayName) }
        let clock = dto.clock.map { StadiaGameClock(displayValue: $0.timeRemaining, remainingSeconds: $0.secondsRemaining, isRunning: $0.running) }
        let statusDetail = NHLStatusFormatter.detail(gameState: dto.gameState, status: status, clock: clock, period: period, start: start)
        let name = "\(awayTeam.displayName) at \(homeTeam.displayName)"
        let shortName = "\(awayTeam.abbreviation) @ \(homeTeam.abbreviation)"

        return StadiaGame(
            id: identityResolver.canonicalGameID(league: league, provider: .nhl, providerGameID: gameID, home: homeTeam, away: awayTeam, scheduledStart: start),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            scheduledStart: start,
            name: name,
            shortName: shortName,
            status: status,
            statusDetail: statusDetail,
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            score: StadiaScore(home: home.score.map(String.init), away: away.score.map(String.init)),
            clock: clock,
            period: period,
            venue: mapVenue(dto.venue),
            broadcasts: dto.tvBroadcasts?.map { StadiaBroadcast(network: $0.network, type: nil, countryCode: $0.countryCode) } ?? [],
            aliases: [ProviderEntityAlias(provider: .nhl, id: gameID)],
            provenance: provenance
        )
    }

    private func mapTeam(_ dto: NHLTeamSideDTO, league: League) -> StadiaTeam {
        let abbreviation = dto.abbrev ?? dto.id.map(String.init) ?? "NHL"
        let displayName = dto.name?.value ?? [dto.placeName?.value, dto.commonName?.value].compactMap { $0 }.joined(separator: " ")
        let shortName = dto.commonName?.value ?? dto.placeName?.value ?? abbreviation
        let providerTeamID = abbreviation
        return StadiaTeam(
            id: identityResolver.canonicalTeamID(league: league, provider: .nhl, providerTeamID: providerTeamID, abbreviation: abbreviation, displayName: displayName.isEmpty ? abbreviation : displayName),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: displayName.isEmpty ? abbreviation : displayName,
            shortName: shortName,
            abbreviation: abbreviation,
            logoURL: dto.logo.flatMap(URL.init(string:)),
            aliases: [ProviderEntityAlias(provider: .nhl, id: providerTeamID)],
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: dto.id.map(String.init), confidence: 0.9)
        )
    }

    private func mapStandingTeam(_ row: NHLStandingDTO, league: League) -> StadiaTeam? {
        guard let abbreviation = row.teamAbbrev?.value else { return nil }
        let displayName = row.teamName?.value ?? abbreviation
        return StadiaTeam(
            id: identityResolver.canonicalTeamID(league: league, provider: .nhl, providerTeamID: abbreviation, abbreviation: abbreviation, displayName: displayName),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: displayName,
            shortName: displayName,
            abbreviation: abbreviation,
            logoURL: row.teamLogo.flatMap(URL.init(string:)),
            aliases: [ProviderEntityAlias(provider: .nhl, id: abbreviation)],
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: abbreviation, confidence: 0.9)
        )
    }

    private func mapRosterPlayer(_ dto: NHLRosterPlayerDTO, positionGroup: String, league: League, teamID: StadiaEntityID, teamAbbreviation: String) -> StadiaPlayer? {
        guard let playerID = dto.id.map(String.init) else { return nil }
        let fullName = [dto.firstName?.value, dto.lastName?.value].compactMap { $0 }.joined(separator: " ")
        let displayName = fullName.isEmpty ? playerID : fullName
        return StadiaPlayer(
            id: identityResolver.canonicalPlayerID(league: league, provider: .nhl, providerPlayerID: playerID, fullName: displayName, teamAbbreviation: teamAbbreviation),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            fullName: displayName,
            displayName: displayName,
            teamID: teamID,
            teamAbbreviation: teamAbbreviation,
            position: dto.positionCode ?? positionGroup,
            jerseyNumber: dto.sweaterNumber.map(String.init),
            birthDate: NHLDateFormatter.dateOnly(from: dto.birthDate),
            headshotURL: dto.headshot.flatMap(URL.init(string:)),
            aliases: [ProviderEntityAlias(provider: .nhl, id: playerID)],
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: playerID, confidence: 0.9)
        )
    }

    private func mapVenue(_ venue: NHLLocalizedString?) -> StadiaVenue? {
        guard let value = venue?.value, !value.isEmpty else { return nil }
        return StadiaVenue(id: StadiaEntityID(rawValue: "venue:nhl:\(SportsIdentityResolver.slug(value))"), name: value, city: nil, state: nil, country: nil, aliases: [])
    }

    private func mapPlay(_ dto: NHLPlayDTO, league: League, gameID: StadiaEntityID) -> StadiaPlay? {
        let eventID = dto.eventId.map(String.init) ?? dto.timeInPeriod ?? UUID().uuidString
        let period = dto.periodDescriptor.map { StadiaPeriod(number: $0.number, displayName: $0.displayName) }
        let clock = dto.timeInPeriod.map { StadiaGameClock(displayValue: $0, remainingSeconds: nil, isRunning: nil) }
        return StadiaPlay(
            id: StadiaEntityID(rawValue: "play:nhl:\(gameID.rawValue):\(eventID)"),
            sequence: dto.eventId,
            period: period,
            clock: clock,
            text: dto.typeDescKey?.replacingOccurrences(of: "-", with: " ").capitalized ?? "Play",
            teamID: nil,
            awayScore: dto.details?.awayScore.map(String.init),
            homeScore: dto.details?.homeScore.map(String.init),
            isScoringPlay: dto.details?.homeScore != nil || dto.details?.awayScore != nil,
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: eventID, confidence: 0.78)
        )
    }
}

struct NHLClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = URL(string: "https://api-web.nhle.com/v1")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func score(date: String?) async throws -> NHLScoreResponseDTO {
        try await get(date.map { "score/\($0)" } ?? "score/now")
    }

    func schedule(date: String) async throws -> NHLScheduleResponseDTO {
        try await get("schedule/\(date)")
    }

    func standings(date: String?) async throws -> NHLStandingsResponseDTO {
        try await get(date.map { "standings/\($0)" } ?? "standings/now")
    }

    func roster(teamAbbreviation: String) async throws -> NHLRosterResponseDTO {
        try await get("roster/\(teamAbbreviation.uppercased())/current")
    }

    func landing(gameID: String) async throws -> NHLGameDTO {
        try await get("gamecenter/\(gameID)/landing")
    }

    func playByPlay(gameID: String) async throws -> NHLPlayByPlayResponseDTO {
        try await get("gamecenter/\(gameID)/play-by-play")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("StadiaTV/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SportsDataError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                return try NHLJSONDecoder.decoder.decode(T.self, from: data)
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

struct NHLScoreResponseDTO: Decodable, Sendable {
    let games: [NHLGameDTO]?
}

struct NHLScheduleResponseDTO: Decodable, Sendable {
    let gameWeek: [NHLGameDayDTO]?
}

struct NHLGameDayDTO: Decodable, Sendable {
    let date: String?
    let games: [NHLGameDTO]?
}

struct NHLStandingsResponseDTO: Decodable, Sendable {
    let standings: [NHLStandingDTO]?
}

struct NHLRosterResponseDTO: Decodable, Sendable {
    let forwards: [NHLRosterPlayerDTO]?
    let defensemen: [NHLRosterPlayerDTO]?
    let goalies: [NHLRosterPlayerDTO]?
}

struct NHLPlayByPlayResponseDTO: Decodable, Sendable {
    let plays: [NHLPlayDTO]?
}

struct NHLGameDTO: Decodable, Sendable {
    let id: Int?
    let gameDate: String?
    let startTimeUTC: String?
    let gameState: String?
    let venue: NHLLocalizedString?
    let homeTeam: NHLTeamSideDTO?
    let awayTeam: NHLTeamSideDTO?
    let tvBroadcasts: [NHLBroadcastDTO]?
    let clock: NHLClockDTO?
    let periodDescriptor: NHLPeriodDTO?
}

struct NHLTeamSideDTO: Decodable, Sendable {
    let id: Int?
    let abbrev: String?
    let score: Int?
    let logo: String?
    let placeName: NHLLocalizedString?
    let commonName: NHLLocalizedString?
    let name: NHLLocalizedString?
}

struct NHLBroadcastDTO: Decodable, Sendable {
    let id: Int?
    let market: String?
    let countryCode: String?
    let network: String?
}

struct NHLClockDTO: Decodable, Sendable {
    let timeRemaining: String?
    let secondsRemaining: Int?
    let running: Bool?
    let inIntermission: Bool?
}

struct NHLPeriodDTO: Decodable, Sendable {
    let number: Int?
    let periodType: String?

    var displayName: String? {
        guard let number else { return periodType }
        switch periodType?.uppercased() {
        case "REG": return "Period \(number)"
        case "OT": return "OT"
        case "SO": return "SO"
        default: return "Period \(number)"
        }
    }
}

struct NHLStandingDTO: Decodable, Sendable {
    let teamName: NHLLocalizedString?
    let teamAbbrev: NHLLocalizedString?
    let teamLogo: String?
    let conferenceName: NHLLocalizedString?
    let divisionName: NHLLocalizedString?
    let conferenceSequence: Int?
    let divisionSequence: Int?
    let gamesPlayed: Int?
    let wins: Int?
    let losses: Int?
    let otLosses: Int?
    let points: Int?
}

struct NHLRosterPlayerDTO: Decodable, Sendable {
    let id: Int?
    let headshot: String?
    let firstName: NHLLocalizedString?
    let lastName: NHLLocalizedString?
    let sweaterNumber: Int?
    let positionCode: String?
    let birthDate: String?
}

struct NHLPlayDTO: Decodable, Sendable {
    let eventId: Int?
    let typeDescKey: String?
    let timeInPeriod: String?
    let periodDescriptor: NHLPeriodDTO?
    let details: NHLPlayDetailsDTO?
}

struct NHLPlayDetailsDTO: Decodable, Sendable {
    let eventOwnerTeamId: Int?
    let awayScore: Int?
    let homeScore: Int?
}

struct NHLLocalizedString: Decodable, Hashable, Sendable {
    let value: String

    init(value: String) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
            return
        }
        if let dictionary = try? container.decode([String: String].self) {
            value = dictionary["default"] ?? dictionary["en"] ?? dictionary.values.first ?? ""
            return
        }
        value = ""
    }
}

enum NHLJSONDecoder {
    nonisolated static var decoder: JSONDecoder {
        JSONDecoder()
    }
}

enum NHLDateFormatter {
    nonisolated static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    nonisolated static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: string) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: string)
    }

    nonisolated static func dateOnly(from string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

enum NHLStatusFormatter {
    nonisolated static func detail(gameState: String?, status: StadiaGameStatus, clock: StadiaGameClock?, period: StadiaPeriod?, start: Date) -> String {
        switch status {
        case .live:
            return [period?.displayName, clock?.displayValue].compactMap { $0 }.joined(separator: " ")
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

extension StadiaGameStatus {
    init(nhlGameState: String?) {
        switch nhlGameState?.uppercased() {
        case "LIVE", "CRIT":
            self = .live
        case "FINAL", "OFF":
            self = .final
        case "PRE":
            self = .pregame
        case "FUT":
            self = .scheduled
        case "POST", "POSTPONED":
            self = .postponed
        case "SUSP", "SUSPENDED":
            self = .suspended
        case "CANCELLED", "CNCL":
            self = .cancelled
        default:
            self = .unknown
        }
    }
}
