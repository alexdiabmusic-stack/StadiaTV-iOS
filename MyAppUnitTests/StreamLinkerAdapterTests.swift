import Foundation
import Testing
@testable import BannerTV

// Adapter-level ports of the highest-value cases from the old SourceMatcher regression suite
// (removed with SourceMatcher — see MatchLinker/PROMPTS.md, Prompt 2). These exercise the real
// StreamLinker through StreamLinkerAdapters instead of a deleted hand-rolled scorer, covering the
// same class of junk-candidate bugs StreamLinker's own README calls out (CAR/CAR CHASE,
// Van Dyke/VAN, Queens Park Rangers/NY Rangers): whole-word-only matching and shared-token
// disambiguation.

@Suite("StreamLinker adapter regressions")
struct StreamLinkerAdapterTests {

    private let playlistID = UUID()

    private func channel(name: String, group: String = "Sports", guideID: String? = nil) -> Channel {
        Channel(id: UUID().uuidString, name: name, streamURL: URL(string: "https://example.com/s.m3u8")!,
                logoURL: nil, group: group, playlistID: playlistID, playlistName: "Test", tvgId: guideID)
    }

    private func match(league: League, home: String, homeAbbr: String, away: String, awayAbbr: String) -> Match {
        Match(
            id: "test-\(Int.random(in: 0..<Int.max))",
            league: league, date: Date(), name: "\(away) at \(home)", shortName: "\(awayAbbr) @ \(homeAbbr)",
            state: .live, statusDetail: "In Progress",
            home: TeamSide(displayName: home, shortName: home, abbreviation: homeAbbr, logoURL: nil, score: "1", record: nil, isWinner: false),
            away: TeamSide(displayName: away, shortName: away, abbreviation: awayAbbr, logoURL: nil, score: "0", record: nil, isWinner: false),
            broadcasts: [], venue: nil
        )
    }

    private func link(_ match: Match, channels: [Channel]) -> [LinkedFeed] {
        let linker = StreamLinker(streams: channels.map(StreamLinkerAdapters.stream), programmes: [])
        return linker.link(StreamLinkerAdapters.event(match))
    }

    private var eredivisie: League { League.all.first { $0.path == "soccer/ned.1" }! }
    private var epl: League { League.all.first { $0.path == "soccer/eng.1" }! }
    private var nba: League { League.all.first { $0.path == "basketball/nba" }! }

    // MARK: REG-004/005/003 (ported): whole-word-only participant matching

    @Test("'Sparta' must not match 'Spartanburg' via substring")
    func spartaDoesNotMatchSpartanburg() {
        let m = match(league: eredivisie, home: "PSV", homeAbbr: "PSV", away: "Sparta Rotterdam", awayAbbr: "SPA")
        let feeds = link(m, channels: [channel(name: "CBS 7 Spartanburg")])
        #expect(feeds.isEmpty, "'Sparta Rotterdam' must not substring-match a channel named 'Spartanburg'")
    }

    @Test("'Sparta' must not match 'Isparta' via substring")
    func spartaDoesNotMatchIsparta() {
        let m = match(league: eredivisie, home: "PSV", homeAbbr: "PSV", away: "Sparta Rotterdam", awayAbbr: "SPA")
        let feeds = link(m, channels: [channel(name: "Isparta Sports")])
        #expect(feeds.isEmpty, "'Sparta Rotterdam' must not substring-match a channel named 'Isparta'")
    }

    @Test("Whole-word fixture channel still links Sparta Rotterdam")
    func spartaMatchesWhenWholeWord() {
        let m = match(league: eredivisie, home: "PSV", homeAbbr: "PSV", away: "Sparta Rotterdam", awayAbbr: "SPA")
        let feeds = link(m, channels: [channel(name: "PSV vs Sparta Rotterdam Live")])
        #expect(!feeds.isEmpty, "A channel naming both teams around a separator must still link")
    }

    // MARK: Manchester City / United disambiguation (ported)

    @Test("A channel naming only Manchester City is not a confirmed both-teams link")
    func manchesterCityAloneNotConfirmed() {
        let m = match(league: epl, home: "Manchester City", homeAbbr: "MCI", away: "Manchester United", awayAbbr: "MUN")
        let feeds = link(m, channels: [channel(name: "Manchester City TV")])
        #expect(feeds.allSatisfy { $0.confidence < 0.7 },
                "Naming only one side must never reach the confident (>=0.7) threshold")
    }

    @Test("A channel naming only Manchester United is not a confirmed both-teams link")
    func manchesterUnitedAloneNotConfirmed() {
        let m = match(league: epl, home: "Manchester City", homeAbbr: "MCI", away: "Manchester United", awayAbbr: "MUN")
        let feeds = link(m, channels: [channel(name: "Manchester United Live")])
        #expect(feeds.allSatisfy { $0.confidence < 0.7 },
                "Naming only one side must never reach the confident (>=0.7) threshold")
    }

    @Test("A channel naming both Manchester City and United links both teams")
    func manchesterBothNamedLinks() {
        let m = match(league: epl, home: "Manchester City", homeAbbr: "MCI", away: "Manchester United", awayAbbr: "MUN")
        let feeds = link(m, channels: [channel(name: "Manchester City vs Manchester United Live")])
        #expect(feeds.contains { $0.evidence.localizedCaseInsensitiveContains("manchester city") },
                "A channel explicitly naming both teams around a separator must produce a feed")
    }

    // MARK: Shared city token (ported)

    @Test("Shared city token — bare 'Los Angeles' does not confirm Lakers vs Clippers")
    func sharedCityTokenDoesNotConfirm() {
        let m = match(league: nba, home: "Los Angeles Lakers", homeAbbr: "LAL", away: "Los Angeles Clippers", awayAbbr: "LAC")
        let feeds = link(m, channels: [channel(name: "ABC Los Angeles")])
        #expect(feeds.allSatisfy { $0.confidence < 0.7 },
                "A bare shared city name must not confirm a fixture between two same-city teams")
    }

    @Test("Shared city token — explicit team names still link Lakers vs Clippers")
    func explicitTeamNamesLinkDespiteSharedCity() {
        let m = match(league: nba, home: "Los Angeles Lakers", homeAbbr: "LAL", away: "Los Angeles Clippers", awayAbbr: "LAC")
        let feeds = link(m, channels: [channel(name: "Lakers vs Clippers Live")])
        #expect(feeds.contains { $0.confidence >= 0.7 },
                "Explicit team names on both sides of a separator must produce a confident link")
    }
}
