import Foundation
import Testing
@testable import StadiaTV

// MARK: - Helpers

private let playlistID = UUID()

private func channel(id: String = UUID().uuidString, name: String, group: String? = "Sports") -> Channel {
    Channel(id: id, name: name, streamURL: URL(string: "https://example.com/stream.m3u8")!,
            logoURL: nil, group: group, playlistID: playlistID, playlistName: "Test")
}

private func match(
    id: String = "test-\(Int.random(in: 0..<Int.max))",
    league: League,
    home: String,
    homeShort: String? = nil,
    homeAbbr: String,
    away: String,
    awayShort: String? = nil,
    awayAbbr: String,
    broadcasts: [String] = [],
    state: GameState = .live,
    name: String = "",
    shortName: String = ""
) -> Match {
    Match(
        id: id,
        league: league,
        date: Date(),
        name: name.isEmpty ? "\(away) at \(home)" : name,
        shortName: shortName.isEmpty ? "\(awayAbbr) @ \(homeAbbr)" : shortName,
        state: state,
        statusDetail: "In Progress",
        home: TeamSide(displayName: home, shortName: homeShort ?? home, abbreviation: homeAbbr,
                       logoURL: nil, score: "1", record: nil, isWinner: false, teamID: "1"),
        away: TeamSide(displayName: away, shortName: awayShort ?? away, abbreviation: awayAbbr,
                       logoURL: nil, score: "0", record: nil, isWinner: false, teamID: "2"),
        broadcasts: broadcasts,
        venue: nil
    )
}

private var nbaLeague: League { League.all.first { $0.path == "basketball/nba" }! }
private var eplLeague: League { League.all.first { $0.path == "soccer/eng.1" }! }

// MARK: - SourceMatcher regression suite

@Suite("SourceMatcher regressions")
struct SourceMatcherRegressionTests {

    // MARK: Shared city token

    @Test("Shared city token — ABC Los Angeles cannot confirm Lakers vs Clippers")
    func sharedCityTokenDoesNotConfirmEitherTeam() {
        let nba = nbaLeague
        let m = match(league: nba, home: "Los Angeles Lakers", homeAbbr: "LAL",
                      away: "Los Angeles Clippers", awayAbbr: "LAC")
        let result = SourceMatcher.rank(match: m, channels: [
            channel(name: "ABC Los Angeles")
        ])
        // "Los Angeles" is shared — must not produce a both-teams teamNameMatch.
        if let source = result.first {
            #expect(!source.evidenceCategories.contains(.teamNameMatch),
                    "Shared city token must not produce a teamNameMatch confirmation")
        }
    }

    @Test("Shared city token — explicit team name still confirms")
    func explicitTeamNameConfirmsDespiteSharedCity() {
        let nba = nbaLeague
        let m = match(league: nba, home: "Los Angeles Lakers", homeAbbr: "LAL",
                      away: "Los Angeles Clippers", awayAbbr: "LAC")
        let result = SourceMatcher.rank(match: m, channels: [
            channel(name: "Lakers vs Clippers Live")
        ])
        // Both distinct tokens (Lakers, Clippers) appear → must confirm via teamNameMatch.
        #expect(result.first?.evidenceCategories.contains(.teamNameMatch) == true,
                "Explicit team names present in both halves must confirm via teamNameMatch")
    }

    // MARK: ESPN+ normalization

    @Test("ESPN+ normalization — ESPN+ broadcast must not match plain ESPN channel")
    func espnPlusDoesNotMatchESPN() {
        let nba = nbaLeague
        let m = match(league: nba, home: "Lakers", homeAbbr: "LAL",
                      away: "Celtics", awayAbbr: "BOS", broadcasts: ["ESPN+"])
        let ranked = SourceMatcher.rank(match: m, channels: [
            channel(name: "ESPN HD")
        ])
        let espnChannel = ranked.first(where: { $0.channel.name == "ESPN HD" })
        // If normalize("ESPN+") == normalize("ESPN"), the rights match fires on "ESPN HD" — the bug.
        let rightsMatchFired = espnChannel?.evidenceCategories.contains(.broadcastRightsMatch) ?? false
        #expect(!rightsMatchFired,
                "normalize('ESPN+') must produce 'espnplus', not 'espn' — plain ESPN HD must not receive broadcastRightsMatch from an ESPN+ broadcast listing")
    }

    @Test("ESPN+ normalization — ESPN+ broadcast matches ESPN+ channel")
    func espnPlusMatchesESPNPlusChannel() {
        let nba = nbaLeague
        let m = match(league: nba, home: "Lakers", homeAbbr: "LAL",
                      away: "Celtics", awayAbbr: "BOS", broadcasts: ["ESPN+"])
        let ranked = SourceMatcher.rank(match: m, channels: [
            channel(name: "ESPN+ HD")
        ])
        let espnPlusChannel = ranked.first(where: { $0.channel.name == "ESPN+ HD" })
        #expect(espnPlusChannel?.evidenceCategories.contains(.broadcastRightsMatch) == true,
                "ESPN+ broadcast listing must match a channel named 'ESPN+ HD'")
    }

    // MARK: isConfirmed semantics

    @Test("isConfirmed — teamNameMatch evidence confirms")
    func teamNameMatchConfirms() {
        var source = RankedSource(channel: channel(name: "Test"), score: 100)
        source.evidenceCategories = [.teamNameMatch]
        #expect(source.isConfirmed)
    }

    @Test("isConfirmed — guideListsMatch confirms")
    func guideListsMatchConfirms() {
        var source = RankedSource(channel: channel(name: "Test"), score: 80)
        source.evidenceCategories = [.guideListsMatch]
        #expect(source.isConfirmed)
    }

    @Test("isConfirmed — eventTitleMatch confirms")
    func eventTitleMatchConfirms() {
        var source = RankedSource(channel: channel(name: "Test"), score: 80)
        source.evidenceCategories = [.eventTitleMatch]
        #expect(source.isConfirmed)
    }

    @Test("isConfirmed — broadcastRightsMatch alone does not confirm")
    func broadcastRightsOnlyNotConfirmed() {
        var source = RankedSource(channel: channel(name: "Test"), score: 35)
        source.evidenceCategories = [.broadcastRightsMatch]
        #expect(!source.isConfirmed)
    }

    @Test("isConfirmed — leagueKeyword alone does not confirm")
    func leagueKeywordOnlyNotConfirmed() {
        var source = RankedSource(channel: channel(name: "Test"), score: 20)
        source.evidenceCategories = [.leagueKeyword]
        #expect(!source.isConfirmed)
    }

    @Test("isConfirmed — networkNameMatch alone does not confirm")
    func networkNameMatchOnlyNotConfirmed() {
        var source = RankedSource(channel: channel(name: "Test"), score: 5)
        source.evidenceCategories = [.networkNameMatch]
        #expect(!source.isConfirmed)
    }

    // MARK: Stream count semantics

    @Test("Stream count — rights-only candidate is not counted as confirmed")
    func rightsOnlyCandidateNotConfirmed() {
        let nba = nbaLeague
        let m = match(league: nba, home: "Lakers", homeAbbr: "LAL",
                      away: "Celtics", awayAbbr: "BOS", broadcasts: ["TNT"])
        let ranked = SourceMatcher.rank(match: m, channels: [
            channel(name: "TNT HD")
        ])
        let confirmed = ranked.filter(\.isConfirmed)
        if !ranked.isEmpty {
            #expect(confirmed.isEmpty,
                    "A channel matched only by broadcast rights must not appear in the confirmed count")
        }
    }

    // MARK: Non-sports channel filter

    @Test("Non-sports filter — news channel is excluded before scoring")
    func newsChannelFiltered() {
        let nba = nbaLeague
        let m = match(league: nba, home: "Lakers", homeAbbr: "LAL",
                      away: "Celtics", awayAbbr: "BOS", broadcasts: ["ESPN"])
        let ranked = SourceMatcher.rank(match: m, channels: [
            channel(name: "ESPN News")
        ])
        #expect(ranked.isEmpty, "ESPN News must be excluded by the nonSportsNameTokens filter")
    }

    @Test("Non-sports filter — weather channel is excluded")
    func weatherChannelFiltered() {
        let epl = eplLeague
        let m = match(league: epl, home: "Arsenal", homeAbbr: "ARS",
                      away: "Chelsea", awayAbbr: "CHE")
        let ranked = SourceMatcher.rank(match: m, channels: [
            channel(name: "Sky Weather")
        ])
        #expect(ranked.isEmpty, "Weather channel must be excluded by the nonSportsNameTokens filter")
    }

    @Test("Non-sports filter — cooking channel is excluded")
    func cookingChannelFiltered() {
        let epl = eplLeague
        let m = match(league: epl, home: "Arsenal", homeAbbr: "ARS",
                      away: "Chelsea", awayAbbr: "CHE")
        let ranked = SourceMatcher.rank(match: m, channels: [
            channel(name: "Food Network Cooking")
        ])
        #expect(ranked.isEmpty, "Cooking channel must be excluded by the nonSportsNameTokens filter")
    }

    // MARK: EPG-based confirmation

    @Test("EPG confirmation — guideListsMatch evidence on an opaque channel name is confirmed")
    func epgListsMatchIsConfirmed() {
        var source = RankedSource(channel: channel(name: "SKY SPORT 2"), score: 60)
        source.evidenceCategories = [.guideListsMatch]
        #expect(source.isConfirmed,
                "An EPG guide-matched source must be confirmed even if the channel name is opaque")
    }

    @Test("EPG conflict — league-keyword-only channel is not confirmed")
    func leagueKeywordChannelNotConfirmed() {
        let epl = eplLeague
        let m = match(league: epl, home: "Arsenal", homeAbbr: "ARS",
                      away: "Chelsea", awayAbbr: "CHE")
        let ranked = SourceMatcher.rank(match: m, channels: [
            channel(name: "Sky Sports Premier League")
        ])
        if let source = ranked.first {
            #expect(!source.isConfirmed,
                    "League-keyword match only must not be confirmed")
        }
    }

    // MARK: MatchPlaybackContext identity

    @Test("MatchPlaybackContext — same match+channel produces stable ID")
    func contextIDIsStable() {
        let nba = nbaLeague
        let m = match(id: "game-001", league: nba, home: "Lakers", homeAbbr: "LAL",
                      away: "Celtics", awayAbbr: "BOS")
        let ch = channel(id: "ch-001", name: "ESPN HD")
        let ctx1 = MatchPlaybackContext(match: m, channel: ch)
        let ctx2 = MatchPlaybackContext(match: m, channel: ch)
        #expect(ctx1.id == ctx2.id)
    }

    @Test("MatchPlaybackContext — different matches produce different IDs")
    func contextIDDistinguishesByMatch() {
        let nba = nbaLeague
        let m1 = match(id: "game-001", league: nba, home: "Lakers", homeAbbr: "LAL",
                       away: "Celtics", awayAbbr: "BOS")
        let m2 = match(id: "game-002", league: nba, home: "Knicks", homeAbbr: "NYK",
                       away: "Bulls", awayAbbr: "CHI")
        let ch = channel(id: "ch-001", name: "ESPN HD")
        #expect(MatchPlaybackContext(match: m1, channel: ch).id !=
                MatchPlaybackContext(match: m2, channel: ch).id)
    }

    @Test("MatchPlaybackContext — selectedSource prefers the context channel")
    func contextSelectedSourcePrefersPassedChannel() throws {
        let nba = nbaLeague
        let m = match(id: "game-001", league: nba, home: "Lakers", homeAbbr: "LAL",
                      away: "Celtics", awayAbbr: "BOS")
        let ch1 = channel(id: "ch-001", name: "ESPN HD")
        let ch2 = channel(id: "ch-002", name: "NBA TV")
        var s1 = RankedSource(channel: ch1, score: 80); s1.evidenceCategories = [.teamNameMatch]
        var s2 = RankedSource(channel: ch2, score: 40); s2.evidenceCategories = [.leagueKeyword]
        let ctx = MatchPlaybackContext(match: m, channel: ch1, rankedSources: [s1, s2])
        let selected = try #require(ctx.selectedSource)
        #expect(selected.channel.id == ch1.id)
    }
}

// MARK: - News pagination regressions

@Suite("News pagination regressions")
struct NewsPaginationTests {

    @Test("Yahoo — supportsPagination is false")
    func yahooDoesNotSupportPagination() {
        let yahoo = YahooSportsProvider()
        #expect(!yahoo.supportsPagination,
                "YahooSportsProvider must declare supportsPagination = false so page-2+ requests skip it")
    }

    @Test("Default supportsPagination — protocol extension defaults to true")
    func defaultSupportsPaginationIsTrue() {
        struct MockPaginatingProvider: SportsNewsProvider {
            var metadata: SportsDataProviderMetadata {
                SportsDataProviderMetadata(
                    id: .espn,
                    name: "Mock",
                    supportLevel: .official,
                    supportedSports: [],
                    supportedLeagues: [],
                    capabilities: [.newsMetadata],
                    authenticationType: .none,
                    isEnabled: true,
                    requestTimeout: 10
                )
            }
            func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [StadiaNewsArticle] { [] }
        }
        #expect(MockPaginatingProvider().supportsPagination,
                "The default protocol extension must return true for providers that don't override it")
    }
}
