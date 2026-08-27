import Foundation

struct SleeperFantasyService: FantasyProviderService {
    let provider: FantasyProvider = .sleeper
    let capabilities = FantasyProviderCapabilities.readOnlyCore

    private let baseURL: URL
    private let session: URLSession
    private let persistence: FantasyPersistenceStore
    private let cachePolicy: FantasyCachePolicy
    private let directoryDeduplicator = SharedRequestDeduplicator<String, CachedFantasyPlayerDirectory>()

    nonisolated init(
        baseURL: URL = URL(string: "https://api.sleeper.app/v1")!,
        session: URLSession = .shared,
        persistence: FantasyPersistenceStore = .shared,
        cachePolicy: FantasyCachePolicy = FantasyCachePolicy()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.persistence = persistence
        self.cachePolicy = cachePolicy
    }

    func connect(usernameOrUserID: String) async throws -> FantasyConnection {
        let identifier = usernameOrUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw FantasyProviderError.invalidIdentifier }
        let dto = try await fetch(SleeperUserDTO.self, path: "user/\(identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier)", notFoundError: .userNotFound)
        guard let userID = dto.userID, !userID.isEmpty else { throw FantasyProviderError.userNotFound }
        return dto.toConnection(connectedAt: Date())
    }

    func currentSeasonState(for connection: FantasyConnection) async throws -> FantasySeasonState {
        try await fetch(SleeperNFLStateDTO.self, path: "state/nfl").toDomain()
    }

    func leagues(for connection: FantasyConnection, season: String) async throws -> [FantasyLeague] {
        try await fetch([SleeperLeagueDTO].self, path: "user/\(connection.providerUserID)/leagues/nfl/\(season)")
            .compactMap { $0.toDomain(defaultSport: .nfl) }
    }

    func league(id: String) async throws -> FantasyLeague {
        guard let league = try await fetch(SleeperLeagueDTO.self, path: "league/\(id)").toDomain(defaultSport: .nfl) else {
            throw FantasyProviderError.badResponse
        }
        return league
    }

    func leagueUsers(leagueID: String) async throws -> [FantasyTeam] {
        try await fetch([SleeperLeagueUserDTO].self, path: "league/\(leagueID)/users")
            .compactMap { $0.toTeam(leagueID: leagueID, rosterID: nil) }
    }

    func leagueRosters(leagueID: String, teams: [FantasyTeam]) async throws -> [FantasyRoster] {
        let usersByID = Dictionary(uniqueKeysWithValues: teams.compactMap { team in
            team.providerUserID.map { ($0, team) }
        })
        return try await fetch([SleeperRosterDTO].self, path: "league/\(leagueID)/rosters")
            .compactMap { $0.toRoster(leagueID: leagueID, team: $0.ownerID.flatMap { usersByID[$0] }) }
    }

    func userRoster(in rosters: [FantasyRoster], connection: FantasyConnection) -> FantasyRoster? {
        rosters.first { $0.ownerUserID == connection.providerUserID }
    }

    func matchup(leagueID: String, week: Int, userRosterID: Int, teams: [FantasyTeam]) async throws -> FantasyMatchup? {
        let entries = try await fetch([SleeperMatchupDTO].self, path: "league/\(leagueID)/matchups/\(week)")
        guard let userEntry = entries.first(where: { $0.rosterID == userRosterID }) else { return nil }
        let opponentEntry = entries.first { entry in
            entry.rosterID != userRosterID && entry.matchupID != nil && entry.matchupID == userEntry.matchupID
        }
        let teamsByRosterID = Dictionary(uniqueKeysWithValues: teams.compactMap { team in
            team.rosterID.map { ($0, team) }
        })
        let userTeam = userEntry.toTeam(leagueID: leagueID, team: teamsByRosterID[userRosterID])
        return FantasyMatchup(
            id: "\(leagueID)-\(week)-\(userRosterID)",
            leagueID: leagueID,
            week: week,
            matchupID: userEntry.matchupID,
            userTeam: userTeam,
            opponentTeam: opponentEntry.map { $0.toTeam(leagueID: leagueID, team: $0.rosterID.flatMap { teamsByRosterID[$0] }) }
        )
    }

    func standings(leagueID: String, rosters: [FantasyRoster]) async throws -> [FantasyStanding] {
        rosters.map { roster in
            FantasyStanding(
                id: "\(leagueID)-\(roster.rosterID)",
                leagueID: leagueID,
                rosterID: roster.rosterID,
                team: roster.team,
                record: roster.record ?? FantasyRecord(wins: nil, losses: nil, ties: nil, pointsFor: nil, pointsAgainst: nil),
                rank: nil
            )
        }
        .sorted { lhs, rhs in
            let leftWins = lhs.record.wins ?? -1
            let rightWins = rhs.record.wins ?? -1
            if leftWins != rightWins { return leftWins > rightWins }
            return (lhs.record.pointsFor ?? -1) > (rhs.record.pointsFor ?? -1)
        }
        .enumerated()
        .map { offset, standing in
            FantasyStanding(id: standing.id, leagueID: standing.leagueID, rosterID: standing.rosterID, team: standing.team, record: standing.record, rank: offset + 1)
        }
    }

    func players(ids: Set<String>, sport: FantasySport) async throws -> [String: FantasyPlayer] {
        let directory = try await playerDirectory(sport: sport)
        if ids.isEmpty { return directory.playersByID }
        return directory.playersByID.filter { ids.contains($0.key) }
    }

    func disconnect(connection: FantasyConnection) async {
        await persistence.removeSleeperConnectionAndCaches()
    }

    func refreshCachedData() async {}

    func playerDirectory(sport: FantasySport, force: Bool = false) async throws -> CachedFantasyPlayerDirectory {
        if !force,
           let cached = await persistence.loadPlayerDirectory(provider: .sleeper, sport: sport),
           cachePolicy.isFresh(cached.fetchedAt, lifetime: cachePolicy.playerDirectoryTTL) {
            return cached
        }

        return try await directoryDeduplicator.value(for: sport.rawValue) {
            if !force,
               let cached = await persistence.loadPlayerDirectory(provider: .sleeper, sport: sport),
               cachePolicy.isFresh(cached.fetchedAt, lifetime: cachePolicy.playerDirectoryTTL) {
                return cached
            }
            let dto = try await fetch([String: SleeperPlayerDTO].self, path: "players/\(sport.rawValue)")
            let players = dto.compactMapValues { $0.toDomain() }
            let directory = CachedFantasyPlayerDirectory(provider: .sleeper, sport: sport, fetchedAt: Date(), playersByID: players)
            await persistence.savePlayerDirectory(directory, provider: .sleeper, sport: sport)
            return directory
        }
    }

    private func fetch<T: Decodable>(_ type: T.Type, path: String, notFoundError: FantasyProviderError = .httpError(404)) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw FantasyProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 { throw notFoundError }
            throw FantasyProviderError.httpError(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Sleeper DTOs

struct SleeperUserDTO: Decodable {
    let username: String?
    let userID: String?
    let displayName: String?
    let avatar: String?

    enum CodingKeys: String, CodingKey {
        case username
        case userID = "user_id"
        case displayName = "display_name"
        case avatar
    }

    nonisolated func toConnection(connectedAt: Date) -> FantasyConnection {
        FantasyConnection(
            provider: .sleeper,
            providerUserID: userID ?? "",
            username: username,
            displayName: displayName,
            avatarID: avatar,
            connectedAt: connectedAt,
            refreshedAt: Date()
        )
    }
}

struct SleeperNFLStateDTO: Decodable {
    let week: Int?
    let seasonType: String?
    let seasonStartDate: String?
    let season: String?
    let leagueSeason: String?
    let displayWeek: Int?

    enum CodingKeys: String, CodingKey {
        case week
        case seasonType = "season_type"
        case seasonStartDate = "season_start_date"
        case season
        case leagueSeason = "league_season"
        case displayWeek = "display_week"
    }

    nonisolated func toDomain() -> FantasySeasonState {
        FantasySeasonState(
            sport: .nfl,
            season: season ?? leagueSeason ?? String(Calendar.current.component(.year, from: Date())),
            leagueSeason: leagueSeason,
            week: week,
            displayWeek: displayWeek,
            seasonType: seasonType,
            seasonStartDate: seasonStartDate.flatMap(Self.dateFormatter.date(from:))
        )
    }

    nonisolated static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

struct SleeperLeagueDTO: Decodable {
    let totalRosters: Int?
    let status: String?
    let sport: String?
    let seasonType: String?
    let season: String?
    let scoringSettings: [String: Double]?
    let rosterPositions: [String]?
    let previousLeagueID: String?
    let name: String?
    let leagueID: String?
    let draftID: String?
    let avatar: String?

    enum CodingKeys: String, CodingKey {
        case totalRosters = "total_rosters"
        case status, sport
        case seasonType = "season_type"
        case season
        case scoringSettings = "scoring_settings"
        case rosterPositions = "roster_positions"
        case previousLeagueID = "previous_league_id"
        case name
        case leagueID = "league_id"
        case draftID = "draft_id"
        case avatar
    }

    nonisolated func toDomain(defaultSport: FantasySport) -> FantasyLeague? {
        guard let leagueID else { return nil }
        return FantasyLeague(
            id: leagueID,
            provider: .sleeper,
            sport: defaultSport,
            name: name ?? "Sleeper League",
            season: season ?? "",
            status: FantasyLeagueStatus(sleeperStatus: status),
            totalRosters: totalRosters,
            avatarID: avatar,
            rosterPositions: rosterPositions ?? [],
            scoringSettings: FantasyScoringSettings(values: scoringSettings ?? [:]),
            providerMetadata: [
                "seasonType": seasonType,
                "previousLeagueID": previousLeagueID,
                "draftID": draftID
            ].compactMapValues { $0 }
        )
    }
}

struct SleeperLeagueUserDTO: Decodable {
    let userID: String?
    let username: String?
    let displayName: String?
    let avatar: String?
    let metadata: [String: String]?
    let isOwner: Bool?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case username
        case displayName = "display_name"
        case avatar, metadata
        case isOwner = "is_owner"
    }

    nonisolated func toTeam(leagueID: String, rosterID: Int?) -> FantasyTeam? {
        guard let userID else { return nil }
        let teamName = metadata?["team_name"]
            ?? metadata?["teamName"]
            ?? displayName
            ?? username
            ?? "Sleeper Team"
        return FantasyTeam(
            id: "\(leagueID)-\(rosterID.map(String.init) ?? userID)",
            leagueID: leagueID,
            providerUserID: userID,
            rosterID: rosterID,
            displayName: teamName,
            username: username,
            avatarID: avatar,
            isOwner: isOwner ?? false
        )
    }
}

struct SleeperRosterDTO: Decodable {
    let starters: [String]?
    let settings: [String: Double]?
    let rosterID: Int?
    let reserve: [String]?
    let players: [String]?
    let ownerID: String?
    let leagueID: String?

    enum CodingKeys: String, CodingKey {
        case starters, settings
        case rosterID = "roster_id"
        case reserve, players
        case ownerID = "owner_id"
        case leagueID = "league_id"
    }

    nonisolated func toRoster(leagueID fallbackLeagueID: String, team: FantasyTeam?) -> FantasyRoster? {
        guard let rosterID else { return nil }
        let leagueID = leagueID ?? fallbackLeagueID
        let starterIDs = starters ?? []
        let reserveIDs = Set(reserve ?? [])
        let allPlayerIDs = players ?? []
        let slots = allPlayerIDs.map { playerID -> FantasyRosterSlot in
            let kind: FantasyRosterSlotKind
            if starterIDs.contains(playerID) { kind = .starter }
            else if reserveIDs.contains(playerID) { kind = .reserve }
            else { kind = .bench }
            let lineupPosition = starterIDs.firstIndex(of: playerID).map { "STARTER_\($0 + 1)" }
            return FantasyRosterSlot(
                id: "\(leagueID)-\(rosterID)-\(playerID)",
                playerID: playerID,
                kind: kind,
                lineupPosition: lineupPosition,
                fantasyPoints: nil,
                projectedPoints: nil
            )
        }
        let updatedTeam = team.map {
            FantasyTeam(id: "\(leagueID)-\(rosterID)", leagueID: leagueID, providerUserID: $0.providerUserID, rosterID: rosterID, displayName: $0.displayName, username: $0.username, avatarID: $0.avatarID, isOwner: $0.isOwner)
        }
        return FantasyRoster(
            id: "\(leagueID)-\(rosterID)",
            leagueID: leagueID,
            rosterID: rosterID,
            ownerUserID: ownerID,
            team: updatedTeam,
            slots: slots,
            record: FantasyRecord(
                wins: settings?["wins"].map(Int.init),
                losses: settings?["losses"].map(Int.init),
                ties: settings?["ties"].map(Int.init),
                pointsFor: settings?["fpts"].map { $0 + ((settings?["fpts_decimal"] ?? 0) / 100) },
                pointsAgainst: settings?["fpts_against"].map { $0 + ((settings?["fpts_against_decimal"] ?? 0) / 100) }
            ),
            waiverPosition: settings?["waiver_position"].map(Int.init),
            waiverBudgetUsed: settings?["waiver_budget_used"].map(Int.init),
            totalMoves: settings?["total_moves"].map(Int.init)
        )
    }
}

struct SleeperMatchupDTO: Decodable {
    let starters: [String]?
    let rosterID: Int?
    let players: [String]?
    let matchupID: Int?
    let points: Double?
    let customPoints: Double?

    enum CodingKeys: String, CodingKey {
        case starters
        case rosterID = "roster_id"
        case players
        case matchupID = "matchup_id"
        case points
        case customPoints = "custom_points"
    }

    nonisolated func toTeam(leagueID: String, team: FantasyTeam?) -> FantasyMatchupTeam {
        let rosterID = rosterID ?? -1
        return FantasyMatchupTeam(
            id: "\(leagueID)-\(rosterID)",
            rosterID: rosterID,
            team: team,
            starters: starters ?? [],
            players: players ?? [],
            points: points,
            customPoints: customPoints
        )
    }
}

struct SleeperPlayerDTO: Decodable {
    let playerID: String?
    let firstName: String?
    let lastName: String?
    let fullName: String?
    let searchFullName: String?
    let team: String?
    let position: String?
    let fantasyPositions: [String]?
    let status: String?
    let injuryStatus: String?
    let number: Int?
    let sport: String?
    let espnID: String?
    let sportradarID: String?
    let yahooID: String?
    let fantasyDataID: String?
    let statsID: String?
    let rotowireID: String?

    enum CodingKeys: String, CodingKey {
        case playerID = "player_id"
        case firstName = "first_name"
        case lastName = "last_name"
        case fullName = "full_name"
        case searchFullName = "search_full_name"
        case team, position
        case fantasyPositions = "fantasy_positions"
        case status
        case injuryStatus = "injury_status"
        case number, sport
        case espnID = "espn_id"
        case sportradarID = "sportradar_id"
        case yahooID = "yahoo_id"
        case fantasyDataID = "fantasy_data_id"
        case statsID = "stats_id"
        case rotowireID = "rotowire_id"
    }

    nonisolated func toDomain() -> FantasyPlayer? {
        guard let playerID else { return nil }
        let name = fullName ?? searchFullName ?? [firstName, lastName].compactMap { $0 }.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return FantasyPlayer(
            id: playerID,
            provider: .sleeper,
            sport: .nfl,
            firstName: firstName,
            lastName: lastName,
            fullName: name,
            teamAbbreviation: team,
            position: position,
            fantasyPositions: fantasyPositions ?? [],
            status: status,
            injuryStatus: injuryStatus,
            jerseyNumber: number.map(String.init),
            externalIDs: FantasyPlayerExternalIDs(
                espnID: espnID,
                sportradarID: sportradarID,
                yahooID: yahooID,
                fantasyDataID: fantasyDataID,
                statsID: statsID,
                rotowireID: rotowireID
            )
        )
    }
}

private extension FantasyLeagueStatus {
    nonisolated init(sleeperStatus: String?) {
        switch sleeperStatus {
        case "pre_draft": self = .preDraft
        case "drafting": self = .drafting
        case "in_season": self = .inSeason
        case "complete": self = .complete
        default: self = .unknown
        }
    }
}
