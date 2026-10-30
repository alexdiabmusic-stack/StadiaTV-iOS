import Foundation
import Testing
@testable import BannerTV

@Suite("Sports experience integrity")
struct SportsExperienceTests {
    @Test("A generic sport is not sufficient league evidence")
    func genericClassification() {
        let result = BannerNewsDeduplicator.classify(headline: "Basketball players prepare for Sunday", description: nil)
        #expect(result.sport == .basketball)
        #expect(result.leagueID == nil)
        #expect(BannerNewsDeduplicator.classify(headline: "Sunday sports roundup", description: nil).leagueID == nil)
    }

    @Test("Explicit headline evidence overrides misleading feed tags")
    func headlineClassification() throws {
        let nba = try #require(League.all.first { $0.path == "basketball/nba" })
        let result = BannerNewsDeduplicator.classify(headline: "NBA season begins", description: nil, tags: ["NHL"])
        #expect(result.leagueID == SportsIdentityResolver.canonicalLeagueID(for: nba))
    }

    @Test("WNBA is not NBA and mixed competition stories remain broad")
    func leagueBoundaries() throws {
        let wnba = try #require(League.all.first { $0.path == "basketball/wnba" })
        #expect(BannerNewsDeduplicator.classify(headline: "WNBA finals", description: nil).leagueID == SportsIdentityResolver.canonicalLeagueID(for: wnba))
        let mixed = BannerNewsDeduplicator.classify(headline: "NBA and WNBA announce schedules", description: nil)
        #expect(mixed.leagueID == nil)
        #expect(mixed.sport == .basketball)
    }

    @Test("Multi-sport daily roundup does not inherit the only explicit league name")
    func dailyRoundup() throws {
        let nhl = try #require(League.all.first { $0.path == "hockey/nhl" })
        let article = news("Today’s top games: Timberwolves vs Heat, NHL action and more", league: nhl)
        #expect(article.toLegacyArticle(league: nhl).categoryLabel == "Sports")
    }

    @Test("Article projection corrects a conflicting feed and retains publisher")
    func articleProjection() throws {
        let nhl = try #require(League.all.first { $0.path == "hockey/nhl" })
        let article = news("NBA season begins", league: nhl, date: Date().addingTimeInterval(3600))
        let projected = article.toLegacyArticle(league: nhl)
        #expect(projected.league.path == "basketball/nba")
        #expect(projected.categoryLabel == "NBA")
        #expect(projected.publisher == "Example Sports")
        #expect(projected.published == nil)
        #expect(projected.relativePublishedText.isEmpty)
    }

    @Test("Injury and player headlines do not manufacture editorial claims")
    func editorialIntegrity() throws {
        let league = try #require(League.all.first)
        let article = news("Player returns after injury and trade", league: league).toLegacyArticle(league: league)
        #expect(!article.isHighlight)
        #expect(article.badgeText == nil)
    }

    @Test("Broad metadata never inherits the requested competition")
    func broadCategory() throws {
        let league = try #require(League.all.first { $0.group == .soccer })
        var article = news("Transfer news", league: nil)
        article.primarySport = .soccer
        #expect(article.toLegacyArticle(league: league).categoryLabel == "Soccer")
    }

    @Test("Canonical URLs remove tracking without collapsing case-sensitive paths")
    func canonicalURLs() {
        let a = news("First story", url: "https://example.test/Story?id=1&utm_source=a")
        let b = news("Same URL different headline", url: "https://example.test/Story?id=1&utm_source=b")
        let c = news("Different path", url: "https://example.test/story?id=1")
        #expect(BannerNewsDeduplicator.deduplicate([a, b, c]).count == 2)
    }

    @Test("Unicode titles and distinct headline suffixes are preserved")
    func headlineDeduplication() {
        let articles = [
            news("試合結果"), news("選手情報"),
            news("Season preview - East"), news("Season preview - West")
        ]
        #expect(BannerNewsDeduplicator.deduplicate(articles).count == 4)
    }

    @MainActor @Test("F1 practice and qualifying use event presentation; team sports retain matchups",
                     arguments: ["racing/f1", "golf/pga", "hockey/nhl", "basketball/nba", "soccer/eng.1"])
    func eventPresentation(path: String) throws {
        let league = try #require(League.all.first { $0.path == path })
        let side = TeamSide(displayName: "", shortName: "", abbreviation: "", logoURL: nil, score: nil, record: nil, isWinner: false)
        for title in ["Practice 1", "Qualifying"] {
            let match = Match(id: title, league: league, date: Date(), name: title, shortName: title,
                              state: .pre, statusDetail: "Scheduled", home: side, away: side, broadcasts: [], venue: nil)
            #expect(GameCentreArchetype(match: match).usesHeadToHeadParticipantUI == ![SportGroup.racing, .golf].contains(league.group))
        }
    }

    @Test("Guide clips cross-midnight programmes and preserves short adjacent slots")
    func guideGeometry() throws {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(23 * 3600)
        let frame = try #require(GuideProgrammeGeometry.frame(start: start.addingTimeInterval(-3600),
            end: start.addingTimeInterval(1800), windowStart: start, windowEnd: end, pointsPerMinute: 3))
        #expect(frame.x == 0)
        #expect(frame.width == 90)
        let short = try #require(GuideProgrammeGeometry.frame(start: start, end: start.addingTimeInterval(60),
            windowStart: start, windowEnd: end, pointsPerMinute: 3))
        #expect(short.width == 3)
        #expect(GuideProgrammeGeometry.frame(start: end, end: start,
            windowStart: start, windowEnd: end, pointsPerMinute: 3) == nil)
        let entireDay = try #require(GuideProgrammeGeometry.frame(start: start.addingTimeInterval(-3600),
            end: end.addingTimeInterval(3600), windowStart: start, windowEnd: end, pointsPerMinute: 3))
        #expect(entireDay.width == 23 * 60 * 3)
    }

    @Test("Exceptional provider states survive the legacy pregame summary",
          arguments: ["Postponed", "Cancelled", "Delayed", "Suspended"])
    func exceptionalStates(detail: String) throws {
        let league = try #require(League.all.first)
        let side = TeamSide(displayName: "", shortName: "", abbreviation: "", logoURL: nil,
                            score: nil, record: nil, isWinner: false)
        let match = Match(id: detail, league: league, date: Date(), name: detail, shortName: detail,
                          state: .pre, statusDetail: detail, home: side, away: side, broadcasts: [], venue: nil)
        #expect(BannerGameStatus(presentationOf: match).rawValue == detail.lowercased())
    }

    @Test("Guide search recognizes channel prefixes without matching inside unrelated names")
    func guideSearch() {
        #expect(GuideSearchQuery("TSN").matches("CA TSN1 HD"))
        #expect(!GuideSearchQuery("TSN").matches("Sportsnet East"))
        #expect(GuideSearchQuery("sports centre").matches("Sports Centre Live"))
        #expect(GuideSearchQuery("tele").matches("Télé Sport"))
    }

    private func news(_ title: String, league: League? = nil, date: Date? = nil, url: String? = nil) -> BannerNewsArticle {
        BannerNewsArticle(id: BannerEntityID(rawValue: title), headline: title, description: "", published: date,
                          url: url.flatMap(URL.init(string:)), imageURL: nil,
                          leagueID: league.map { SportsIdentityResolver.canonicalLeagueID(for: $0) },
                          teamIDs: [], playerIDs: [], sourceName: nil, provenance: nil,
                          publisher: "Example Sports", authorByline: "Reporter")
    }
}
