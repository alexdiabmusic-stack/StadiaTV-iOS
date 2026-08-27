import Foundation
import Testing
@testable import StadiaTV

@Suite("Fantasy foundation")
struct FantasyFoundationTests {
    @Test func sleeperUserDecodesAndMapsToConnection() throws {
        let data = Data("""
        {"username":"alex","user_id":"42","display_name":"Alex","avatar":"abc"}
        """.utf8)
        let dto = try JSONDecoder().decode(SleeperUserDTO.self, from: data)
        let connection = dto.toConnection(connectedAt: Date(timeIntervalSince1970: 1))
        #expect(connection.provider == .sleeper)
        #expect(connection.providerUserID == "42")
        #expect(connection.username == "alex")
        #expect(connection.avatarThumbnailURL?.absoluteString == "https://sleepercdn.com/avatars/thumbs/abc")
    }

    @Test func sleeperLeagueDecodesAndPreservesScoring() throws {
        let data = Data("""
        {"total_rosters":12,"status":"in_season","sport":"nfl","season":"2026","scoring_settings":{"rec":1,"pass_td":4},"roster_positions":["QB","RB","FLEX"],"name":"Work League","league_id":"L1"}
        """.utf8)
        let league = try #require(JSONDecoder().decode(SleeperLeagueDTO.self, from: data).toDomain(defaultSport: .nfl))
        #expect(league.status == .inSeason)
        #expect(league.scoringSettings.values["rec"] == 1)
        #expect(league.rosterPositions == ["QB", "RB", "FLEX"])
    }

    @Test func sleeperStateUsesDisplayWeekAndLeagueSeason() throws {
        let data = Data("""
        {"week":3,"display_week":2,"season_type":"regular","season":"2026","league_season":"2026","season_start_date":"2026-09-10"}
        """.utf8)
        let state = try JSONDecoder().decode(SleeperNFLStateDTO.self, from: data).toDomain()
        #expect(state.activeWeek == 2)
        #expect(state.seasonForLeagueLookup == "2026")
    }

    @Test func rosterMappingFindsOwnerAndSlotKinds() throws {
        let users = [FantasyTeam(id: "L1-U1", leagueID: "L1", providerUserID: "U1", rosterID: nil, displayName: "Team Alex", username: "alex", avatarID: nil, isOwner: true)]
        let data = Data("""
        [{"starters":["p1"],"settings":{"wins":4,"losses":2,"ties":1,"fpts":812,"fpts_decimal":45},"roster_id":7,"reserve":["p3"],"players":["p1","p2","p3"],"owner_id":"U1","league_id":"L1"}]
        """.utf8)
        let service = SleeperFantasyService()
        let rosters = try JSONDecoder().decode([SleeperRosterDTO].self, from: data).compactMap { $0.toRoster(leagueID: "L1", team: users[0]) }
        let connection = FantasyConnection(provider: .sleeper, providerUserID: "U1", username: nil, displayName: nil, avatarID: nil, connectedAt: Date(), refreshedAt: nil)
        let owned = try #require(service.userRoster(in: rosters, connection: connection))
        #expect(owned.rosterID == 7)
        #expect(owned.record?.pointsFor == 812.45)
        #expect(owned.slots.first { $0.playerID == "p1" }?.kind == .starter)
        #expect(owned.slots.first { $0.playerID == "p2" }?.kind == .bench)
        #expect(owned.slots.first { $0.playerID == "p3" }?.kind == .reserve)
    }

    @Test func matchupPairingIdentifiesOpponentAndCustomPoints() throws {
        let entries = try JSONDecoder().decode([SleeperMatchupDTO].self, from: Data("""
        [
          {"starters":["p1"],"roster_id":1,"players":["p1","p2"],"matchup_id":10,"points":11.5},
          {"starters":["p3"],"roster_id":2,"players":["p3"],"matchup_id":10,"points":14,"custom_points":20}
        ]
        """.utf8))
        let teams = [
            FantasyTeam(id: "L1-1", leagueID: "L1", providerUserID: "U1", rosterID: 1, displayName: "One", username: nil, avatarID: nil, isOwner: false),
            FantasyTeam(id: "L1-2", leagueID: "L1", providerUserID: "U2", rosterID: 2, displayName: "Two", username: nil, avatarID: nil, isOwner: false)
        ]
        let teamsByRosterID = Dictionary(uniqueKeysWithValues: teams.map { ($0.rosterID!, $0) })
        let user = try #require(entries.first { $0.rosterID == 1 })
        let opponent = try #require(entries.first { $0.rosterID == 2 })
        let matchup = FantasyMatchup(id: "L1-1", leagueID: "L1", week: 1, matchupID: user.matchupID, userTeam: user.toTeam(leagueID: "L1", team: teamsByRosterID[1]), opponentTeam: opponent.toTeam(leagueID: "L1", team: teamsByRosterID[2]))
        #expect(matchup.opponentTeam?.team?.displayName == "Two")
        #expect(matchup.opponentTeam?.effectivePoints == 20)
    }

    @Test func playerDirectorySubsetDecodesExternalIDs() throws {
        let data = Data("""
        {"4046":{"player_id":"4046","first_name":"Patrick","last_name":"Mahomes","team":"KC","position":"QB","fantasy_positions":["QB"],"status":"Active","espn_id":"3139477","sport":"nfl"}}
        """.utf8)
        let players = try JSONDecoder().decode([String: SleeperPlayerDTO].self, from: data).compactMapValues { $0.toDomain() }
        #expect(players["4046"]?.externalIDs.espnID == "3139477")
        #expect(players["4046"]?.fullName == "Patrick Mahomes")
    }

    @Test func resolverUsesPersistedExternalNameAndAmbiguousRules() async throws {
        let suite = try #require(UserDefaults(suiteName: "FantasyResolverTests-\(UUID().uuidString)"))
        let persistence = FantasyPersistenceStore(defaults: suite)
        let resolver = FantasyPlayerResolver(persistence: persistence)
        let known = [
            StadiaPlayerIdentity(id: "espn:1", leaguePath: "football/nfl", displayName: "Exact One", teamAbbreviation: "KC", position: "QB", espnAthleteID: "1", source: "test"),
            StadiaPlayerIdentity(id: "name:2", leaguePath: "football/nfl", displayName: "Jane Runner", teamAbbreviation: "KC", position: "RB", espnAthleteID: nil, source: "test"),
            StadiaPlayerIdentity(id: "amb:a", leaguePath: "football/nfl", displayName: "Chris Smith", teamAbbreviation: "KC", position: "WR", espnAthleteID: nil, source: "test"),
            StadiaPlayerIdentity(id: "amb:b", leaguePath: "football/nfl", displayName: "Kris Smith", teamAbbreviation: "KC", position: "WR", espnAthleteID: nil, source: "test")
        ]
        let players = [
            fantasyPlayer(id: "p1", name: "Exact One", team: "KC", position: "QB", espnID: "1"),
            fantasyPlayer(id: "p2", name: "Jane Runner", team: "KC", position: "RB"),
            fantasyPlayer(id: "p3", name: "Will Missing", team: "KC", position: "TE")
        ]
        let result = await resolver.resolve(players: players, knownStadiaPlayers: known)
        #expect(result["p1"]?.identity?.espnAthleteID == "1")
        #expect(result["p2"]?.identity?.displayName == "Jane Runner")
        if case .unresolved = result["p3"] {} else { Issue.record("Expected unresolved player") }

        let persisted = await persistence.loadMappings()
        #expect(persisted["p1"]?.espnAthleteID == "1")
    }

    @Test func eventAndIPTVLinkingUsesStadiaMatchAndSourceMatcher() async throws {
        let league = try #require(League.all.first { $0.path == "football/nfl" })
        let match = Match(
            id: "game1",
            league: league,
            date: Date().addingTimeInterval(600),
            name: "Kansas City Chiefs at Denver Broncos",
            shortName: "KC @ DEN",
            state: .pre,
            statusDetail: "Today 4:25 PM",
            home: TeamSide(displayName: "Denver Broncos", shortName: "Broncos", abbreviation: "DEN", logoURL: nil, score: nil, record: nil, isWinner: false, teamID: "7"),
            away: TeamSide(displayName: "Kansas City Chiefs", shortName: "Chiefs", abbreviation: "KC", logoURL: nil, score: nil, record: nil, isWinner: false, teamID: "12"),
            broadcasts: ["CBS"],
            venue: nil
        )
        let channel = Channel(id: "cbs", name: "US CBS Sports", streamURL: URL(string: "https://example.com/live.m3u8")!, logoURL: nil, group: "Sports", playlistID: UUID(), playlistName: "Local")
        let player = fantasyPlayer(id: "p1", name: "Patrick Mahomes", team: "KC", position: "QB", espnID: "3139477")
        let identity = StadiaPlayerIdentity(id: "espn:3139477", leaguePath: "football/nfl", displayName: "Patrick Mahomes", teamAbbreviation: "KC", position: "QB", espnAthleteID: "3139477", source: "test")
        let linker = FantasyEventLinker(nowProvider: { Date() })
        let games = await linker.linkPlayerGames(players: [player], resolutions: ["p1": .resolved(identity)], matchup: nil, channels: [channel], preferredLanguages: ["en"], knownMatches: [match])
        #expect(games.first?.gameState == .upcoming)
        #expect(games.first?.opponent?.abbreviation == "DEN")
        #expect(games.first?.watchAvailable == true)
        #expect(games.first?.matchedChannel?.channel.id == "cbs")
    }

    @Test func cacheFreshnessAndRequestDeduplicationWork() async throws {
        let policy = FantasyCachePolicy()
        #expect(policy.isFresh(Date(), lifetime: 60))
        #expect(!policy.isFresh(Date(timeIntervalSinceNow: -120), lifetime: 60))

        let deduplicator = SharedRequestDeduplicator<String, Int>()
        let counter = Counter()
        async let first = deduplicator.value(for: "same") {
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return 7
        }
        async let second = deduplicator.value(for: "same") {
            await counter.increment()
            return 8
        }
        let values = try await [first, second]
        #expect(values == [7, 7])
        #expect(await counter.value == 1)
    }

    @Test func guideLookupUsesPrecomputedChannelContext() async throws {
        let league = try #require(League.all.first { $0.path == "football/nfl" })
        let eventDate = Date()
        let match = Match(
            id: "guide-game",
            league: league,
            date: eventDate,
            name: "Kansas City Chiefs at Denver Broncos",
            shortName: "KC @ DEN",
            state: .live,
            statusDetail: "Q2",
            home: TeamSide(displayName: "Denver Broncos", shortName: "Broncos", abbreviation: "DEN", logoURL: nil, score: "7", record: nil, isWinner: false, teamID: "7"),
            away: TeamSide(displayName: "Kansas City Chiefs", shortName: "Chiefs", abbreviation: "KC", logoURL: nil, score: "10", record: nil, isWinner: false, teamID: "12"),
            broadcasts: ["CBS"],
            venue: nil
        )
        let channel = Channel(id: "cbs-guide", name: "CBS", streamURL: URL(string: "https://example.com/live.m3u8")!, logoURL: nil, group: "Sports", playlistID: UUID(), playlistName: "Local")
        let player = fantasyPlayer(id: "p1", name: "Patrick Mahomes", team: "KC", position: "QB", espnID: "3139477")
        let identity = StadiaPlayerIdentity(id: "espn:3139477", leaguePath: "football/nfl", displayName: "Patrick Mahomes", teamAbbreviation: "KC", position: "QB", espnAthleteID: "3139477", source: "test")
        let linker = FantasyEventLinker(nowProvider: { eventDate })
        let games = await linker.linkPlayerGames(players: [player], resolutions: ["p1": .resolved(identity)], matchup: nil, channels: [channel], preferredLanguages: ["en"], knownMatches: [match])
        #expect(games.first?.matchedChannel?.channel.id == "cbs-guide")
        #expect(games.first?.event?.id == "guide-game")
    }

    @Test @MainActor func storeRefreshLeagueSwitchOfflineAndDisconnectUseProviderAbstractions() async throws {
        let suite = try #require(UserDefaults(suiteName: "FantasyStoreTests-\(UUID().uuidString)"))
        let persistence = FantasyPersistenceStore(defaults: suite, cacheDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let leagueOne = fantasyLeague(id: "L1", name: "League One")
        let leagueTwo = fantasyLeague(id: "L2", name: "League Two")
        let roster = fantasyRoster(leagueID: "L1", rosterID: 1, ownerID: "U1", playerIDs: ["p1"])
        let player = fantasyPlayer(id: "p1", name: "Patrick Mahomes", team: "KC", position: "QB", espnID: "3139477")
        let provider = MockFantasyProviderService(leagues: [leagueOne, leagueTwo], rostersByLeagueID: ["L1": [roster], "L2": [fantasyRoster(leagueID: "L2", rosterID: 2, ownerID: "U1", playerIDs: ["p1"])]], playersByID: ["p1": player])
        let linker = MockFantasyEventLinker(games: [FantasyPlayerGame(id: "p1-none", fantasyPlayer: player, stadiaPlayer: nil, event: nil, opponent: nil, gameState: .noGame, fantasyPoints: nil, projectedPoints: nil, matchedChannel: nil)])
        let store = FantasyStore(providerRegistry: FantasyProviderRegistry(services: [provider]), persistence: persistence, resolver: FantasyPlayerResolver(persistence: persistence), eventLinker: linker)

        await store.connect(provider: .sleeper, usernameOrUserID: "alex")
        #expect(store.currentConnection?.providerUserID == "U1")
        #expect(store.leagues.count == 2)
        #expect(store.selectedLeague?.id == "L1")
        #expect(store.playerGames.count == 1)

        await store.selectLeague(id: "L2")
        #expect(store.selectedLeague?.id == "L2")

        let failingStore = FantasyStore(providerRegistry: FantasyProviderRegistry(services: [MockFantasyProviderService(shouldFailSeason: true)]), persistence: persistence, resolver: FantasyPlayerResolver(persistence: persistence), eventLinker: linker)
        await failingStore.refresh(force: true)
        #expect(failingStore.isStale)
        #expect(failingStore.playerGames.count == 1)

        await store.disconnect()
        #expect(store.currentConnection == nil)
        #expect(store.playerGames.isEmpty)
    }

    @Test func playerDirectoryUsesFileBackedCacheAndMigratesLegacyDefaults() async throws {
        let suite = try #require(UserDefaults(suiteName: "FantasyFileCacheTests-\(UUID().uuidString)"))
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let persistence = FantasyPersistenceStore(defaults: suite, cacheDirectoryURL: cacheDirectory)
        let directory = CachedFantasyPlayerDirectory(provider: .sleeper, sport: .nfl, fetchedAt: Date(), playersByID: ["p1": fantasyPlayer(id: "p1", name: "Patrick Mahomes", team: "KC", position: "QB")])
        await persistence.savePlayerDirectory(directory, provider: .sleeper, sport: .nfl)
        let loaded = await persistence.loadPlayerDirectory(provider: .sleeper, sport: .nfl)
        #expect(loaded?.playersByID["p1"]?.fullName == "Patrick Mahomes")

        let legacyKey = "legacy.players"
        let legacyPersistence = FantasyPersistenceStore(defaults: suite, playerDirectoryKey: legacyKey, cacheDirectoryURL: cacheDirectory.appendingPathComponent("legacy", isDirectory: true))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        suite.set(try encoder.encode(directory), forKey: legacyKey)
        let migrated = await legacyPersistence.loadPlayerDirectory(provider: .sleeper, sport: .nfl)
        #expect(migrated?.playersByID["p1"]?.fullName == "Patrick Mahomes")
        #expect(suite.data(forKey: legacyKey) == nil)
    }

    @Test func accountSnapshotPersistsAndDisconnectClearsSleeperOnly() async throws {
        let suite = try #require(UserDefaults(suiteName: "FantasyAccountTests-\(UUID().uuidString)"))
        let persistence = FantasyPersistenceStore(defaults: suite)
        let connection = FantasyConnection(provider: .sleeper, providerUserID: "U1", username: "alex", displayName: "Alex", avatarID: nil, connectedAt: Date(), refreshedAt: nil)
        var snapshot = FantasyPersistentSnapshot()
        snapshot.connection = connection
        snapshot.settings.selectedLeagueID = "L1"
        await persistence.saveSnapshot(snapshot)
        #expect(await persistence.loadSnapshot().connection?.providerUserID == "U1")
        await persistence.removeSleeperConnectionAndCaches()
        let cleared = await persistence.loadSnapshot()
        #expect(cleared.connection == nil)
        #expect(cleared.settings.selectedLeagueID == nil)
    }

    @Test func espnFantasyRequestUsesFHLRepeatedViewsAndFilterHeader() throws {
        let client = ESPNFantasyClient(baseURL: URL(string: "https://lm-api-reads.fantasy.espn.com")!)
        let request = try client.request(
            gameCode: .hockey,
            seasonID: 2026,
            leagueID: "12345",
            views: [.matchupScore, .scoreboard],
            scoringPeriodID: 17,
            filter: .matchupPeriods([4]),
            credentials: ESPNFantasyCredentials(espnS2: "secret-token", swid: "{ABC}")
        )
        let url = try #require(request.url)
        #expect(url.path == "/apis/v3/games/fhl/seasons/2026/segments/0/leagues/12345")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "view" }.map(\.value) == ["mMatchupScore", "mScoreboard"])
        #expect(items.first { $0.name == "scoringPeriodId" }?.value == "17")
        #expect(request.value(forHTTPHeaderField: "X-Fantasy-Filter")?.contains("filterMatchupPeriodIds") == true)
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("espn_s2=") == true)
        #expect(url.absoluteString.contains("secret-token") == false)
    }

    @Test func espnLeagueRosterMatchupAndStandingsMapToFantasyDomain() throws {
        let json = Data("""
        {
          "id": 12345,
          "seasonId": 2026,
          "scoringPeriodId": 12,
          "status": {"currentMatchupPeriod": 4, "latestScoringPeriod": 12, "isActive": true, "isExpired": false},
          "settings": {
            "name": "Hockey League",
            "size": 2,
            "rosterSettings": {"lineupSlotCounts": {"0": 2, "4": 4, "5": 2, "7": 5, "8": 1}},
            "scoringSettings": {"scoringType": "H2H_POINTS", "scoringItems": [{"statId": 1, "points": 3.0}]},
            "scheduleSettings": {"matchupPeriods": {"4": [10, 11, 12]}}
          },
          "members": [{"id": "{OWNER}", "displayName": "Alex"}],
          "teams": [
            {"id": 1, "name": "Stadia Skaters", "abbrev": "STAD", "owners": ["{OWNER}"], "record": {"overall": {"wins": 3, "losses": 1, "ties": 0, "pointsFor": 240.5, "pointsAgainst": 220.0, "rankCalculatedFinal": 1}}, "roster": {"entries": [
              {"lineupSlotId": 0, "playerPoolEntry": {"appliedStatTotal": 12.5, "player": {"id": 3114, "fullName": "Auston Matthews", "firstName": "Auston", "lastName": "Matthews", "active": true, "proTeamId": 22, "defaultPositionId": 0, "eligibleSlots": [0, 3, 6], "injuryStatus": "ACTIVE"}}},
              {"lineupSlotId": 7, "playerPoolEntry": {"player": {"id": 3897, "fullName": "Connor McDavid", "active": true, "proTeamId": 6, "defaultPositionId": 0, "eligibleSlots": [0, 3, 6]}}}
            ]}},
            {"id": 2, "name": "Opponent", "owners": ["{OTHER}"], "record": {"overall": {"wins": 1, "losses": 3, "ties": 0, "pointsFor": 200.0, "pointsAgainst": 230.0, "rankCalculatedFinal": 2}}, "roster": {"entries": []}}
          ],
          "schedule": [{"id": 99, "matchupPeriodId": 4, "home": {"teamId": 2, "totalPoints": 88.0}, "away": {"teamId": 1, "totalPoints": 91.5}}]
        }
        """.utf8)
        let response = try JSONDecoder().decode(ESPNLeagueResponseDTO.self, from: json)
        let descriptor = ESPNFantasyConnectionInput(gameCode: .hockey, seasonID: 2026, leagueID: "12345", teamID: 1, scoringPeriodID: 12, matchupPeriodID: 4)
        let league = try ESPNFantasyMapper.league(from: response, descriptor: descriptor)
        #expect(league.provider == .espn)
        #expect(league.sport == .nhl)
        #expect(league.scoringSettings.values["espn.hockey.stat.1"] == 3.0)

        let teams = ESPNFantasyMapper.teams(from: response, descriptor: descriptor)
        let rosters = ESPNFantasyMapper.rosters(from: response, descriptor: descriptor, teams: teams)
        #expect(rosters.first?.slots.first?.kind == .starter)
        #expect(rosters.first?.slots.dropFirst().first?.kind == .bench)
        ESPNHockeyTeamResolver.shared.updateMappings([22: "TOR"])
        let players = ESPNFantasyMapper.players(from: response)
        #expect(players["3114"]?.externalIDs.espnID == "3114")
        #expect(players["3114"]?.teamAbbreviation == "TOR")

        let matchup = ESPNFantasyMapper.matchup(from: response, descriptor: descriptor, userTeamID: 1, teams: teams)
        #expect(matchup?.userTeam.effectivePoints == 91.5)
        #expect(matchup?.opponentTeam?.rosterID == 2)

        let standings = ESPNFantasyMapper.standings(from: response, descriptor: descriptor)
        #expect(standings.first?.rosterID == 1)
        #expect(ESPNFantasyMapper.ownerTeamID(from: response, swid: "owner") == 1)
    }

    private func fantasyLeague(id: String, name: String, status: FantasyLeagueStatus = .inSeason) -> FantasyLeague {
        FantasyLeague(
            id: id,
            provider: .sleeper,
            sport: .nfl,
            name: name,
            season: "2026",
            status: status,
            totalRosters: 12,
            avatarID: nil,
            rosterPositions: ["QB", "RB", "WR", "TE", "FLEX"],
            scoringSettings: FantasyScoringSettings(values: ["rec": 1]),
            providerMetadata: [:]
        )
    }

    private func fantasyRoster(leagueID: String, rosterID: Int, ownerID: String, playerIDs: [String]) -> FantasyRoster {
        FantasyRoster(
            id: "\(leagueID)-\(rosterID)",
            leagueID: leagueID,
            rosterID: rosterID,
            ownerUserID: ownerID,
            team: FantasyTeam(id: "\(leagueID)-\(rosterID)", leagueID: leagueID, providerUserID: ownerID, rosterID: rosterID, displayName: "Mock Team", username: "mock", avatarID: nil, isOwner: true),
            slots: playerIDs.enumerated().map { index, playerID in
                FantasyRosterSlot(id: "\(leagueID)-\(rosterID)-\(playerID)", playerID: playerID, kind: index == 0 ? .starter : .bench, lineupPosition: index == 0 ? "STARTER_1" : nil, fantasyPoints: nil, projectedPoints: nil)
            },
            record: FantasyRecord(wins: 1, losses: 0, ties: 0, pointsFor: 100, pointsAgainst: 90),
            waiverPosition: nil,
            waiverBudgetUsed: nil,
            totalMoves: nil
        )
    }

    private func fantasyPlayer(id: String, name: String, team: String, position: String, espnID: String? = nil) -> FantasyPlayer {
        FantasyPlayer(
            id: id,
            provider: .sleeper,
            sport: .nfl,
            firstName: nil,
            lastName: nil,
            fullName: name,
            teamAbbreviation: team,
            position: position,
            fantasyPositions: [position],
            status: nil,
            injuryStatus: nil,
            jerseyNumber: nil,
            externalIDs: FantasyPlayerExternalIDs(espnID: espnID, sportradarID: nil, yahooID: nil, fantasyDataID: nil, statsID: nil, rotowireID: nil)
        )
    }
}

struct MockFantasyProviderService: FantasyProviderService {
    nonisolated let provider: FantasyProvider = .sleeper
    nonisolated let capabilities = FantasyProviderCapabilities.readOnlyCore
    var shouldFailSeason = false
    var leagues: [FantasyLeague] = []
    var rostersByLeagueID: [String: [FantasyRoster]] = [:]
    var playersByID: [String: FantasyPlayer] = [:]

    func connect(usernameOrUserID: String) async throws -> FantasyConnection {
        FantasyConnection(provider: .sleeper, providerUserID: "U1", username: usernameOrUserID, displayName: "Mock User", avatarID: nil, connectedAt: Date(), refreshedAt: nil)
    }

    func currentSeasonState(for connection: FantasyConnection) async throws -> FantasySeasonState {
        if shouldFailSeason { throw FantasyProviderError.providerUnavailableForTests }
        return FantasySeasonState(sport: .nfl, season: "2026", leagueSeason: "2026", week: 1, displayWeek: 1, seasonType: "regular", seasonStartDate: nil)
    }

    func leagues(for connection: FantasyConnection, season: String) async throws -> [FantasyLeague] { leagues }
    func league(id: String) async throws -> FantasyLeague { leagues.first { $0.id == id } ?? FantasyLeague(id: id, provider: .sleeper, sport: .nfl, name: id, season: "2026", status: .inSeason, totalRosters: nil, avatarID: nil, rosterPositions: [], scoringSettings: FantasyScoringSettings(values: [:]), providerMetadata: [:]) }
    func leagueUsers(leagueID: String) async throws -> [FantasyTeam] { rostersByLeagueID[leagueID]?.compactMap(\.team) ?? [] }
    func leagueRosters(leagueID: String, teams: [FantasyTeam]) async throws -> [FantasyRoster] { rostersByLeagueID[leagueID] ?? [] }
    func userRoster(in rosters: [FantasyRoster], connection: FantasyConnection) -> FantasyRoster? { rosters.first { $0.ownerUserID == connection.providerUserID } }
    func matchup(leagueID: String, week: Int, userRosterID: Int, teams: [FantasyTeam]) async throws -> FantasyMatchup? { nil }
    func standings(leagueID: String, rosters: [FantasyRoster]) async throws -> [FantasyStanding] { rosters.map { FantasyStanding(id: "\(leagueID)-\($0.rosterID)", leagueID: leagueID, rosterID: $0.rosterID, team: $0.team, record: $0.record ?? FantasyRecord(wins: nil, losses: nil, ties: nil, pointsFor: nil, pointsAgainst: nil), rank: nil) } }
    func players(ids: Set<String>, sport: FantasySport) async throws -> [String: FantasyPlayer] { playersByID.filter { ids.contains($0.key) } }
    func disconnect(connection: FantasyConnection) async {}
    func refreshCachedData() async {}
}

extension FantasyProviderError {
    static var providerUnavailableForTests: FantasyProviderError { .httpError(503) }
}

struct MockFantasyEventLinker: FantasyEventLinking {
    let games: [FantasyPlayerGame]

    func linkPlayerGames(players: [FantasyPlayer], resolutions: [String: FantasyPlayerResolution], matchup: FantasyMatchup?, channels: [Channel], preferredLanguages: Set<String>, knownMatches: [Match]?) async -> [FantasyPlayerGame] {
        games
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
