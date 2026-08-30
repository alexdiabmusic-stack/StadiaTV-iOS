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
        #expect(providerIDs.contains(.mlb))
        #expect(providerIDs.contains(.nba))
        #expect(providerIDs.contains(.nfl))
        #expect(providerIDs.contains(.appleSports))
        #expect(providerIDs.contains(.espn))
    }

    @Test func appleSportsRoutesMatchRequestedHierarchy() throws {
        let config = SportsProviderRouteConfiguration.firstPass
        let premierLeague = try #require(League.all.first { $0.path == "soccer/eng.1" })
        let nhl = try #require(League.all.first { $0.path == "hockey/nhl" })
        let mlb = try #require(League.all.first { $0.path == "baseball/mlb" })
        let nba = try #require(League.all.first { $0.path == "basketball/nba" })
        let nfl = try #require(League.all.first { $0.path == "football/nfl" })
        let wnba = try #require(League.all.first { $0.path == "basketball/wnba" })
        #expect(config.providers(for: premierLeague, capability: .liveScores).prefix(2) == [.appleSports, .espn])
        #expect(config.providers(for: premierLeague, capability: .boxScore).first == .appleSports)
        #expect(config.providers(for: wnba, capability: .schedule).prefix(2) == [.appleSports, .foxSports])
        #expect(config.providers(for: wnba, capability: .playerStats).first == .appleSports)
        #expect(config.providers(for: nhl, capability: .liveScores).prefix(2) == [.nhl, .appleSports])
        #expect(config.providers(for: mlb, capability: .schedule).prefix(2) == [.mlb, .appleSports])
        #expect(config.providers(for: mlb, capability: .boxScore).prefix(2) == [.mlb, .appleSports])
        #expect(config.providers(for: mlb, capability: .playByPlay).prefix(2) == [.mlb, .appleSports])
        #expect(config.providers(for: nba, capability: .liveScores).prefix(2) == [.nba, .appleSports])
        #expect(config.providers(for: nba, capability: .schedule).prefix(2) == [.nba, .appleSports])
        #expect(config.providers(for: nba, capability: .boxScore).prefix(2) == [.nba, .appleSports])
        #expect(config.providers(for: nba, capability: .playByPlay).prefix(2) == [.nba, .appleSports])
        #expect(config.providers(for: nfl, capability: .liveScores).prefix(2) == [.nfl, .appleSports])
        #expect(config.providers(for: nfl, capability: .schedule).prefix(2) == [.nfl, .appleSports])
        #expect(config.providers(for: nfl, capability: .playByPlay).prefix(2) == [.nfl, .appleSports])
    }

    @Test func webFallbackProviderMetadataMatchesImplementedReferenceCoverage() throws {
        let yahoo = YahooSportsProvider()
        let fox = FoxSportsProvider()
        let cbs = CBSSportsProvider()

        #expect(yahoo.metadata.supportedLeagues == Set(["football/college-football", "league.football-college-football"]))
        #expect(yahoo.metadata.supportedSports == [.football])
        #expect(fox.metadata.supportedLeagues.contains("baseball/mlb"))
        #expect(fox.metadata.supportedLeagues.contains("basketball/wnba"))
        #expect(!fox.metadata.capabilities.contains(.leagueLeaders))
        #expect(cbs.metadata.supportedLeagues.contains("football/nfl"))
        #expect(!cbs.metadata.supportedLeagues.contains("*"))
    }

    @Test func nflScheduleFixtureDecodesAndNormalizesGameShape() throws {
        let data = #"""
        {
          "games":[{
            "id":"7d3e8f84-1312-11ef-afd1-646009f18b2e",
            "date":"2026-09-13T20:25:00Z",
            "status":{"phase":"SCHEDULED","shortDescription":"4:25 PM ET"},
            "awayTeam":{"id":"away-team","fullName":"Green Bay Packers","nickName":"Packers","abbreviation":"GB"},
            "homeTeam":{"id":"home-team","fullName":"Minnesota Vikings","nickName":"Vikings","abbreviation":"MIN"},
            "venue":{"id":"venue-1","name":"U.S. Bank Stadium","city":"Minneapolis","state":"MN"},
            "broadcasts":[{"name":"FOX","type":"TV"}]
          }]
        }
        """#.data(using: .utf8)!
        let response = try NFLJSONDecoder.decoder.decode(NFLGameScheduleResponseDTO.self, from: data)
        let game = try #require(response.games?.first)
        #expect(game.providerID == "7d3e8f84-1312-11ef-afd1-646009f18b2e")
        #expect(game.awayTeam?.abbreviation == "GB")
        #expect(game.homeTeam?.fullName == "Minnesota Vikings")
        #expect(StadiaGameStatus(nflStatus: game.status, start: NFLDateFormatter.date(from: game.date) ?? Date()) == .scheduled)
    }

    @Test func nflGameDetailEnvelopeUnwrapsPlayByPlayPayload() throws {
        let data = #"""
        {
          "data":{"viewer":{"gameDetail":{
            "id":"game-1",
            "homeTeam":{"id":"home-team","fullName":"Buffalo Bills","nickName":"Bills","abbreviation":"BUF","score":14,"totalYards":180},
            "visitorTeam":{"id":"away-team","fullName":"Miami Dolphins","nickName":"Dolphins","abbreviation":"MIA","score":7,"totalYards":121},
            "status":{"phase":"LIVE","quarter":2,"clock":"08:11","displayStatus":"2nd · 08:11"},
            "plays":[{"playID":"42","quarter":2,"clock":"08:11","playDescription":"Josh Allen pass complete for 12 yards","homeScore":14,"visitorScore":7}]
          }}}
        }
        """#.data(using: .utf8)!
        let envelope = try NFLJSONDecoder.decoder.decode(NFLGameDetailEnvelopeDTO.self, from: data)
        let detail = try #require(envelope.data?.viewer?.gameDetail)
        #expect(detail.id == "game-1")
        #expect(detail.homeTeam?.totalYards == 180)
        #expect(detail.visitorTeam?.score == 7)
        #expect(detail.plays?.first?.playDescription == "Josh Allen pass complete for 12 yards")
        #expect(StadiaGameStatus(nflStatus: detail.status, start: Date()) == .live)
    }

    @Test func bundledTeamLogoResolverReturnsAssetURLsForPrimaryLeagues() {
        #expect(TeamLogoAssetResolver.nbaAssetURL(abbreviation: "TOR")?.stadiaImageAssetName == "NBALogo_TOR")
        #expect(TeamLogoAssetResolver.nflAssetURL(abbreviation: "JAC")?.stadiaImageAssetName == "NFLLogo_JAX")
        #expect(TeamLogoAssetResolver.mlbAssetURL(abbreviation: "TOR", displayName: "Toronto Blue Jays", providerTeamID: "141")?.stadiaImageAssetName == "MLBLogo_Toronto_Blue_Jays")
        #expect(TeamLogoAssetResolver.assetURL(leaguePath: "soccer/fra.1", abbreviation: nil, displayName: "Paris Saint Germain")?.stadiaImageAssetName == "MSILogo_ligue_1_paris_saint_germain")
    }

    @Test func nbaScoreboardFixtureDecodesLiveGameShape() throws {
        let data = #"""
        {
          "scoreboard":{
            "games":[{
              "gameId":"0022500001",
              "gameCode":"20251021/LALGSW",
              "gameStatus":2,
              "gameStatusText":"Q2 05:31",
              "gameTimeUTC":"2025-10-22T02:00:00Z",
              "period":2,
              "homeTeam":{"teamId":1610612744,"teamCity":"Golden State","teamName":"Warriors","teamTricode":"GSW","score":54},
              "awayTeam":{"teamId":1610612747,"teamCity":"Los Angeles","teamName":"Lakers","teamTricode":"LAL","score":51},
              "broadcasters":{"nationalTvBroadcasters":[{"broadcasterDisplay":"TNT"}]}
            }]
          }
        }
        """#.data(using: .utf8)!
        let response = try NBAJSONDecoder.decoder.decode(NBAScoreboardResponseDTO.self, from: data)
        let game = try #require(response.scoreboard?.games?.first)
        #expect(game.gameIDValue == "0022500001")
        #expect(game.homeTeam?.teamTricode == "GSW")
        #expect(game.awayTeam?.score == 51)
        #expect(game.stadiaBroadcasts.first?.network == "TNT")
        #expect(StadiaGameStatus(nbaStatusCode: game.gameStatus, text: game.gameStatusText, start: NBADateFormatter.date(from: game.gameTimeUTC) ?? Date()) == .live)
    }

    @Test func nbaBoxScoreFixtureDecodesTeamAndPlayerStats() throws {
        let data = #"""
        {
          "game":{
            "gameId":"0022500001",
            "gameStatus":3,
            "gameStatusText":"Final",
            "gameTimeUTC":"2025-10-22T02:00:00Z",
            "homeTeam":{
              "teamId":1610612744,
              "teamCity":"Golden State",
              "teamName":"Warriors",
              "teamTricode":"GSW",
              "score":112,
              "statistics":{"points":112,"assists":28,"reboundsTotal":44,"fieldGoalsPercentage":"47.8"},
              "players":[{"personId":201939,"name":"Stephen Curry","statistics":{"minutes":"32:18","points":31,"assists":7,"reboundsTotal":5,"plusMinusPoints":12}}]
            },
            "awayTeam":{"teamId":1610612747,"teamCity":"Los Angeles","teamName":"Lakers","teamTricode":"LAL","score":106,"statistics":{"points":106,"assists":22,"reboundsTotal":41}}
          }
        }
        """#.data(using: .utf8)!
        let response = try NBAJSONDecoder.decoder.decode(NBABoxScoreResponseDTO.self, from: data)
        let game = try #require(response.game)
        #expect(game.homeTeam?.statistics?.assists == 28)
        #expect(game.homeTeam?.players?.first?.personID == 201939)
        #expect(game.homeTeam?.players?.first?.statistics?.points == 31)
    }

    @Test func nbaStatsResultSetFixtureMapsRowsByHeader() throws {
        let data = #"""
        {"resultSets":[{"name":"Standings","headers":["TeamID","Conference","WINS","Losses","ConferenceRank"],"rowSet":[["1610612761","East",50,32,3]]}]}
        """#.data(using: .utf8)!
        let response = try NBAJSONDecoder.decoder.decode(NBAStatsResponseDTO.self, from: data)
        let row = try #require(response.firstResultSet(named: "Standings")?.rowsByHeader.first)
        #expect(row["TeamID"]?.stringValue == "1610612761")
        #expect(row["Conference"]?.stringValue == "East")
        #expect(row["WINS"]?.intValue == 50)
        #expect(row["ConferenceRank"]?.intValue == 3)
    }

    @Test func nbaPlayByPlayFixtureDecodesActionShape() throws {
        let data = #"""
        {"game":{"actions":[{"actionNumber":7,"period":1,"clock":"PT08M42.00S","teamId":1610612744,"description":"Stephen Curry makes 3PT jump shot","scoreHome":"12","scoreAway":"9","shotResult":"Made"}]}}
        """#.data(using: .utf8)!
        let response = try NBAJSONDecoder.decoder.decode(NBAPlayByPlayResponseDTO.self, from: data)
        let action = try #require(response.game?.actions?.first)
        #expect(action.actionNumber == 7)
        #expect(action.teamIDValue == "1610612744")
        #expect(action.isScoringPlay)
    }

    @Test func mlbScheduleFixtureDecodesLiveGameShape() throws {
        let data = #"""
        {
          "dates":[{
            "date":"2026-08-29",
            "games":[{
              "gamePk":822770,
              "gameDate":"2026-08-29T19:07:00Z",
              "status":{"abstractGameState":"Live","detailedState":"In Progress","statusCode":"I"},
              "teams":{
                "away":{"team":{"id":136,"name":"Seattle Mariners","teamName":"Mariners","abbreviation":"SEA","fileCode":"sea"},"score":4},
                "home":{"team":{"id":141,"name":"Toronto Blue Jays","teamName":"Blue Jays","abbreviation":"TOR","fileCode":"tor"},"score":3}
              },
              "venue":{"id":14,"name":"Rogers Centre","location":{"city":"Toronto","state":"Ontario","country":"Canada"}},
              "broadcasts":[{"id":1,"name":"Sportsnet","type":"TV"}],
              "linescore":{"currentInning":7,"inningHalf":"Top","balls":1,"strikes":2,"outs":1}
            }]
          }]
        }
        """#.data(using: .utf8)!
        let response = try MLBJSONDecoder.decoder.decode(MLBScheduleResponseDTO.self, from: data)
        let game = try #require(response.dates?.first?.games?.first)
        #expect(game.gamePk == 822770)
        #expect(game.teams?.away?.team?.abbreviation == "SEA")
        #expect(game.venue?.location?.city == "Toronto")
        #expect(game.broadcasts?.first?.name == "Sportsnet")
        #expect(StadiaGameStatus(mlbAbstractState: game.status?.abstractGameState, detailedState: game.status?.detailedState, statusCode: game.status?.statusCode) == .live)
        #expect(MLBStatusFormatter.detail(status: .live, detailedState: game.status?.detailedState, linescore: game.linescore, start: Date()) == "Top 7th · 1 out")
    }

    @Test func mlbStatusMapperTreatsDetailedInningStatesAsLive() {
        #expect(StadiaGameStatus(mlbAbstractState: nil, detailedState: "Top 4th", statusCode: nil) == .live)
        #expect(StadiaGameStatus(mlbAbstractState: nil, detailedState: "In Progress", statusCode: nil) == .live)
        #expect(StadiaGameStatus(mlbAbstractState: nil, detailedState: "Game Over", statusCode: nil) == .final)
    }

    @Test func mlbBoxScoreStatsFlattenBaseballFields() throws {
        let data = #"""
        {"batting":{"runs":5,"hits":9,"homeRuns":2,"rbi":5,"baseOnBalls":3,"strikeOuts":7,"avg":".264"},"pitching":{"inningsPitched":"8.0","earnedRuns":2,"pitchesStrikes":"101-65","era":"3.41"},"fielding":{"errors":1}}
        """#.data(using: .utf8)!
        let stats = try MLBJSONDecoder.decoder.decode(MLBPlayerBoxStatsDTO.self, from: data).flattenedStats()
        #expect(stats.contains { $0.key == "runs" && $0.value == "5" })
        #expect(stats.contains { $0.key == "home_runs" && $0.value == "2" })
        #expect(stats.contains { $0.key == "pitch_strikes" && $0.value == "101-65" })
        #expect(stats.contains { $0.key == "errors" && $0.value == "1" })
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

    @Test func repositoryRoutesGolfTournamentCapabilityWithNormalizedLeaderboard() async throws {
        let league = try #require(League.all.first { $0.path == "golf/pga" })
        let gameID = StadiaEntityID(rawValue: "umc.cse.golf")
        let playerID = StadiaEntityID(rawValue: "player:league-golf-pga:appleSports:golfer-1")
        let tournament = StadiaGolfTournament(
            id: StadiaEntityID(rawValue: "golfTournament:appleSports:umc.cse.golf"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            gameID: gameID,
            tournamentName: "PGA Tour Champions",
            tourName: league.name,
            status: .live,
            statusDetail: "Round 2",
            currentRound: 2,
            totalRounds: 4,
            course: StadiaGolfCourse(id: nil, name: "Example Course", location: nil, par: 72, yardage: nil, holes: []),
            cutLine: "-2",
            leaderboard: StadiaGolfLeaderboardNormalizer.normalized([
                StadiaGolfLeaderboardEntry(
                    id: StadiaEntityID(rawValue: "golfEntry:appleSports:umc.cse.golf:golfer-1"),
                    playerID: playerID,
                    playerName: "V. Taylor",
                    position: nil,
                    isTied: false,
                    totalScore: StadiaGolfScoreFormatter.format(raw: "-12"),
                    todayScore: StadiaGolfScoreFormatter.format(raw: "-4"),
                    thru: "15",
                    status: nil,
                    rounds: [],
                    stats: [],
                    aliases: [ProviderEntityAlias(provider: .appleSports, id: "golfer-1")],
                    provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: "golfer-1", confidence: 1)
                )
            ]),
            broadcasts: [StadiaBroadcast(network: "Golf Channel", type: nil, countryCode: nil)],
            stats: [],
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: "umc.cse.golf", confidence: 1)
        )
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [MockGolfTournamentProvider(result: .success(tournament))]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.path, capability: .golfTournament, providers: [.appleSports])
            ]),
            healthMonitor: ProviderHealthMonitor()
        )
        let repository = SportsRepository(router: router, cache: SportsDataCache())
        let routed = try await repository.golfTournament(for: league, gameID: gameID)
        #expect(routed.leaderboard.first?.position == "1")
        #expect(routed.leaderboard.first?.totalScore == "-12")
        #expect(routed.cutLine == "-2")
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

    @Test func liveSnapshotRequestsSameDayScheduleWindowForAggregation() async throws {
        let league = try #require(League.all.first { $0.path == "baseball/mlb" })
        let capture = SportsScheduleRangeCapture()
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [MockScheduleSnapshotProvider(capture: capture)]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.stadiaKey, capability: .liveScores, providers: [.mlb]),
                ProviderRoute(leagueID: league.stadiaKey, capability: .schedule, providers: [.mlb])
            ]),
            healthMonitor: ProviderHealthMonitor(),
            routeOverrides: SportsProviderRouteOverrideStore(storageKey: "sportsData.tests.liveSnapshotRange")
        )
        let repository = SportsRepository(router: router, cache: SportsDataCache())
        _ = await repository.liveMatchSnapshot(leagues: [league], startingSoonWindow: 4 * 3600, nextLimit: 0)
        let range = try #require(await capture.range)
        #expect(Calendar.current.isDate(range.start, inSameDayAs: Date()))
        #expect(range.start == Calendar.current.startOfDay(for: Date()))
        #expect(range.end > Date())
        await router.routeOverrides.removeAll()
    }

    @Test func liveSnapshotPromotesSameDayScoredLiveDetailFromSchedule() async throws {
        let league = try #require(League.all.first { $0.path == "soccer/eng.1" })
        let scheduledButLive = Self.game(
            league: league,
            providerID: .appleSports,
            providerGameID: "soccer-live-detail",
            scheduledStart: Date().addingTimeInterval(-1_800),
            status: .scheduled,
            statusDetail: "HT",
            homeScore: "2",
            awayScore: "1"
        )
        let router = SportsProviderRouter(
            registry: SportsProviderRegistry(providers: [MockScoreScheduleProvider(scoreResult: .success([]), scheduleGames: [scheduledButLive])]),
            routeConfiguration: SportsProviderRouteConfiguration(routes: [
                ProviderRoute(leagueID: league.stadiaKey, capability: .liveScores, providers: [.appleSports]),
                ProviderRoute(leagueID: league.stadiaKey, capability: .schedule, providers: [.appleSports])
            ]),
            healthMonitor: ProviderHealthMonitor(),
            routeOverrides: SportsProviderRouteOverrideStore(storageKey: "sportsData.tests.liveSnapshotScored")
        )
        let repository = SportsRepository(router: router, cache: SportsDataCache())
        let snapshot = await repository.liveMatchSnapshot(leagues: [league], startingSoonWindow: 4 * 3600, nextLimit: 0)
        #expect(snapshot.live.map(\.id) == ["soccer-live-detail"])
        #expect(snapshot.live.first?.hasDisplayScore == true)
        await router.routeOverrides.removeAll()
    }

    @Test func gameCentreArchetypeUsesSportGroupRouting() throws {
        let golf = try #require(League.all.first { $0.path == "golf/champions-tour" })
        let indyCar = try #require(League.all.first { $0.path == "racing/irl" })
        let tennis = try #require(League.all.first { $0.path == "tennis/atp" })
        let nhl = try #require(League.all.first { $0.path == "hockey/nhl" })

        #expect(GameCentreArchetype(match: Self.legacyMatch(league: golf)) == .golf)
        #expect(GameCentreArchetype(match: Self.legacyMatch(league: indyCar)) == .motorsport)
        #expect(GameCentreArchetype(match: Self.legacyMatch(league: tennis)) == .tennis)
        #expect(GameCentreArchetype(match: Self.legacyMatch(league: nhl)) == .teamSport)
    }

    @Test func gameCentreArchetypeDetectsCombatEventsFromMetadata() {
        let league = League(name: "UFC", shortName: "UFC", path: "combat/ufc", group: .wrestling, keywords: ["ufc", "mma"])
        #expect(GameCentreArchetype(match: Self.legacyMatch(league: league, name: "UFC Fight Night")) == .combatSport)
    }

    private static func legacyMatch(league: League, name: String = "Example Event") -> Match {
        Match(
            id: "event-\(league.path)",
            league: league,
            date: Date(),
            name: name,
            shortName: league.shortName,
            state: .live,
            statusDetail: "In Progress",
            home: TeamSide(displayName: "Home", shortName: "Home", abbreviation: "HME", logoURL: nil, score: "1", record: nil, isWinner: false, teamID: "1"),
            away: TeamSide(displayName: "Away", shortName: "Away", abbreviation: "AWY", logoURL: nil, score: "0", record: nil, isWinner: false, teamID: "2"),
            broadcasts: [],
            venue: nil
        )
    }

    private static func game(
        league: League,
        providerID: SportsDataProviderID,
        providerGameID: String,
        scheduledStart: Date = Date(timeIntervalSince1970: 1_800_000_000),
        status: StadiaGameStatus = .scheduled,
        statusDetail: String = "Tonight",
        homeScore: String? = nil,
        awayScore: String? = nil
    ) -> StadiaGame {
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
            id: resolver.canonicalGameID(league: league, provider: providerID, providerGameID: providerGameID, home: home, away: away, scheduledStart: scheduledStart),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            scheduledStart: scheduledStart,
            name: "Away at Home",
            shortName: "AWY @ HME",
            status: status,
            statusDetail: statusDetail,
            homeTeam: home,
            awayTeam: away,
            score: StadiaScore(home: homeScore, away: awayScore),
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

private struct MockGolfTournamentProvider: GolfTournamentProvider {
    let metadata = SportsDataProviderMetadata(
        id: .appleSports,
        name: "Apple golf mock",
        supportLevel: .experimental,
        supportedSports: [.golf],
        supportedLeagues: ["*"],
        capabilities: [.golfTournament],
        authenticationType: .none,
        isEnabled: true,
        requestTimeout: 1
    )
    let result: Result<StadiaGolfTournament, Error>

    func golfTournament(for league: League, gameID: StadiaEntityID) async throws -> StadiaGolfTournament {
        try result.get()
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

private struct MockScoreScheduleProvider: ScoreProvider, ScheduleProvider {
    let metadata = SportsDataProviderMetadata(
        id: .appleSports,
        name: "Apple schedule mock",
        supportLevel: .experimental,
        supportedSports: Set(SportGroup.allCases),
        supportedLeagues: ["*"],
        capabilities: [.liveScores, .schedule],
        authenticationType: .none,
        isEnabled: true,
        requestTimeout: 1
    )
    let scoreResult: Result<[StadiaGame], Error>
    let scheduleGames: [StadiaGame]

    func liveScores(for league: League) async throws -> [StadiaGame] {
        try scoreResult.get()
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:scoreScheduleMock:\(league.stadiaKey)"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: scheduleGames,
            provenance: DataProvenance(provider: .appleSports, fetchedAt: Date(), providerEntityID: nil, confidence: 1)
        )
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

private struct MockScheduleSnapshotProvider: ScoreProvider, ScheduleProvider {
    let metadata = SportsDataProviderMetadata(
        id: .mlb,
        name: "MLB schedule mock",
        supportLevel: .official,
        supportedSports: [.baseball],
        supportedLeagues: ["*"],
        capabilities: [.liveScores, .schedule],
        authenticationType: .none,
        isEnabled: true,
        requestTimeout: 1
    )
    let capture: SportsScheduleRangeCapture

    func liveScores(for league: League) async throws -> [StadiaGame] {
        []
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> StadiaSchedule {
        await capture.set(range)
        return StadiaSchedule(
            id: StadiaEntityID(rawValue: "schedule:mock:\(league.stadiaKey)"),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            range: range,
            games: [],
            provenance: DataProvenance(provider: .mlb, fetchedAt: Date(), providerEntityID: nil, confidence: 1)
        )
    }
}

private actor SportsScheduleRangeCapture {
    private(set) var range: SportsDateRange?

    func set(_ range: SportsDateRange) {
        self.range = range
    }
}

private actor SportsCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
