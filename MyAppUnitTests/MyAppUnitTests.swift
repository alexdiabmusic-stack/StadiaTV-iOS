import Foundation
import Testing
@testable import BannerTV

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

// MARK: - SourceMatcher regression suite

@Suite("SourceMatcher regressions")
struct SourceMatcherRegressionTests {

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

    // MARK: EPG-based confirmation

    @Test("EPG confirmation — guideListsMatch evidence on an opaque channel name is confirmed")
    func epgListsMatchIsConfirmed() {
        var source = RankedSource(channel: channel(name: "SKY SPORT 2"), score: 60)
        source.evidenceCategories = [.guideListsMatch]
        #expect(source.isConfirmed,
                "An EPG guide-matched source must be confirmed even if the channel name is opaque")
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
            func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle] { [] }
        }
        #expect(MockPaginatingProvider().supportsPagination,
                "The default protocol extension must return true for providers that don't override it")
    }
}

// MARK: - Helpers (shared with SourceMatcherRegressionTests via file-private scope)

private let precisionPlaylistID = UUID()

private func pChannel(id: String = UUID().uuidString, name: String, group: String? = "Sports") -> Channel {
    Channel(id: id, name: name, streamURL: URL(string: "https://example.com/stream.m3u8")!,
            logoURL: nil, group: group, playlistID: precisionPlaylistID, playlistName: "PrecisionTest")
}

private func pMatch(
    id: String = "prec-\(Int.random(in: 0..<Int.max))",
    league: League,
    home: String,
    homeShort: String? = nil,
    homeAbbr: String,
    away: String,
    awayShort: String? = nil,
    awayAbbr: String,
    broadcasts: [String] = [],
    name: String = "",
    shortName: String = ""
) -> Match {
    Match(
        id: id,
        league: league,
        date: Date(),
        name: name.isEmpty ? "\(away) at \(home)" : name,
        shortName: shortName.isEmpty ? "\(awayAbbr) @ \(homeAbbr)" : shortName,
        state: .live,
        statusDetail: "In Progress",
        home: TeamSide(displayName: home, shortName: homeShort ?? home, abbreviation: homeAbbr,
                       logoURL: nil, score: "1", record: nil, isWinner: false, teamID: "1"),
        away: TeamSide(displayName: away, shortName: awayShort ?? away, abbreviation: awayAbbr,
                       logoURL: nil, score: "0", record: nil, isWinner: false, teamID: "2"),
        broadcasts: broadcasts,
        venue: nil
    )
}

// MARK: - Precision Stream Matcher Regression Suite (v3)

@Suite("Precision stream matcher regressions (v3)")
struct PrecisionStreamMatcherTests {

    // MARK: MatchStatus

    @Test("MatchStatus: confirmed source maps to .confirmed")
    func matchStatusConfirmedSource() {
        var source = RankedSource(channel: pChannel(name: "Test"), score: 100)
        source.evidenceCategories = [.teamNameMatch]
        #expect(source.matchStatus == .confirmed)
    }

    @Test("MatchStatus: possible source maps to .possible")
    func matchStatusPossibleSource() {
        var source = RankedSource(channel: pChannel(name: "Test"), score: 35)
        source.evidenceCategories = [.broadcastRightsMatch]
        #expect(source.matchStatus == .possible)
    }

    // MARK: MatchPlaybackContext requestGenerationID

    @Test("MatchPlaybackContext: requestGenerationID is unique per context by default")
    func requestGenerationIDIsUnique() {
        let nba = League.all.first { $0.path == "basketball/nba" }!
        let m = pMatch(id: "g-001", league: nba, home: "Lakers", homeAbbr: "LAL",
                       away: "Celtics", awayAbbr: "BOS")
        let ch = pChannel(id: "ch-001", name: "ESPN HD")
        let ctx1 = MatchPlaybackContext(match: m, channel: ch)
        let ctx2 = MatchPlaybackContext(match: m, channel: ch)
        // Two separate context objects must have different generation IDs.
        #expect(ctx1.requestGenerationID != ctx2.requestGenerationID,
                "Each MatchPlaybackContext must get a fresh UUID so stale async results can be detected")
    }

    @Test("MatchPlaybackContext: stable id despite different requestGenerationID")
    func contextIDStableAcrossGenerations() {
        let nba = League.all.first { $0.path == "basketball/nba" }!
        let m = pMatch(id: "g-001", league: nba, home: "Lakers", homeAbbr: "LAL",
                       away: "Celtics", awayAbbr: "BOS")
        let ch = pChannel(id: "ch-001", name: "ESPN HD")
        let ctx1 = MatchPlaybackContext(match: m, channel: ch)
        let ctx2 = MatchPlaybackContext(match: m, channel: ch)
        // `id` is used for SwiftUI identity — it must be deterministic.
        #expect(ctx1.id == ctx2.id,
                "Context id (match+channel) must be stable regardless of requestGenerationID")
    }

}
