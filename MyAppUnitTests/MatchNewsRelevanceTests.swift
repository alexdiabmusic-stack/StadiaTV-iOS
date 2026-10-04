import Foundation
import Testing
@testable import BannerTV

@Suite("MatchNewsRelevance")
struct MatchNewsRelevanceTests {

    private var nhl: League { League.all.first { $0.path == "hockey/nhl" }! }
    private var nba: League { League.all.first { $0.path == "basketball/nba" }! }

    private func match(league: League, home: String, homeAbbr: String, away: String, awayAbbr: String) -> Match {
        func nickname(_ fullName: String) -> String { String(fullName.split(separator: " ").last ?? Substring(fullName)) }
        return Match(
            id: "test-\(Int.random(in: 0..<Int.max))",
            league: league, date: Date(), name: "\(away) at \(home)", shortName: "\(awayAbbr) @ \(homeAbbr)",
            state: .live, statusDetail: "In Progress",
            home: TeamSide(displayName: home, shortName: nickname(home), abbreviation: homeAbbr, logoURL: nil, score: "1", record: nil, isWinner: false),
            away: TeamSide(displayName: away, shortName: nickname(away), abbreviation: awayAbbr, logoURL: nil, score: "0", record: nil, isWinner: false),
            broadcasts: [], venue: nil
        )
    }

    private func article(headline: String, description: String = "", categories: [String] = [], league: League, published: Date = Date()) -> ESPNArticle {
        ESPNArticle(id: UUID().uuidString, headline: headline, description: description, published: published, url: nil, imageURL: nil, league: league, categories: categories)
    }

    @Test("An unrelated college football article mis-tagged as NHL is rejected")
    func unrelatedArticleRejected() {
        let m = match(league: nhl, home: "Los Angeles Kings", homeAbbr: "LAK", away: "San Jose Sharks", awayAbbr: "SJS")
        let article = article(headline: "Penn State holds off Northwestern in Big Ten thriller",
                               description: "The Nittany Lions' defense forced three turnovers in a tense fourth quarter.",
                               categories: ["NHL"], league: nhl)
        let ranked = MatchNewsRelevance.rank(articles: [article], match: m)
        #expect(ranked.isEmpty, "A mis-tagged college football article must not pass as NHL news just because of its category")
    }

    @Test("An NBA article about the Sacramento Kings is rejected for an NHL LA Kings game")
    func sacramentoKingsRejectedForLAKings() {
        let m = match(league: nhl, home: "Los Angeles Kings", homeAbbr: "LAK", away: "San Jose Sharks", awayAbbr: "SJS")
        let article = article(headline: "Sacramento Kings fall in overtime to the Warriors", league: nba)
        let ranked = MatchNewsRelevance.rank(articles: [article], match: m)
        #expect(ranked.isEmpty, "Nickname-only match ('Kings') must require the article to also contain hockey/NHL context")
    }

    @Test("An article naming both teams ranks above one naming only one team")
    func bothTeamsRanksFirst() {
        let m = match(league: nhl, home: "Los Angeles Kings", homeAbbr: "LAK", away: "San Jose Sharks", awayAbbr: "SJS")
        let bothTeams = article(headline: "Kings vs. Sharks: what to watch", league: nhl)
        let oneTeam = article(headline: "Los Angeles Kings recall forward from AHL", league: nhl)
        let ranked = MatchNewsRelevance.rank(articles: [oneTeam, bothTeams], match: m)
        #expect(ranked.first?.id == bothTeams.id, "The both-teams article should rank first regardless of input order")
    }

    @Test("A league-only article with a league keyword is kept but ranks below team articles")
    func leagueOnlyRanksLast() {
        let m = match(league: nhl, home: "Los Angeles Kings", homeAbbr: "LAK", away: "San Jose Sharks", awayAbbr: "SJS")
        let leagueOnly = article(headline: "NHL announces new playoff format for next season", league: nhl)
        let oneTeam = article(headline: "Los Angeles Kings recall forward from AHL", league: nhl)
        let ranked = MatchNewsRelevance.rank(articles: [leagueOnly, oneTeam], match: m)
        #expect(ranked.map(\.id) == [oneTeam.id, leagueOnly.id])
    }

    @Test("Nothing relevant returns an empty list")
    func nothingRelevantReturnsEmpty() {
        let m = match(league: nhl, home: "Los Angeles Kings", homeAbbr: "LAK", away: "San Jose Sharks", awayAbbr: "SJS")
        let article = article(headline: "Yankees sign free agent pitcher to multi-year deal", league: nhl)
        let ranked = MatchNewsRelevance.rank(articles: [article], match: m)
        #expect(ranked.isEmpty)
    }
}
