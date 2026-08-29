import Foundation
import Testing
@testable import StadiaTV

@Suite("Sports data foundation")
struct SportsDataFoundationTests {
    @Test func canonicalIDsDoNotUseDisplayNamesForESPNAliases() throws {
        let league = try #require(League.all.first { $0.path == "hockey/nhl" })
        let resolver = SportsIdentityResolver()
        let first = resolver.canonicalTeamID(league: league, provider: .espn, providerTeamID: "10", abbreviation: "TOR", displayName: "Toronto Maple Leafs")
        let renamed = resolver.canonicalTeamID(league: league, provider: .espn, providerTeamID: "10", abbreviation: "TOR", displayName: "Toronto")
        #expect(first == renamed)
        #expect(SportsIdentityResolver.providerID(from: first, provider: .espn) == "10")
    }

    @Test func routeConfigurationIsCapabilitySpecific() throws {
        let league = try #require(League.all.first { $0.path == "hockey/nhl" })
        let config = SportsProviderRouteConfiguration(routes: [
            ProviderRoute(leagueID: league.stadiaKey, capability: .liveScores, providers: [.nhl, .espn]),
            ProviderRoute(leagueID: league.stadiaKey, capability: .injuries, providers: [.cbsSports, .espn])
        ])
        #expect(config.providers(for: league, capability: .liveScores).first == .nhl)
        #expect(config.providers(for: league, capability: .injuries).first == .cbsSports)
    }

    @Test func productionRegistryContainsEnabledFoundationAdapters() {
        let providerIDs = Set(SportsProviderRegistry.production().metadata().map(\.id))
        #expect(providerIDs.contains(.nhl))
        #expect(providerIDs.contains(.appleSports))
        #expect(providerIDs.contains(.espn))
    }

    @Test func appleSportsRoutesMatchRequestedHierarchy() throws {
        let config = SportsProviderRouteConfiguration.firstPass
        let premierLeague = try #require(League.all.first { $0.path == "soccer/eng.1" })
        let nhl = try #require(League.all.first { $0.path == "hockey/nhl" })
        let mlb = try #require(League.all.first { $0.path == "baseball/mlb" })
        let wnba = try #require(League.all.first { $0.path == "basketball/wnba" })
        #expect(config.providers(for: premierLeague, capability: .liveScores).prefix(2) == [.appleSports, .cbsSports])
        #expect(config.providers(for: premierLeague, capability: .boxScore).first == .appleSports)
        #expect(config.providers(for: wnba, capability: .schedule).first == .appleSports)
        #expect(config.providers(for: wnba, capability: .playerStats).first == .appleSports)
        #expect(config.providers(for: nhl, capability: .liveScores).prefix(2) == [.nhl, .appleSports])
        #expect(config.providers(for: mlb, capability: .schedule).prefix(2) == [.mlb, .appleSports])
    }

    @Test func appleSportsManifestDecodesDiscoveredGroupAndTeamIDs() throws {
        let data = #"""
        {
          "version":"3.0.109",
          "cdn_base_url":"https://api-sports.cdn-apple.com/v3/query",
          "image_service_url":"https://is1-ssl.mzstatic.com",
          "groups":{
            "umc.csl.4uhb3gez2l9v5y5u4nz5zwft6":{"name":"Premier League","abbr":"EPL","cdn_id":"a6c7d4c2f1a60a1713113a286337aff9"}
          },
          "teams":{
            "umc.cst.62yqybrdww796c82xfk7w69xb":{"league_ids":["umc.csl.4uhb3gez2l9v5y5u4nz5zwft6"],"group_ids":["umc.csl.4uhb3gez2l9v5y5u4nz5zwft6"],"name":"Leeds","full_name":"Leeds United","abbr":"LEE","logo_token":"token"}
          }
        }
        """#.data(using: .utf8)!
        let response = try AppleSportsJSONDecoder.decoder.decode(AppleSportsManifestResponseDTO.self, from: data)
        let manifest = AppleSportsManifest(response: response)
        let league = try #require(League.all.first { $0.path == "soccer/eng.1" })
        #expect(manifest.version == "3.0.109")
        #expect(manifest.group(for: league)?.canonicalID == "umc.csl.4uhb3gez2l9v5y5u4nz5zwft6")
        #expect(manifest.teams["umc.cst.62yqybrdww796c82xfk7w69xb"]?.abbr == "LEE")
    }

    @Test func appleSportsScoreEntriesNormalizeBoxScoreStats() throws {
        let data = #"""
        {
          "scoreEntries":[
            {"value":96,"statisticType":{"name":"Score"}},
            {"value":12,"statisticType":{"name":"Rebounds"}}
          ],
          "lineScore":[
            {"period":{"index":1,"type":"Quarter"},"score":[{"value":27,"statisticType":{"name":"Points"}}]}
          ]
        }
        """#.data(using: .utf8)!
        let score = try AppleSportsJSONDecoder.decoder.decode(AppleSportsScoreDTO.self, from: data)
        let stats = score.allStats(prefix: "event")
        #expect(score.displayScore == "96")
        #expect(stats.contains { $0.key == "event_score" && $0.value == "96" })
        #expect(stats.contains { $0.key == "event_rebounds" && $0.value == "12" })
        #expect(stats.contains { $0.key == "line_quarter_1_points" && $0.value == "27" })
    }

    @Test func repositoryRoutesBoxScoreCapability() async throws {
        let league = try #require(League.all.first { $0.path == "basketball/wnba" })
        let gameID = StadiaEntityID(rawValue: "umc.cse.example")
        let teamID = StadiaEntityID(rawValue: "team:basketball/wnba:appleSports:umc.cst.example")
        let stat = StadiaTeamStat(
            id: StadiaEntityID(rawValue: "teamStat:example"),
            teamID: teamID,
            seasonID: nil,
            stats: [StadiaStatValue(key: "event_score", displayName: "Score", value: "96")],
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: "umc.cst.example", confidence: 1)
        )
        let boxScore = StadiaBoxScore(
            id: StadiaEntityID(rawValue: "boxScore:example"),
            gameID: gameID,
            teamStats: [stat],
            playerStats: [],
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: "umc.cse.example", confidence: 1)
        )
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [MockBoxScoreProvider(result: .success(boxScore))]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.path, capability: .boxScore, providers: [.appleSports])
            ]),
            healthMonitor: ProviderHealthMonitor()
        )
        let repository = SportsRepository(router: router, cache: SportsDataCache())
        let routed = try await repository.boxScore(for: league, gameID: gameID)
        #expect(routed.teamStats.first?.stats.first?.value == "96")
        #expect(routed.provenance.provider == .appleSports)
    }

    @Test func nhlLocalizedStringsDecodeKnownAPIShapes() throws {
        let objectData = #"{"name":{"default":"Toronto Maple Leafs"}}"#.data(using: .utf8)!
        let stringData = #"{"name":"Toronto"}"#.data(using: .utf8)!
        #expect(try NHLJSONDecoder.decoder.decode(NHLLocalizedNameFixture.self, from: objectData).name.value == "Toronto Maple Leafs")
        #expect(try NHLJSONDecoder.decoder.decode(NHLLocalizedNameFixture.self, from: stringData).name.value == "Toronto")
    }

    @Test func legacyBridgeUsesNonESPNAliasesWhenESPNAliasIsAbsent() throws {
        let league = try #require(League.all.first { $0.path == "hockey/nhl" })
        let game = Self.game(league: league, providerID: .nhl, providerGameID: "2025020001")
        let legacy = game.toLegacyMatch(league: league)
        #expect(legacy.id == "2025020001")
        #expect(legacy.home.teamID == "1")
    }

    @Test func nhlBoxScoreFixtureDecodesPlayerStats() throws {
        let data = #"""
        {
          "awayTeam":{"id":10,"abbrev":"TOR","score":4,"sog":31,"name":{"default":"Toronto Maple Leafs"}},
          "homeTeam":{"id":8,"abbrev":"MTL","score":2,"sog":26,"name":{"default":"Montreal Canadiens"}},
          "playerByGameStats":{
            "awayTeam":{
              "forwards":[{"playerId":8478402,"name":{"default":"Auston Matthews"},"sweaterNumber":34,"position":"C","goals":2,"assists":1,"points":3,"plusMinus":2,"pim":0,"hits":1,"blockedShots":0,"powerPlayGoals":1,"sog":6,"faceoffWinningPctg":0.56,"toi":"21:14"}],
              "defense":[],
              "goalies":[{"playerId":8475883,"name":{"default":"Example Goalie"},"sweaterNumber":31,"goalsAgainst":2,"shotsAgainst":26,"saves":24,"savePctg":0.923,"toi":"60:00"}]
            },
            "homeTeam":{"forwards":[],"defense":[],"goalies":[]}
          }
        }
        """#.data(using: .utf8)!
        let boxScore = try NHLJSONDecoder.decoder.decode(NHLBoxScoreResponseDTO.self, from: data)
        #expect(boxScore.awayTeam?.abbrev == "TOR")
        #expect(boxScore.awayTeam?.sog == 31)
        #expect(boxScore.playerByGameStats?.awayTeam?.forwards?.first?.playerID == 8478402)
        #expect(boxScore.playerByGameStats?.awayTeam?.forwards?.first?.points == 3)
        #expect(boxScore.playerByGameStats?.awayTeam?.goalies?.first?.savePctg == 0.923)
    }

    @Test func routerSkipsUnhealthyPrimaryAndUsesFallbackProvider() async throws {
        let league = try #require(League.all.first { $0.path == "football/nfl" })
        let failing = MockScoreProvider(id: .nfl, result: .failure(SportsDataError.unavailable))
        let fallbackGame = Self.game(league: league, providerID: .espn, providerGameID: "401")
        let fallback = MockScoreProvider(id: .espn, result: .success([fallbackGame]))
        let health = ProviderHealthMonitor(failureCooldownThreshold: 1, cooldownDuration: 300)
        await health.recordFailure(providerID: .nfl, error: SportsDataError.unavailable)
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [failing, fallback]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.path, capability: .liveScores, providers: [.nfl, .espn])
            ]),
            healthMonitor: health
        )
        let providers = await router.providers(for: league, capability: .liveScores, as: (any ScoreProvider).self)
        #expect(providers.map { $0.metadata.id } == [.espn])
    }

    @Test func repositoryFallsBackWhenPrimaryFails() async throws {
        let league = try #require(League.all.first { $0.path == "football/nfl" })
        let fallbackGame = Self.game(league: league, providerID: .espn, providerGameID: "402")
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [
                MockScoreProvider(id: .nfl, result: .failure(SportsDataError.unavailable)),
                MockScoreProvider(id: .espn, result: .success([fallbackGame]))
            ]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.path, capability: .liveScores, providers: [.nfl, .espn])
            ]),
            healthMonitor: ProviderHealthMonitor()
        )
        let repository = SportsRepository(router: router, cache: SportsDataCache())
        let games = try await repository.liveScores(for: league)
        #expect(games.map(\.id) == [fallbackGame.id])
        #expect(games.first?.provenance.provider == .espn)
    }

    @Test func repositoryRoutesPlayByPlayCapability() async throws {
        let league = try #require(League.all.first { $0.path == "hockey/nhl" })
        let gameID = StadiaEntityID(rawValue: "2025020001")
        let play = StadiaPlay(
            id: StadiaEntityID(rawValue: "play:nhl:2025020001:1"),
            sequence: 1,
            period: StadiaPeriod(number: 1, displayName: "Period 1"),
            clock: StadiaGameClock(displayValue: "19:59", remainingSeconds: nil, isRunning: nil),
            text: "Puck dropped",
            teamID: nil,
            awayScore: nil,
            homeScore: nil,
            isScoringPlay: false,
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: "1", confidence: 1)
        )
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [MockPlayByPlayProvider(result: .success([play]))]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.path, capability: .playByPlay, providers: [.nhl])
            ]),
            healthMonitor: ProviderHealthMonitor()
        )
        let repository = SportsRepository(router: router, cache: SportsDataCache())
        let playByPlay = try await repository.playByPlay(for: league, gameID: gameID)
        #expect(playByPlay.plays.map(\.text) == ["Puck dropped"])
        #expect(playByPlay.provenance.provider == .nhl)
    }

    @Test func cacheAndRequestDeduplicatorCoalesceIdenticalRequests() async throws {
        let key = SportsCacheKey(providerID: .espn, leagueID: "football/nfl", capability: .liveScores, scope: "today")
        let cache = SportsDataCache()
        await cache.store([1, 2, 3], for: key, ttl: 60)
        let cached: [Int]? = await cache.value(for: key)
        #expect(cached == [1, 2, 3])

        let counter = SportsCounter()
        let deduplicator = SportsRequestDeduplicator<String, Int>()
        async let first = deduplicator.value(for: "same") {
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return 11
        }
        async let second = deduplicator.value(for: "same") {
            await counter.increment()
            return 12
        }
        let values = try await [first, second]
        #expect(values == [11, 11])
        #expect(await counter.value == 1)
    }

    @Test func healthMonitorCoolsDownRepeatedFailuresAndRecoversOnSuccess() async {
        let monitor = ProviderHealthMonitor(failureCooldownThreshold: 2, cooldownDuration: 120)
        await monitor.recordFailure(providerID: .appleSports, error: SportsDataError.decodingFailed)
        #expect(await monitor.snapshot(for: .appleSports).state == .degraded)
        await monitor.recordFailure(providerID: .appleSports, error: SportsDataError.decodingFailed)
        #expect(await monitor.snapshot(for: .appleSports).state == .unavailable)
        await monitor.recordSuccess(providerID: .appleSports, latency: 0.2)
        #expect(await monitor.snapshot(for: .appleSports).state == .healthy)
    }

    @Test func legacyESPNFavoriteDecodesWithCanonicalTeamIDAndAlias() throws {
        let data = #"""
        {
          "leaguePath":"hockey/nhl",
          "teamID":"10",
          "displayName":"Toronto Maple Leafs",
          "abbreviation":"TOR",
          "logoURLString":null
        }
        """#.data(using: .utf8)!
        let favorite = try JSONDecoder().decode(FavoriteTeam.self, from: data)
        #expect(favorite.leagueStadiaKey == "league.hockey-nhl")
        #expect(favorite.canonicalTeamID == "team:league.hockey-nhl:espn:10")
        #expect(favorite.providerAliases == [ProviderEntityAlias(provider: .espn, id: "10")])
    }

    @Test func routeOverrideDisablesProviderForSelectedCapability() async throws {
        let league = try #require(League.all.first { $0.path == "hockey/nhl" })
        let overrides = SportsProviderRouteOverrideStore(storageKey: "sportsData.tests.routeOverrides")
        await overrides.removeAll()
        await overrides.setProvider(.nhl, enabled: false, leagueID: league.stadiaKey, capability: .liveScores)
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [
                MockScoreProvider(id: .nhl, result: .success([])),
                MockScoreProvider(id: .espn, result: .success([]))
            ]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.stadiaKey, capability: .liveScores, providers: [.nhl, .espn])
            ]),
            healthMonitor: ProviderHealthMonitor(),
            routeOverrides: overrides
        )
        let providers = await router.providers(for: league, capability: .liveScores, as: (any ScoreProvider).self)
        #expect(providers.map { $0.metadata.id } == [.espn])
        await overrides.removeAll()
    }

    @Test func repositoryCachesTeamsCapability() async throws {
        let league = try #require(League.all.first { $0.path == "hockey/nhl" })
        let counter = SportsCounter()
        let team = StadiaTeam(
            id: StadiaEntityID(rawValue: "team:\(league.stadiaKey):nhl:TOR"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: "Toronto Maple Leafs",
            shortName: "Maple Leafs",
            abbreviation: "TOR",
            logoURL: nil,
            aliases: [ProviderEntityAlias(provider: .nhl, id: "TOR")],
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: "TOR", confidence: 1)
        )
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [MockTeamProvider(counter: counter, teams: [team])]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.stadiaKey, capability: .teams, providers: [.nhl])
            ]),
            healthMonitor: ProviderHealthMonitor(),
            routeOverrides: SportsProviderRouteOverrideStore(storageKey: "sportsData.tests.teamCache")
        )
        let repository = SportsRepository(router: router, cache: SportsDataCache())
        let first = try await repository.teams(for: league)
        let second = try await repository.teams(for: league)
        #expect(first == second)
        #expect(await counter.value == 1)
    }

    private static func game(league: League, providerID: SportsDataProviderID, providerGameID: String) -> StadiaGame {
        let resolver = SportsIdentityResolver()
        let provenance = DataProvenance(provider: providerID, fetchedAt: Date(), providerEntityID: providerGameID, confidence: 1)
        let home = StadiaTeam(
            id: resolver.canonicalTeamID(league: league, provider: providerID, providerTeamID: "1", abbreviation: "HME", displayName: "Home"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: "Home",
            shortName: "Home",
            abbreviation: "HME",
            logoURL: nil,
            aliases: [ProviderEntityAlias(provider: providerID, id: "1")],
            provenance: provenance
        )
        let away = StadiaTeam(
            id: resolver.canonicalTeamID(league: league, provider: providerID, providerTeamID: "2", abbreviation: "AWY", displayName: "Away"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: "Away",
            shortName: "Away",
            abbreviation: "AWY",
            logoURL: nil,
            aliases: [ProviderEntityAlias(provider: providerID, id: "2")],
            provenance: provenance
        )
        return StadiaGame(
            id: resolver.canonicalGameID(league: league, provider: providerID, providerGameID: providerGameID, home: home, away: away, scheduledStart: Date(timeIntervalSince1970: 1_800_000_000)),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            scheduledStart: Date(timeIntervalSince1970: 1_800_000_000),
            name: "Away at Home",
            shortName: "AWY @ HME",
            status: .scheduled,
            statusDetail: "Tonight",
            homeTeam: home,
            awayTeam: away,
            score: StadiaScore(home: nil, away: nil),
            clock: nil,
            period: nil,
            venue: nil,
            broadcasts: [],
            aliases: [ProviderEntityAlias(provider: providerID, id: providerGameID)],
            provenance: provenance
        )
    }
}

private struct NHLLocalizedNameFixture: Decodable {
    let name: NHLLocalizedString
}

private struct MockBoxScoreProvider: BoxScoreProvider {
    let metadata = SportsDataProviderMetadata(
        id: .appleSports,
        name: "Apple mock",
        supportLevel: .experimental,
        supportedSports: Set(SportGroup.allCases),
        supportedLeagues: ["*"],
        capabilities: [.boxScore],
        authenticationType: .none,
        isEnabled: true,
        requestTimeout: 1
    )
    let result: Result<StadiaBoxScore, Error>

    func boxScore(for league: League, gameID: StadiaEntityID) async throws -> StadiaBoxScore {
        try result.get()
    }
}

private struct MockPlayByPlayProvider: PlayByPlayProvider {
    let metadata = SportsDataProviderMetadata(
        id: .nhl,
        name: "NHL mock",
        supportLevel: .firstPartyWeb,
        supportedSports: [.hockey],
        supportedLeagues: ["hockey/nhl"],
        capabilities: [.playByPlay],
        authenticationType: .none,
        isEnabled: true,
        requestTimeout: 1
    )
    let result: Result<[StadiaPlay], Error>

    func playByPlay(for league: League, gameID: StadiaEntityID) async throws -> StadiaPlayByPlay {
        StadiaPlayByPlay(
            id: StadiaEntityID(rawValue: "pbp:mock:\(gameID.rawValue)"),
            gameID: gameID,
            plays: try result.get(),
            provenance: DataProvenance(provider: .nhl, fetchedAt: Date(), providerEntityID: gameID.rawValue, confidence: 1)
        )
    }
}

private struct MockScoreProvider: ScoreProvider {
    let metadata: SportsDataProviderMetadata
    let result: Result<[StadiaGame], Error>

    init(id: SportsDataProviderID, result: Result<[StadiaGame], Error>) {
        self.metadata = SportsDataProviderMetadata(
            id: id,
            name: id.rawValue,
            supportLevel: id == .espn ? .legacy : .official,
            supportedSports: Set(SportGroup.allCases),
            supportedLeagues: ["*"],
            capabilities: [.liveScores],
            authenticationType: .none,
            isEnabled: true,
            requestTimeout: 1
        )
        self.result = result
    }

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try result.get()
    }
}

private struct MockTeamProvider: TeamProvider {
    let metadata = SportsDataProviderMetadata(
        id: .nhl,
        name: "NHL teams mock",
        supportLevel: .firstPartyWeb,
        supportedSports: [.hockey],
        supportedLeagues: ["*"],
        capabilities: [.teams],
        authenticationType: .none,
        isEnabled: true,
        requestTimeout: 1
    )
    let counter: SportsCounter
    let teams: [StadiaTeam]

    func teams(for league: League) async throws -> [StadiaTeam] {
        await counter.increment()
        return teams
    }
}

private actor SportsCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
