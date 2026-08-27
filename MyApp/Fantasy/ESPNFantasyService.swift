import Foundation
import Security

struct ESPNFantasyService: FantasyProviderService, ESPNFantasyCredentialSaving {
    let provider: FantasyProvider = .espn
    let capabilities = FantasyProviderCapabilities(
        leagues: true,
        rosters: true,
        matchups: true,
        standings: true,
        liveScoring: true,
        projections: false,
        transactions: false,
        waiversWrite: false,
        tradesWrite: false,
        draftWrite: false
    )

    private let client: ESPNFantasyClient
    private let credentialStore: ESPNFantasyCredentialStore
    private let playerCache: ESPNFantasyRosterPlayerCache
    private let nowProvider: @Sendable () -> Date

    nonisolated init(
        client: ESPNFantasyClient = ESPNFantasyClient(),
        credentialStore: ESPNFantasyCredentialStore = ESPNFantasyCredentialStore(),
        playerCache: ESPNFantasyRosterPlayerCache = .shared,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.playerCache = playerCache
        self.nowProvider = nowProvider
    }

    func connect(usernameOrUserID: String) async throws -> FantasyConnection {
        let input = try ESPNFantasyConnectionInput(rawValue: usernameOrUserID, now: nowProvider())
        let credentials = await credentialStore.credentials(for: input.connectionKey)
        let response = try await client.league(
            gameCode: input.gameCode,
            seasonID: input.seasonID,
            leagueID: input.leagueID,
            views: [.settings, .team, .status],
            scoringPeriodID: nil,
            filter: nil,
            credentials: credentials
        )
        guard response.id.map(String.init) == input.leagueID || response.settings != nil else {
            throw FantasyProviderError.suspiciousResponse
        }
        let selectedTeamID = input.teamID ?? credentials.map { ESPNFantasyMapper.ownerTeamID(from: response, swid: $0.normalizedSWID) } ?? nil
        return FantasyConnection(
            provider: .espn,
            providerUserID: input.connectionKeyWithTeam(selectedTeamID),
            username: input.leagueID,
            displayName: response.settings?.name ?? "ESPN Fantasy \(input.sport.displayName)",
            avatarID: nil,
            connectedAt: Date(),
            refreshedAt: Date()
        )
    }

    func currentSeasonState(for connection: FantasyConnection) async throws -> FantasySeasonState {
        let descriptor = try ESPNFantasyConnectionInput(connection: connection)
        let response = try await client.league(
            gameCode: descriptor.gameCode,
            seasonID: descriptor.seasonID,
            leagueID: descriptor.leagueID,
            views: [.status, .settings],
            scoringPeriodID: nil,
            filter: nil,
            credentials: await credentialStore.credentials(for: descriptor.connectionKey)
        )
        return ESPNFantasyMapper.seasonState(from: response, descriptor: descriptor)
    }

    func leagues(for connection: FantasyConnection, season: String) async throws -> [FantasyLeague] {
        let descriptor = try ESPNFantasyConnectionInput(connection: connection)
        let response = try await client.league(
            gameCode: descriptor.gameCode,
            seasonID: descriptor.seasonID,
            leagueID: descriptor.leagueID,
            views: [.settings, .team, .status],
            scoringPeriodID: nil,
            filter: nil,
            credentials: await credentialStore.credentials(for: descriptor.connectionKey)
        )
        return [try ESPNFantasyMapper.league(from: response, descriptor: descriptor)]
    }

    func league(id: String) async throws -> FantasyLeague {
        let descriptor = try ESPNFantasyConnectionInput(leagueIdentifier: id)
        let response = try await client.league(
            gameCode: descriptor.gameCode,
            seasonID: descriptor.seasonID,
            leagueID: descriptor.leagueID,
            views: [.settings, .team, .status],
            scoringPeriodID: nil,
            filter: nil,
            credentials: await credentialStore.credentials(for: descriptor.connectionKey)
        )
        return try ESPNFantasyMapper.league(from: response, descriptor: descriptor)
    }

    func leagueUsers(leagueID: String) async throws -> [FantasyTeam] {
        let descriptor = try ESPNFantasyConnectionInput(leagueIdentifier: leagueID)
        let response = try await client.league(
            gameCode: descriptor.gameCode,
            seasonID: descriptor.seasonID,
            leagueID: descriptor.leagueID,
            views: [.team],
            scoringPeriodID: nil,
            filter: nil,
            credentials: await credentialStore.credentials(for: descriptor.connectionKey)
        )
        return ESPNFantasyMapper.teams(from: response, descriptor: descriptor)
    }

    func leagueRosters(leagueID: String, teams: [FantasyTeam]) async throws -> [FantasyRoster] {
        let descriptor = try ESPNFantasyConnectionInput(leagueIdentifier: leagueID)
        let response = try await client.league(
            gameCode: descriptor.gameCode,
            seasonID: descriptor.seasonID,
            leagueID: descriptor.leagueID,
            views: [.roster, .team, .status],
            scoringPeriodID: descriptor.scoringPeriodID,
            filter: nil,
            credentials: await credentialStore.credentials(for: descriptor.connectionKey)
        )
        guard response.teams?.contains(where: { $0.roster?.entries?.isEmpty == false }) == true else {
            throw FantasyProviderError.suspiciousResponse
        }
        await playerCache.store(ESPNFantasyMapper.players(from: response, descriptor: descriptor), leagueID: descriptor.connectionKeyWithTeam(descriptor.teamID))
        return ESPNFantasyMapper.rosters(from: response, descriptor: descriptor, teams: teams)
    }

    func userRoster(in rosters: [FantasyRoster], connection: FantasyConnection) -> FantasyRoster? {
        guard let descriptor = try? ESPNFantasyConnectionInput(connection: connection), let teamID = descriptor.teamID else { return nil }
        return rosters.first { $0.rosterID == teamID }
    }

    func matchup(leagueID: String, week: Int, userRosterID: Int, teams: [FantasyTeam]) async throws -> FantasyMatchup? {
        let baseDescriptor = try ESPNFantasyConnectionInput(leagueIdentifier: leagueID)
        let descriptor = baseDescriptor.with(matchupPeriodID: week)
        let response = try await client.league(
            gameCode: descriptor.gameCode,
            seasonID: descriptor.seasonID,
            leagueID: descriptor.leagueID,
            views: [.matchupScore, .scoreboard],
            scoringPeriodID: descriptor.scoringPeriodID,
            filter: .matchupPeriods([week]),
            credentials: await credentialStore.credentials(for: descriptor.connectionKey)
        )
        return ESPNFantasyMapper.matchup(from: response, descriptor: descriptor, userTeamID: userRosterID, teams: teams)
    }

    func standings(leagueID: String, rosters: [FantasyRoster]) async throws -> [FantasyStanding] {
        let descriptor = try ESPNFantasyConnectionInput(leagueIdentifier: leagueID)
        let response = try await client.league(
            gameCode: descriptor.gameCode,
            seasonID: descriptor.seasonID,
            leagueID: descriptor.leagueID,
            views: [.standings, .team],
            scoringPeriodID: nil,
            filter: nil,
            credentials: await credentialStore.credentials(for: descriptor.connectionKey)
        )
        let standings = ESPNFantasyMapper.standings(from: response, descriptor: descriptor)
        return standings.isEmpty ? rosters.compactMap(ESPNFantasyMapper.standingFromRoster(_:)) : standings
    }

    func players(ids: Set<String>, sport: FantasySport) async throws -> [String: FantasyPlayer] {
        let cached = await playerCache.players()
        guard !ids.isEmpty else { return cached.filter { $0.value.sport == sport } }
        return cached.filter { ids.contains($0.key) && $0.value.sport == sport }
    }

    func disconnect(connection: FantasyConnection) async {
        if let descriptor = try? ESPNFantasyConnectionInput(connection: connection) {
            await credentialStore.deleteCredentials(for: descriptor.connectionKey)
        }
    }

    func refreshCachedData() async {}

    func saveESPNFantasyCredentials(espnS2: String, swid: String, sport: FantasySport, leagueID: String, seasonID: Int) async throws {
        let key = ESPNFantasyConnectionInput(sport: sport, seasonID: seasonID, leagueID: leagueID, teamID: nil, scoringPeriodID: nil, matchupPeriodID: nil).connectionKey
        try await credentialStore.save(ESPNFantasyCredentials(espnS2: espnS2, swid: swid), for: key)
    }
}

actor ESPNFantasyRosterPlayerCache {
    static let shared = ESPNFantasyRosterPlayerCache()

    private var playersByLeagueID: [String: [String: FantasyPlayer]] = [:]

    func store(_ players: [String: FantasyPlayer], leagueID: String) {
        playersByLeagueID[leagueID] = players
    }

    func players() -> [String: FantasyPlayer] {
        playersByLeagueID.values.reduce(into: [:]) { partial, players in
            partial.merge(players) { current, _ in current }
        }
    }
}

struct ESPNFantasyClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    nonisolated init(
        baseURL: URL = URL(string: "https://lm-api-reads.fantasy.espn.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func league(
        gameCode: ESPNFantasyGameCode,
        seasonID: Int,
        leagueID: String,
        views: [ESPNFantasyView],
        scoringPeriodID: Int?,
        filter: ESPNFantasyFilter?,
        credentials: ESPNFantasyCredentials?
    ) async throws -> ESPNLeagueResponseDTO {
        let request = try request(
            gameCode: gameCode,
            seasonID: seasonID,
            leagueID: leagueID,
            views: views,
            scoringPeriodID: scoringPeriodID,
            filter: filter,
            credentials: credentials
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FantasyProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw FantasyProviderError.authenticationRequired }
            if http.statusCode == 404 { throw FantasyProviderError.leagueNotFound }
            throw FantasyProviderError.httpError(http.statusCode)
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type"), !contentType.localizedCaseInsensitiveContains("json") {
            throw FantasyProviderError.suspiciousResponse
        }
        if data.prefix(32).contains(60) {
            throw FantasyProviderError.suspiciousResponse
        }
        if String(decoding: data.prefix(4096), as: UTF8.self).contains("AUTH_LEAGUE_NOT_VISIBLE") {
            throw FantasyProviderError.authenticationRequired
        }
        let decoder = JSONDecoder()
        return try decoder.decode(ESPNLeagueResponseDTO.self, from: data)
    }

    func request(
        gameCode: ESPNFantasyGameCode,
        seasonID: Int,
        leagueID: String,
        views: [ESPNFantasyView],
        scoringPeriodID: Int?,
        filter: ESPNFantasyFilter?,
        credentials: ESPNFantasyCredentials?
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/apis/v3/games/\(gameCode.rawValue)/seasons/\(seasonID)/segments/0/leagues/\(leagueID)"
        var items = views.map { URLQueryItem(name: "view", value: $0.rawValue) }
        if let scoringPeriodID {
            items.append(URLQueryItem(name: "scoringPeriodId", value: String(scoringPeriodID)))
        }
        components.queryItems = items
        guard let url = components.url else { throw FantasyProviderError.invalidIdentifier }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let filter {
            request.setValue(try filter.headerValue(), forHTTPHeaderField: "X-Fantasy-Filter")
        }
        if let credentials {
            request.setValue(credentials.cookieHeaderValue, forHTTPHeaderField: "Cookie")
        }
        return request
    }
}

enum ESPNFantasyGameCode: String, Codable, CaseIterable, Sendable {
    case football = "ffl"
    case hockey = "fhl"
    case basketball = "fba"
    case baseball = "flb"

    nonisolated var sport: FantasySport {
        switch self {
        case .football: return .nfl
        case .hockey: return .nhl
        case .basketball: return .nba
        case .baseball: return .mlb
        }
    }

    init?(sport: FantasySport) {
        switch sport {
        case .nfl: self = .football
        case .nhl: self = .hockey
        case .nba: self = .basketball
        case .mlb: self = .baseball
        }
    }

    init?(token: String) {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "ffl", "nfl", "football": self = .football
        case "fhl", "nhl", "hockey": self = .hockey
        case "fba", "nba", "basketball": self = .basketball
        case "flb", "mlb", "baseball": self = .baseball
        default: return nil
        }
    }
}

enum ESPNFantasyView: String, Sendable {
    case settings = "mSettings"
    case team = "mTeam"
    case roster = "mRoster"
    case status = "mStatus"
    case matchupScore = "mMatchupScore"
    case scoreboard = "mScoreboard"
    case standings = "mStandings"
    case schedule = "mSchedule"
    case boxscore = "mBoxscore"
    case liveScoring = "mLiveScoring"
    case playerInfo = "kona_player_info"
    case playerCard = "kona_playercard"
}

enum ESPNFantasyFilter: Sendable {
    case matchupPeriods([Int])
    case playerIDs([Int])

    func headerValue() throws -> String {
        let object: [String: Any]
        switch self {
        case .matchupPeriods(let ids):
            object = ["schedule": ["filterMatchupPeriodIds": ["value": ids]]]
        case .playerIDs(let ids):
            object = ["players": ["filterIds": ["value": ids]]]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return String(decoding: data, as: UTF8.self)
    }
}

struct ESPNFantasyCredentials: Codable, Hashable, Sendable {
    let espnS2: String
    let swid: String

    var normalizedSWID: String {
        ESPNFantasyMapper.normalizeSWID(swid)
    }

    var cookieHeaderValue: String {
        "espn_s2=\(espnS2); SWID=\(swid)"
    }
}

struct ESPNFantasyCredentialStore: Sendable {
    private let service = "com.alexdiab.StadiaTV.fantasy.espn"

    nonisolated init() {}

    func save(_ credentials: ESPNFantasyCredentials, for key: String) async throws {
        let data = try JSONEncoder().encode(credentials)
        deleteCredentialsSync(for: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStore.KeychainError.unhandledStatus(status) }
    }

    func credentials(for key: String) async -> ESPNFantasyCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ESPNFantasyCredentials.self, from: data)
    }

    func deleteCredentials(for key: String) async {
        deleteCredentialsSync(for: key)
    }

    private func deleteCredentialsSync(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct ESPNFantasyConnectionInput: Hashable, Sendable {
    let gameCode: ESPNFantasyGameCode
    let seasonID: Int
    let leagueID: String
    let teamID: Int?
    let scoringPeriodID: Int?
    let matchupPeriodID: Int?
    nonisolated var sport: FantasySport { gameCode.sport }

    init(gameCode: ESPNFantasyGameCode, seasonID: Int, leagueID: String, teamID: Int?, scoringPeriodID: Int?, matchupPeriodID: Int?) {
        self.gameCode = gameCode
        self.seasonID = seasonID
        self.leagueID = leagueID
        self.teamID = teamID
        self.scoringPeriodID = scoringPeriodID
        self.matchupPeriodID = matchupPeriodID
    }

    init(sport: FantasySport, seasonID: Int, leagueID: String, teamID: Int?, scoringPeriodID: Int?, matchupPeriodID: Int?) {
        self.init(gameCode: ESPNFantasyGameCode(sport: sport) ?? .hockey, seasonID: seasonID, leagueID: leagueID, teamID: teamID, scoringPeriodID: scoringPeriodID, matchupPeriodID: matchupPeriodID)
    }

    init(rawValue: String, now: Date) throws {
        let parts = rawValue
            .split { [":", ",", "|"].contains($0) }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw FantasyProviderError.invalidIdentifier }
        let defaultSeason = Calendar.current.component(.year, from: now)

        if parts.first == "espn" {
            try self.init(leagueIdentifier: parts.joined(separator: ":"))
            return
        }

        if let gameCode = ESPNFantasyGameCode(token: parts[0]) {
            guard parts.count >= 2 else { throw FantasyProviderError.invalidIdentifier }
            let leagueID = parts[1]
            let season = parts.dropFirst(2).first.flatMap(Int.init) ?? defaultSeason
            let team = parts.dropFirst(3).first.flatMap(Int.init)
            self.init(gameCode: gameCode, seasonID: season, leagueID: leagueID, teamID: team, scoringPeriodID: nil, matchupPeriodID: nil)
            return
        }

        let leagueID = parts[0]
        let season = parts.dropFirst().first.flatMap(Int.init) ?? defaultSeason
        let team = parts.dropFirst(2).first.flatMap(Int.init)
        self.init(gameCode: .hockey, seasonID: season, leagueID: leagueID, teamID: team, scoringPeriodID: nil, matchupPeriodID: nil)
    }

    init(connection: FantasyConnection) throws {
        try self.init(leagueIdentifier: connection.providerUserID)
    }

    init(leagueIdentifier: String) throws {
        let parts = leagueIdentifier.split(separator: ":").map(String.init)
        if parts.count >= 4, parts[0] == "espn", let gameCode = ESPNFantasyGameCode(token: parts[1]), let season = Int(parts[2]) {
            let team = parts.count > 4 ? Int(parts[4]) : nil
            let scoring = parts.count > 5 ? Int(parts[5]) : nil
            let matchup = parts.count > 6 ? Int(parts[6]) : nil
            self.init(gameCode: gameCode, seasonID: season, leagueID: parts[3], teamID: team, scoringPeriodID: scoring, matchupPeriodID: matchup)
            return
        }

        if parts.count >= 2, let season = Int(parts[1]) {
            let team = parts.count > 2 ? Int(parts[2]) : nil
            self.init(gameCode: .hockey, seasonID: season, leagueID: parts[0], teamID: team, scoringPeriodID: nil, matchupPeriodID: nil)
            return
        }

        throw FantasyProviderError.invalidIdentifier
    }

    nonisolated var connectionKey: String {
        "espn:\(gameCode.rawValue):\(seasonID):\(leagueID)"
    }

    nonisolated func connectionKeyWithTeam(_ teamID: Int?) -> String {
        guard let teamID else { return connectionKey }
        return "\(connectionKey):\(teamID)"
    }

    func with(matchupPeriodID: Int) -> ESPNFantasyConnectionInput {
        ESPNFantasyConnectionInput(gameCode: gameCode, seasonID: seasonID, leagueID: leagueID, teamID: teamID, scoringPeriodID: scoringPeriodID, matchupPeriodID: matchupPeriodID)
    }
}

// MARK: - DTOs

struct ESPNLeagueResponseDTO: Decodable, Sendable {
    let id: Int?
    let seasonID: Int?
    let scoringPeriodID: Int?
    let status: ESPNStatusDTO?
    let settings: ESPNSettingsDTO?
    let members: [ESPNMemberDTO]?
    let teams: [ESPNTeamDTO]?
    let schedule: [ESPNMatchupDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case seasonID = "seasonId"
        case scoringPeriodID = "scoringPeriodId"
        case status, settings, members, teams, schedule
    }
}

struct ESPNSettingsDTO: Decodable, Sendable {
    let name: String?
    let size: Int?
    let rosterSettings: ESPNRosterSettingsDTO?
    let scoringSettings: ESPNScoringSettingsDTO?
    let scheduleSettings: ESPNScheduleSettingsDTO?
}

struct ESPNRosterSettingsDTO: Decodable, Sendable {
    let lineupSlotCounts: [String: Int]?
}

struct ESPNScoringSettingsDTO: Decodable, Sendable {
    let scoringType: String?
    let scoringItems: [ESPNScoringItemDTO]?
}

struct ESPNScoringItemDTO: Decodable, Sendable {
    let statID: Int?
    let points: Double?
    let isReverseItem: Bool?

    enum CodingKeys: String, CodingKey {
        case statID = "statId"
        case points, isReverseItem
    }
}

struct ESPNScheduleSettingsDTO: Decodable, Sendable {
    let matchupPeriods: [String: [Int]]?
}

struct ESPNStatusDTO: Decodable, Sendable {
    let currentMatchupPeriod: Int?
    let latestScoringPeriod: Int?
    let firstScoringPeriod: Int?
    let finalScoringPeriod: Int?
    let isActive: Bool?
    let isExpired: Bool?
}

struct ESPNMemberDTO: Decodable, Sendable {
    let id: String?
    let displayName: String?
    let firstName: String?
    let lastName: String?
}

struct ESPNTeamDTO: Decodable, Sendable {
    let id: Int?
    let name: String?
    let location: String?
    let nickname: String?
    let abbrev: String?
    let owners: [String]?
    let record: ESPNTeamRecordDTO?
    let roster: ESPNRosterDTO?
}

struct ESPNTeamRecordDTO: Decodable, Sendable {
    let overall: ESPNRecordDTO?
}

struct ESPNRecordDTO: Decodable, Sendable {
    let wins: Int?
    let losses: Int?
    let ties: Int?
    let pointsFor: Double?
    let pointsAgainst: Double?
    let rankCalculatedFinal: Int?
    let rankFinal: Int?
    let standing: Int?
}

struct ESPNRosterDTO: Decodable, Sendable {
    let entries: [ESPNRosterEntryDTO]?
}

struct ESPNRosterEntryDTO: Decodable, Sendable {
    let lineupSlotID: Int?
    let playerID: Int?
    let playerPoolEntry: ESPNPlayerPoolEntryDTO?

    enum CodingKeys: String, CodingKey {
        case lineupSlotID = "lineupSlotId"
        case playerID = "playerId"
        case playerPoolEntry
    }
}

struct ESPNPlayerPoolEntryDTO: Decodable, Sendable {
    let appliedStatTotal: Double?
    let totalPoints: Double?
    let player: ESPNPlayerDTO?
}

struct ESPNPlayerDTO: Decodable, Sendable {
    let id: Int?
    let fullName: String?
    let firstName: String?
    let lastName: String?
    let active: Bool?
    let proTeamID: Int?
    let defaultPositionID: Int?
    let eligibleSlots: [Int]?
    let injuryStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, fullName, firstName, lastName, active, eligibleSlots, injuryStatus
        case proTeamID = "proTeamId"
        case defaultPositionID = "defaultPositionId"
    }
}

struct ESPNMatchupDTO: Decodable, Sendable {
    let id: Int?
    let matchupPeriodID: Int?
    let winner: String?
    let home: ESPNMatchupSideDTO?
    let away: ESPNMatchupSideDTO?

    enum CodingKeys: String, CodingKey {
        case id, winner, home, away
        case matchupPeriodID = "matchupPeriodId"
    }
}

struct ESPNMatchupSideDTO: Decodable, Sendable {
    let teamID: Int?
    let totalPoints: Double?
    let pointsByScoringPeriod: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case teamID = "teamId"
        case totalPoints, pointsByScoringPeriod
    }
}

// MARK: - Mapping

nonisolated enum ESPNFantasyMapper {
    static func seasonState(from response: ESPNLeagueResponseDTO, descriptor: ESPNFantasyConnectionInput) -> FantasySeasonState {
        FantasySeasonState(
            sport: descriptor.sport,
            season: String(response.seasonID ?? descriptor.seasonID),
            leagueSeason: String(response.seasonID ?? descriptor.seasonID),
            week: response.status?.currentMatchupPeriod,
            displayWeek: response.status?.currentMatchupPeriod,
            seasonType: response.status?.isActive == true ? "in_season" : "off_season",
            seasonStartDate: nil
        )
    }

    static func league(from response: ESPNLeagueResponseDTO, descriptor: ESPNFantasyConnectionInput) throws -> FantasyLeague {
        guard response.settings != nil || response.teams != nil else { throw FantasyProviderError.suspiciousResponse }
        let status = leagueStatus(from: response.status)
        let scoringType = response.settings?.scoringSettings?.scoringType
        let scoringValues = Dictionary(uniqueKeysWithValues: (response.settings?.scoringSettings?.scoringItems ?? []).compactMap { item in
            item.statID.map { ("espn.\(descriptor.gameCode.rawValue).stat.\($0)", item.points ?? 0) }
        })
        var metadata: [String: String] = [
            "gameCode": descriptor.gameCode.rawValue,
            "leagueID": descriptor.leagueID,
            "seasonID": String(descriptor.seasonID),
            "scoringType": scoringType,
            "currentMatchupPeriod": response.status?.currentMatchupPeriod.map(String.init),
            "latestScoringPeriod": response.status?.latestScoringPeriod.map(String.init)
        ].compactMapValues { $0 }
        if let teamID = descriptor.teamID { metadata["selectedTeamID"] = String(teamID) }
        return FantasyLeague(
            id: descriptor.connectionKeyWithTeam(descriptor.teamID),
            provider: .espn,
            sport: descriptor.sport,
            name: response.settings?.name ?? "ESPN Fantasy \(descriptor.sport.displayName)",
            season: String(response.seasonID ?? descriptor.seasonID),
            status: status,
            totalRosters: response.settings?.size ?? response.teams?.count,
            avatarID: nil,
            rosterPositions: rosterPositions(from: response.settings?.rosterSettings, descriptor: descriptor),
            scoringSettings: FantasyScoringSettings(values: scoringValues),
            providerMetadata: metadata
        )
    }

    static func teams(from response: ESPNLeagueResponseDTO, descriptor: ESPNFantasyConnectionInput) -> [FantasyTeam] {
        let membersByID = Dictionary(uniqueKeysWithValues: (response.members ?? []).compactMap { member in
            member.id.map { (normalizeSWID($0), member) }
        })
        return (response.teams ?? []).compactMap { team in
            guard let id = team.id else { return nil }
            let owner = team.owners?.first.map(normalizeSWID(_:))
            let member = owner.flatMap { membersByID[$0] }
            return FantasyTeam(
                id: "\(descriptor.connectionKey)-\(id)",
                leagueID: descriptor.connectionKeyWithTeam(descriptor.teamID),
                providerUserID: owner,
                rosterID: id,
                displayName: teamDisplayName(team),
                username: member?.displayName,
                avatarID: nil,
                isOwner: descriptor.teamID == id
            )
        }
    }

    static func rosters(from response: ESPNLeagueResponseDTO, descriptor: ESPNFantasyConnectionInput, teams: [FantasyTeam]) -> [FantasyRoster] {
        let teamByID = Dictionary(uniqueKeysWithValues: teams.compactMap { team in team.rosterID.map { ($0, team) } })
        return (response.teams ?? []).compactMap { team in
            guard let id = team.id else { return nil }
            let slots = (team.roster?.entries ?? []).compactMap { entry -> FantasyRosterSlot? in
                guard let player = entry.playerPoolEntry?.player, let playerID = player.id else { return nil }
                let slotID = entry.lineupSlotID ?? ESPNFantasyPositionMapper.benchSlotID(for: descriptor.sport)
                return FantasyRosterSlot(
                    id: "\(descriptor.connectionKey)-\(id)-\(playerID)-\(slotID)",
                    playerID: String(playerID),
                    kind: ESPNFantasyPositionMapper.slotKind(for: slotID, sport: descriptor.sport),
                    lineupPosition: ESPNFantasyPositionMapper.abbreviation(for: slotID, sport: descriptor.sport),
                    fantasyPoints: entry.playerPoolEntry?.appliedStatTotal ?? entry.playerPoolEntry?.totalPoints,
                    projectedPoints: nil
                )
            }
            return FantasyRoster(
                id: "\(descriptor.connectionKey)-\(id)",
                leagueID: descriptor.connectionKeyWithTeam(descriptor.teamID),
                rosterID: id,
                ownerUserID: team.owners?.first.map(normalizeSWID(_:)),
                team: teamByID[id],
                slots: slots,
                record: fantasyRecord(from: team.record?.overall),
                waiverPosition: nil,
                waiverBudgetUsed: nil,
                totalMoves: nil
            )
        }
    }

    static func matchup(from response: ESPNLeagueResponseDTO, descriptor: ESPNFantasyConnectionInput, userTeamID: Int, teams: [FantasyTeam]) -> FantasyMatchup? {
        guard let schedule = response.schedule else { return nil }
        let teamsByID = Dictionary(uniqueKeysWithValues: teams.compactMap { team in team.rosterID.map { ($0, team) } })
        guard let matchup = schedule.first(where: { $0.home?.teamID == userTeamID || $0.away?.teamID == userTeamID }) else { return nil }
        let userSide = matchup.home?.teamID == userTeamID ? matchup.home : matchup.away
        let opponentSide = matchup.home?.teamID == userTeamID ? matchup.away : matchup.home
        guard let user = userSide, let rosterID = user.teamID else { return nil }
        return FantasyMatchup(
            id: "\(descriptor.connectionKey)-\(matchup.matchupPeriodID ?? descriptor.matchupPeriodID ?? 0)-\(userTeamID)",
            leagueID: descriptor.connectionKeyWithTeam(descriptor.teamID),
            week: matchup.matchupPeriodID ?? descriptor.matchupPeriodID ?? 0,
            matchupID: matchup.id,
            userTeam: matchupTeam(from: user, leagueID: descriptor.connectionKeyWithTeam(descriptor.teamID), team: teamsByID[rosterID]),
            opponentTeam: opponentSide.map { side in matchupTeam(from: side, leagueID: descriptor.connectionKeyWithTeam(descriptor.teamID), team: side.teamID.flatMap { teamsByID[$0] }) }
        )
    }

    static func standings(from response: ESPNLeagueResponseDTO, descriptor: ESPNFantasyConnectionInput) -> [FantasyStanding] {
        let teams = self.teams(from: response, descriptor: descriptor)
        let teamsByID = Dictionary(uniqueKeysWithValues: teams.compactMap { team in team.rosterID.map { ($0, team) } })
        return (response.teams ?? []).compactMap { team in
            guard let id = team.id, let record = fantasyRecord(from: team.record?.overall) else { return nil }
            return FantasyStanding(
                id: "\(descriptor.connectionKey)-standing-\(id)",
                leagueID: descriptor.connectionKeyWithTeam(descriptor.teamID),
                rosterID: id,
                team: teamsByID[id],
                record: record,
                rank: team.record?.overall?.rankFinal ?? team.record?.overall?.rankCalculatedFinal ?? team.record?.overall?.standing
            )
        }.sorted { ($0.rank ?? Int.max) < ($1.rank ?? Int.max) }
    }

    static func standingFromRoster(_ roster: FantasyRoster) -> FantasyStanding? {
        guard let record = roster.record else { return nil }
        return FantasyStanding(id: "\(roster.leagueID)-standing-\(roster.rosterID)", leagueID: roster.leagueID, rosterID: roster.rosterID, team: roster.team, record: record, rank: nil)
    }

    static func players(from response: ESPNLeagueResponseDTO, descriptor: ESPNFantasyConnectionInput) -> [String: FantasyPlayer] {
        var output: [String: FantasyPlayer] = [:]
        for team in response.teams ?? [] {
            for entry in team.roster?.entries ?? [] {
                guard let player = entry.playerPoolEntry?.player, let id = player.id else { continue }
                output[String(id)] = FantasyPlayer(
                    id: String(id),
                    provider: .espn,
                    sport: descriptor.sport,
                    firstName: player.firstName,
                    lastName: player.lastName,
                    fullName: player.fullName ?? [player.firstName, player.lastName].compactMap { $0 }.joined(separator: " "),
                    teamAbbreviation: ESPNFantasyTeamResolver.shared.abbreviation(for: player.proTeamID, sport: descriptor.sport),
                    position: player.defaultPositionID.flatMap { ESPNFantasyPositionMapper.positionAbbreviation(for: $0, sport: descriptor.sport) },
                    fantasyPositions: (player.eligibleSlots ?? []).compactMap { ESPNFantasyPositionMapper.abbreviation(for: $0, sport: descriptor.sport) },
                    status: player.active == false ? "Inactive" : "Active",
                    injuryStatus: player.injuryStatus,
                    jerseyNumber: nil,
                    externalIDs: FantasyPlayerExternalIDs(espnID: String(id), sportradarID: nil, yahooID: nil, fantasyDataID: nil, statsID: nil, rotowireID: nil)
                )
            }
        }
        return output
    }

    static func ownerTeamID(from response: ESPNLeagueResponseDTO, swid: String) -> Int? {
        response.teams?.first { team in
            team.owners?.map(normalizeSWID(_:)).contains(swid) == true
        }?.id
    }

    static func normalizeSWID(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).lowercased()
    }

    private static func leagueStatus(from status: ESPNStatusDTO?) -> FantasyLeagueStatus {
        if status?.isExpired == true { return .complete }
        if status?.isActive == true { return .inSeason }
        return .offSeason
    }

    private static func rosterPositions(from settings: ESPNRosterSettingsDTO?, descriptor: ESPNFantasyConnectionInput) -> [String] {
        (settings?.lineupSlotCounts ?? [:])
            .compactMap { key, count -> String? in Int(key).flatMap { ESPNFantasyPositionMapper.abbreviation(for: $0, sport: descriptor.sport) }.map { "\($0):\(count)" } }
            .sorted()
    }

    private static func fantasyRecord(from record: ESPNRecordDTO?) -> FantasyRecord? {
        guard let record else { return nil }
        return FantasyRecord(wins: record.wins, losses: record.losses, ties: record.ties, pointsFor: record.pointsFor, pointsAgainst: record.pointsAgainst)
    }

    private static func teamDisplayName(_ team: ESPNTeamDTO) -> String {
        if let name = team.name, !name.isEmpty { return name }
        let combined = [team.location, team.nickname].compactMap { $0 }.joined(separator: " ")
        return combined.isEmpty ? "ESPN Team \(team.id.map(String.init) ?? "")" : combined
    }

    private static func matchupTeam(from side: ESPNMatchupSideDTO, leagueID: String, team: FantasyTeam?) -> FantasyMatchupTeam {
        let rosterID = side.teamID ?? -1
        return FantasyMatchupTeam(
            id: "\(leagueID)-matchup-\(rosterID)",
            rosterID: rosterID,
            team: team,
            starters: [],
            players: [],
            points: side.totalPoints,
            customPoints: nil
        )
    }
}

nonisolated enum ESPNFantasyPositionMapper {
    static func benchSlotID(for sport: FantasySport) -> Int {
        switch sport {
        case .nfl: return 20
        case .nhl: return 7
        case .nba: return 12
        case .mlb: return 13
        }
    }

    static func slotKind(for id: Int, sport: FantasySport) -> FantasyRosterSlotKind {
        switch abbreviation(for: id, sport: sport) {
        case "BN": return .bench
        case "IR", "IL": return .reserve
        default: return .starter
        }
    }

    static func abbreviation(for id: Int, sport: FantasySport) -> String? {
        switch sport {
        case .nfl:
            switch id {
            case 0: return "QB"
            case 2: return "RB"
            case 4: return "WR"
            case 6: return "TE"
            case 16: return "DST"
            case 17: return "K"
            case 20: return "BN"
            case 21: return "IR"
            case 23: return "FLEX"
            default: return "UNK\(id)"
            }
        case .nhl:
            switch id {
            case 0: return "C"
            case 1: return "LW"
            case 2: return "RW"
            case 3: return "F"
            case 4: return "D"
            case 5: return "G"
            case 6: return "UTIL"
            case 7: return "BN"
            case 8: return "IR"
            default: return "UNK\(id)"
            }
        case .nba:
            switch id {
            case 0: return "PG"
            case 1: return "SG"
            case 2: return "SF"
            case 3: return "PF"
            case 4: return "C"
            case 5: return "G"
            case 6: return "F"
            case 11: return "UTIL"
            case 12: return "BN"
            case 13: return "IR"
            default: return "UNK\(id)"
            }
        case .mlb:
            switch id {
            case 0: return "C"
            case 1: return "1B"
            case 2: return "2B"
            case 3: return "3B"
            case 4: return "SS"
            case 5: return "OF"
            case 10: return "UTIL"
            case 11: return "P"
            case 13: return "BN"
            case 14: return "IL"
            case 15: return "SP"
            case 16: return "RP"
            default: return "UNK\(id)"
            }
        }
    }

    static func positionAbbreviation(for id: Int, sport: FantasySport) -> String? {
        abbreviation(for: id, sport: sport)
    }
}

typealias ESPNHockeyPositionMapper = ESPNFantasyPositionMapper

nonisolated final class ESPNFantasyTeamResolver: @unchecked Sendable {
    static let shared = ESPNFantasyTeamResolver()

    private let lock = NSLock()
    private var abbreviationsBySportAndProTeamID: [String: [Int: String]] = [:]

    nonisolated init() {}

    func updateMappings(_ mappings: [Int: String], sport: FantasySport = .nhl) {
        lock.lock()
        var existing = abbreviationsBySportAndProTeamID[sport.rawValue] ?? [:]
        existing.merge(mappings) { _, new in new }
        abbreviationsBySportAndProTeamID[sport.rawValue] = existing
        lock.unlock()
    }

    func abbreviation(for proTeamID: Int?, sport: FantasySport) -> String? {
        guard let proTeamID else { return nil }
        lock.lock()
        let value = abbreviationsBySportAndProTeamID[sport.rawValue]?[proTeamID]
        lock.unlock()
        return value
    }
}

typealias ESPNHockeyTeamResolver = ESPNFantasyTeamResolver
