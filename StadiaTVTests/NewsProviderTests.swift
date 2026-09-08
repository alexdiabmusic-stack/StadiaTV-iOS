import Testing
import Foundation
@testable import Banner_TV

// MARK: - RSS Parser tests

@Suite("BannerRSSParser")
struct BannerRSSParserTests {

    // Minimal RSS 2.0 fixture
    private static let rss2Fixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>Test Sports</title>
        <item>
          <title>Eagles win Super Bowl in overtime thriller</title>
          <link>https://example.com/eagles-super-bowl</link>
          <guid isPermaLink="true">https://example.com/eagles-super-bowl</guid>
          <description>Philadelphia Eagles claimed their second Lombardi Trophy.</description>
          <pubDate>Mon, 03 Feb 2025 02:30:00 +0000</pubDate>
          <author>Jane Smith</author>
          <category>NFL</category>
          <category>Eagles</category>
          <enclosure url="https://example.com/image.jpg" type="image/jpeg" length="0"/>
        </item>
        <item>
          <title><![CDATA[Chiefs dynasty: can they three-peat?]]></title>
          <link>https://example.com/chiefs-three-peat</link>
          <description><![CDATA[Analysis of the Kansas City Chiefs' chances at a historic three-peat.]]></description>
          <pubDate>Sun, 02 Feb 2025 18:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
    """.data(using: .utf8)!

    // Minimal Atom fixture
    private static let atomFixture = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>NBC Sports</title>
      <entry>
        <id>urn:uuid:nbc-001</id>
        <title>LeBron James scores 40 in Lakers victory</title>
        <link href="https://nbcsports.com/lakers-win" rel="alternate"/>
        <summary>LeBron James put on a show Friday night.</summary>
        <published>2025-02-01T22:00:00Z</published>
        <author><name>Bob Reporter</name></author>
        <category term="NBA"/>
      </entry>
    </feed>
    """.data(using: .utf8)!

    @Test("Parses RSS 2.0 items")
    func parsesRSS2Items() {
        let items = BannerRSSParser.parse(rss2Fixture)
        #expect(items.count == 2)
        #expect(items[0].title == "Eagles win Super Bowl in overtime thriller")
        #expect(items[0].link == "https://example.com/eagles-super-bowl")
        #expect(items[0].author == "Jane Smith")
        #expect(items[0].categories.contains("NFL"))
        #expect(items[0].imageURL == "https://example.com/image.jpg")
        #expect(items[1].title == "Chiefs dynasty: can they three-peat?")
    }

    @Test("Parses Atom feed")
    func parsesAtomFeed() {
        let items = BannerRSSParser.parse(atomFixture)
        #expect(items.count == 1)
        #expect(items[0].title == "LeBron James scores 40 in Lakers victory")
        #expect(items[0].link == "https://nbcsports.com/lakers-win")
        #expect(items[0].author == "Bob Reporter")
        #expect(items[0].guid == "urn:uuid:nbc-001")
    }

    @Test("Parses RFC 822 date")
    func parsesRFC822Date() {
        let date = BannerRSSParser.parseDate("Mon, 03 Feb 2025 02:30:00 +0000")
        #expect(date != nil)
        let comps = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        #expect(comps.month == 2)
        #expect(comps.day == 3)
        #expect(comps.year == 2025)
    }

    @Test("Parses ISO 8601 date")
    func parsesISO8601Date() {
        let date = BannerRSSParser.parseDate("2025-02-01T22:00:00Z")
        #expect(date != nil)
    }

    @Test("Returns nil for nil date")
    func nilDateReturnsNil() {
        #expect(BannerRSSParser.parseDate(nil) == nil)
    }

    @Test("Returns empty array for malformed XML")
    func malformedXMLReturnsEmpty() {
        let bad = "<this is not valid xml <<<".data(using: .utf8)!
        let items = BannerRSSParser.parse(bad)
        #expect(items.isEmpty)
    }

    @Test("XXE prevention: resolveExternalEntities false")
    func xxePrevention() {
        // Feed that embeds an XXE entity reference — must not crash or leak
        let xxeFeed = """
        <?xml version="1.0"?>
        <!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <rss version="2.0"><channel>
          <item><title>&xxe;</title><link>https://example.com</link></item>
        </channel></rss>
        """.data(using: .utf8)!
        // Should not throw or crash; may return zero items or an item with empty title
        let items = BannerRSSParser.parse(xxeFeed)
        // The important invariant: no file system read occurs (title won't be /etc/passwd content)
        for item in items {
            #expect(item.title?.contains("root:") != true)
        }
    }
}

// MARK: - Deduplicator tests

@Suite("BannerNewsDeduplicator")
struct BannerNewsDeduplicatorTests {

    private func makeArticle(
        id: String,
        headline: String,
        url: String? = nil,
        published: Date = Date(),
        provider: SportsDataProviderID = .espn
    ) -> BannerNewsArticle {
        BannerNewsArticle(
            id: BannerEntityID(rawValue: id),
            headline: headline,
            description: "",
            published: published,
            url: url.flatMap(URL.init(string:)),
            imageURL: nil,
            leagueID: nil,
            teamIDs: [],
            playerIDs: [],
            sourceName: nil,
            provenance: DataProvenance(provider: provider, fetchedAt: Date(), providerEntityID: id, confidence: 0.8)
        )
    }

    @Test("Deduplication removes exact URL duplicates")
    func deduplicatesExactURLs() {
        let a1 = makeArticle(id: "a1", headline: "Chiefs win", url: "https://espn.com/article/1")
        let a2 = makeArticle(id: "a2", headline: "Chiefs win", url: "https://espn.com/article/1", provider: .yahooSports)
        let result = BannerNewsDeduplicator.deduplicate([a1, a2])
        #expect(result.count == 1)
    }

    @Test("Deduplication strips UTM parameters before comparing")
    func deduplicatesURLsWithUTMParams() {
        let a1 = makeArticle(id: "b1", headline: "Title", url: "https://example.com/story?utm_source=twitter&utm_medium=social")
        let a2 = makeArticle(id: "b2", headline: "Title", url: "https://example.com/story?utm_campaign=nfl")
        let result = BannerNewsDeduplicator.deduplicate([a1, a2])
        #expect(result.count == 1)
    }

    @Test("Deduplication matches near-identical titles")
    func deduplicatesNearIdenticalTitles() {
        let a1 = makeArticle(id: "c1", headline: "Eagles win Super Bowl in overtime thriller - ESPN")
        let a2 = makeArticle(id: "c2", headline: "Eagles win Super Bowl in overtime thriller | CBS Sports")
        let result = BannerNewsDeduplicator.deduplicate([a1, a2])
        #expect(result.count == 1)
    }

    @Test("Different articles are not removed")
    func doesNotDeduplicateDifferentArticles() {
        let a1 = makeArticle(id: "d1", headline: "Chiefs defeat Eagles 31-14", url: "https://espn.com/1")
        let a2 = makeArticle(id: "d2", headline: "Eagles sign star receiver to extension", url: "https://espn.com/2")
        let result = BannerNewsDeduplicator.deduplicate([a1, a2])
        #expect(result.count == 2)
    }

    @Test("Classification identifies NFL from headline")
    func classifiesNFLFromHeadline() {
        let (_, lid) = BannerNewsDeduplicator.classify(headline: "Chiefs win NFL championship", description: nil)
        let nfl = League.all.first { $0.path == "football/nfl" }
        let expectedID = nfl.map { SportsIdentityResolver.canonicalLeagueID(for: $0) }
        #expect(lid != nil)
        #expect(lid == expectedID)
    }

    @Test("Classification identifies NBA from tags")
    func classifiesNBAFromTags() {
        let (_, lid) = BannerNewsDeduplicator.classify(headline: "Star player drops 40 points", description: nil, tags: ["NBA", "basketball"])
        let nba = League.all.first { $0.path == "basketball/nba" }
        let expectedID = nba.map { SportsIdentityResolver.canonicalLeagueID(for: $0) }
        #expect(lid == expectedID)
    }

    @Test("mergeAndRank respects source diversity cap")
    func mergeAndRankRespectsSourceCap() {
        var espnArticles: [BannerNewsArticle] = (0..<15).map { i in
            makeArticle(id: "e\(i)", headline: "ESPN story \(i)", url: "https://espn.com/\(i)", provider: .espn)
        }
        var cbsArticles: [BannerNewsArticle] = (0..<5).map { i in
            makeArticle(id: "c\(i)", headline: "CBS story \(i)", url: "https://cbssports.com/\(i)", provider: .cbsRSS)
        }
        let nfl = League.all.first { $0.path == "football/nfl" }!
        let collected: [(SportsDataProviderID, [BannerNewsArticle])] = [
            (.espn, espnArticles),
            (.cbsRSS, cbsArticles),
        ]
        let result = BannerNewsDeduplicator.mergeAndRank(collected, league: nfl, limit: 10)
        #expect(result.count <= 10)
        // ESPN shouldn't flood all 10 slots
        let espnCount = result.filter { $0.provenance?.provider == .espn }.count
        #expect(espnCount <= 8)
    }
}

// MARK: - Provider metadata tests

@Suite("NewsProvider metadata")
struct NewsProviderMetadataTests {

    @Test("All new provider IDs are registered in production registry")
    func allProviderIDsInRegistry() {
        let registry = SportsProviderRegistry.production()
        let newIDs: [SportsDataProviderID] = [
            .foxBifrostNews, .cbsRSS, .bbcSport, .skySports,
            .nbcSports, .foxRSS, .bleacherReport,
        ]
        for id in newIDs {
            #expect(registry.provider(id: id) != nil, "\(id.rawValue) missing from production registry")
        }
    }

    @Test("BleacherReport provider is disabled by default")
    func bleacherReportDisabledByDefault() {
        let provider = BleacherReportNewsProvider()
        #expect(provider.metadata.isEnabled == false)
    }

    @Test("News providers support newsMetadata capability")
    func newsProvidersHaveCapability() {
        let providers: [any SportsNewsProvider] = [
            FOXBifrostNewsProvider(),
            CBSRSSNewsProvider(),
            BBCSportNewsProvider(),
            SkySportsNewsProvider(),
            NBCSportsNewsProvider(),
            FOXRSSNewsProvider(),
            BleacherReportNewsProvider(),
        ]
        for p in providers {
            #expect(p.metadata.capabilities.contains(.newsMetadata),
                    "\(p.metadata.name) missing .newsMetadata capability")
        }
    }

    @Test("News providers do not support pagination by default")
    func rssProvidersNoPagination() {
        let providers: [any SportsNewsProvider] = [
            CBSRSSNewsProvider(), BBCSportNewsProvider(),
            SkySportsNewsProvider(), NBCSportsNewsProvider(), FOXRSSNewsProvider(),
        ]
        for p in providers {
            #expect(p.supportsPagination == false,
                    "\(p.metadata.name) should not support pagination")
        }
    }

    @Test("toLegacyArticle preserves publisher in byline")
    func toLegacyArticlePreservesPublisher() {
        let nfl = League.all.first { $0.path == "football/nfl" }!
        let article = BannerNewsArticle(
            id: BannerEntityID(rawValue: "test:1"),
            headline: "Test headline",
            description: "Description",
            published: nil,
            url: URL(string: "https://cbssports.com/test"),
            imageURL: nil,
            leagueID: nil,
            teamIDs: [],
            playerIDs: [],
            sourceName: nil,
            provenance: nil,
            publisher: "CBS Sports",
            articleType: "recap",
            authorByline: nil
        )
        let legacy = article.toLegacyArticle(league: nfl)
        #expect(legacy.byline == "CBS Sports")
        #expect(legacy.type == "recap")
    }
}
