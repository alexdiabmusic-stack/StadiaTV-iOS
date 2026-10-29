import Foundation
import Testing
@testable import BannerTV

@Suite("Champions League integrity")
struct ChampionsLeagueProviderTests {
    @Test("Provider timestamps accept whole and fractional seconds")
    func dates() {
        #expect(FotMobDate.parse("2026-10-28T19:00:00Z") != nil)
        #expect(FotMobDate.parse("2026-10-28T19:00:00.000Z") == FotMobDate.parse("2026-10-28T19:00:00Z"))
        #expect(FotMobDate.parse("unknown") == nil)
    }

    @Test("Postponed fixtures do not become scheduled when started is false")
    func postponed() throws {
        let raw = try JSONDecoder().decode(FotMobValue.self, from: Data(#"{"started":false,"reason":{"shortKey":"postponed"}}"#.utf8))
        #expect(FotMobStatusMapper.status(raw) == .postponed)
    }

    @Test("Fixture mapping preserves IDs, score and missing fields")
    func fixtures() throws {
        let raw = try JSONDecoder().decode(FotMobValue.self, from: Data(#"{"id":"example-42","home":{"id":"1","name":"Home","shortName":"H"},"away":{"id":"2","name":"Away","shortName":"A"},"status":{"utcTime":"2026-10-28T19:00:00Z","finished":true,"scoreStr":"2 - 1"}}"#.utf8))
        let match = try #require(ChampionsLeagueMapper.match(raw))
        #expect(match.league.path == "soccer/uefa.champions")
        #expect(match.state == .final)
        #expect(match.statusDetail == String(localized: "Final"))
        #expect(match.home.score == "2")
        #expect(match.away.score == "1")
        #expect(match.canonicalID?.contains(":fotmob:example-42") == true)
        #expect(ChampionsLeagueMapper.match(.null) == nil)
        #expect(ChampionsLeagueMapper.team(.object(["name": .string("Missing ID")])) == nil)
    }

    @Test("Mixed competition roundup cannot inherit an NHL feed label")
    func mixedEditorial() throws {
        let league = try #require(League.all.first { $0.path == "hockey/nhl" })
        let article = BannerNewsArticle(id: BannerEntityID(rawValue: "mixed"), headline: "World Series Game 3 and Cowboys vs Eagles MNF",
            description: "", published: nil, url: nil, imageURL: nil,
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league), teamIDs: [], playerIDs: [],
            sourceName: nil, provenance: DataProvenance(provider: .cbsRSS, fetchedAt: Date(), providerEntityID: "mixed", confidence: 0.65))
        #expect(article.toLegacyArticle(league: league).categoryLabel == String(localized: "Sports"))
    }
}
