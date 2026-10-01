import Foundation
import Testing
@testable import BannerTV   // StreamLinker.swift is Foundation-only; import whichever module you put it in

// Golden tests built from REAL guide titles and channel names taken from a live Xtream playlist
// (guide checked 2026-09-29). Each case documents what the real data looked like.

private func utc(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
    return f.date(from: s)!
}
private func prog(_ guide: String, _ start: String, _ end: String, _ title: String, _ desc: String? = nil) -> LinkerProgramme {
    LinkerProgramme(guideID: guide, start: utc(start), end: utc(end), title: title, desc: desc)
}

private let streams: [LinkerStream] = [
    .init(id: "espn-hd", name: "US ★ ESPN HD ◉", category: "US ❖ SPORTS", guideID: "ESPN.us"),
    .init(id: "espn-fhd", name: "US ★ ESPN FHD", category: "US ❖ SPORTS", guideID: "ESPN.us"),               // mirror of the same feed
    .init(id: "espn3-nl", name: "NL ★ ESPN 3 UHD", category: "NL ❖ SPORT", guideID: "ESPN3.nl"),
    .init(id: "premier-uk", name: "UK ★ PREMIER SPORTS 1", category: "UK ❖ SPORTS", guideID: "PremierSports1.uk"),
    .init(id: "skymix-de", name: "DE ★ SKY SPORT MIX 4K", category: "DE ❖ SPORT", guideID: "SkySportMix.de"),
    .init(id: "sporttv-pt", name: "PT ★ SPORT TV 2", category: "PT ❖ ESPORTES", guideID: "SPORTTV2.pt"),
    .init(id: "bein-fr", name: "FR ★ BEIN SPORTS 1 HD", category: "FR ❖ SPORTS", guideID: "beINSPORTS1.fr"),
    .init(id: "tnt-us", name: "US ★ TNT [EAST]", category: "US ❖ SPORTS", guideID: "TNT.us"),
    .init(id: "tnt-es", name: "ES ★ TNT", category: "ES ❖ SPORT", guideID: "TNT.es"),                       // a different network with the same name
    .init(id: "mlb01", name: "US ★ MLB 01: PHILADELPHIA PHILLIES @ ATLANTA BRAVES 2:00 PM ET", category: "US ❖ MLB", guideID: "MLB.01"),
    .init(id: "mlb-stale", name: "US ★ MLB 02: TORONTO BLUE JAYS @ BALTIMORE ORIOLES 7:35 PM ET", category: "US ❖ MLB", guideID: "MLB.02"),
    .init(id: "sox", name: "US ★ MLB TEAMS : Boston Red Sox HD", category: "US ❖ MLB", guideID: "BostonRedSox.mlb"),
    .init(id: "kings", name: "US ★ LOS ANGELES KINGS HD", category: "US ❖ NHL TEAMS", guideID: nil),
    .init(id: "grid", name: "US ★ SPORTS GRID HD", category: "US ❖ SPORTS", guideID: "SportsGrid.us"),
    .init(id: "spectrum", name: "US ★ SPECTRUM NEWS 1 [NEW YORK]", category: "US ❖ NEWS", guideID: "SpectrumNews1NewYork.us"),
    .init(id: "sny", name: "US ★ SNY HD", category: "US ❖ SPORTS", guideID: "SNY.us"),
    .init(id: "sky-arena", name: "IT ★ SKY SPORT ARENA", category: "IT ❖ SPORT", guideID: "SkySportArena.it"),
    .init(id: "ziggo", name: "NL ★ ZIGGO SPORT 2", category: "NL ❖ SPORT", guideID: "ZiggoSport2.nl"),
    .init(id: "cytavision", name: "GR ★ CYTAVISION SPORTS 4", category: "GR ❖ SPORT", guideID: "CytavisionSports4.cy"),
    .init(id: "polsat", name: "PL ★ POLSAT SPORT", category: "PL ❖ SPORT", guideID: "PolsatSport1.pl"),
    .init(id: "bg", name: "BG ★ DIEMA SPORT", category: "BG ❖ SPORT", guideID: "DiemaSport.bg"),
    .init(id: "laliga-tv", name: "ES ★ LALIGA HYPERMOTION TV 2", category: "ES ❖ SPORT", guideID: "LaLigaSmartbankTV2.es"),
]

private let programmes: [LinkerProgramme] = [
    // NHL: Florida Panthers at Carolina Hurricanes, kickoff 2026-09-29T21:00Z
    prog("ESPN.us", "2026-09-29T21:00Z", "2026-09-30T00:00Z", "NHL Hockey : Florida Panthers at Carolina Hurricanes ᴸᶦᵛᵉ",
         "The Carolina Hurricanes host the Florida Panthers in an Eastern Conference game at Lenovo Center in Raleigh, North Carolina."),
    prog("ESPN3.nl", "2026-09-29T21:00Z", "2026-09-30T00:00Z", "NHL : Carolina Hurricanes - Florida Panthers"),
    prog("PremierSports1.uk", "2026-09-29T21:00Z", "2026-09-30T00:00Z", "NHL Hockey : Florida Panthers at Carolina Hurricanes ᴸᶦᵛᵉ"),
    prog("SkySportMix.de", "2026-09-29T20:55Z", "2026-09-30T00:00Z", "Live NHL: Florida Panthers @ Carolina Hurricanes : Carolina Hurricanes - Florida Panthers", "Aus dem Lenovo Center in Raleigh, North Carolina, USA."),
    prog("SPORTTV2.pt", "2026-09-29T21:00Z", "2026-09-30T00:00Z", "Hoquei No Gelo - NHL - Carolina Hurricanes x Florida Panthers (Live) : ter 29-09"),
    prog("beINSPORTS1.fr", "2026-09-29T21:00Z", "2026-09-30T00:00Z", "Hockey sur glace : NHL ᴺᵉʷ", "Carolina Hurricanes v Florida Panthers\nRetransmission d'un match de NHL, la présentation..."),
    prog("TNT.us", "2026-09-29T21:00Z", "2026-09-30T00:00Z", "SportsCenter Special"),
    // NHL: Pittsburgh Penguins at Philadelphia Flyers 2026-09-30T23:30Z on TNT (a different game)
    prog("TNT.us", "2026-09-30T23:30Z", "2026-10-01T02:00Z", "NHL Hockey : Pittsburgh Penguins at Philadelphia Flyers ᴸᶦᵛᵉ"),
    // MLS-style team channel with placeholders around the real listing (St. Louis CITY SC at Red Bull New York 2026-09-30T23:30Z)
    prog("BostonRedSox.mlb", "2026-09-29T19:00Z", "2026-09-30T23:00Z", "Next Game: Boston Red Sox @ New York Yankees on 2026-09-30 at 03:33AM EDT"),
    prog("BostonRedSox.mlb", "2026-09-30T00:00Z", "2026-09-30T03:00Z", "Boston Red Sox @ New York Yankees  ᴸᶦᵛᵉ"),
    prog("SportsGrid.us", "2026-09-30T00:00Z", "2026-09-30T03:00Z", "Boston Red Sox vs. New York Yankees MLB Baseball Playoffs In-Game Live Gameday"),
    prog("SpectrumNews1NewYork.us", "2026-09-30T23:00Z", "2026-10-01T00:00Z", "Inside City Hall  ᴺᵉʷ", "Errol Louis interviews public officials about New York City politics."),
    prog("SNY.us", "2026-09-30T23:00Z", "2026-10-01T02:00Z", "Mets Classics : 2015: New York Mets vs. Washington Nationals", "Flores Walk-Off from July 31, 2015."),
    // national teams, many languages: Croatia at Spain 2026-09-29T18:45Z
    prog("SkySportArena.it", "2026-09-29T18:45Z", "2026-09-29T21:00Z", "Spagna - Croazia  ᴸᶦᵛᵉ"),
    prog("ZiggoSport2.nl", "2026-09-29T18:45Z", "2026-09-29T21:00Z", "UEFA Nations League : Spanje - Kroatië"),
    prog("CytavisionSports4.cy", "2026-09-29T18:45Z", "2026-09-29T21:00Z", "Ισπανία - Κροατία : UEFA Nations League 2026/27"),
    prog("PolsatSport1.pl", "2026-09-29T18:45Z", "2026-09-29T21:00Z", "Piłka nożna: Liga Narodów - mecz: Hiszpania - Chorwacja  ᴸᶦᵛᵉ"),
    // Cyrillic: Iceland at Luxembourg
    prog("DiemaSport.bg", "2026-09-29T18:45Z", "2026-09-29T21:00Z", "Люксембург - Исландия. 2 кръг, Футбол: УЕФА Лига на нациите 2026/2027, директно"),
    // club name variant: CD Sabadell at RC Celta Fortuna 2026-09-26T16:30Z
    prog("LaLigaSmartbankTV2.es", "2026-09-26T16:30Z", "2026-09-26T18:30Z", "LALIGA HYPERMOTION (T26/27): RC Celta B - CE Sabadell  ᴸᶦᵛᵉ"),
]

private let linker = StreamLinker(streams: streams, programmes: programmes)

private func nhl(_ home: String, _ homeNick: String, _ homeCity: String, _ away: String, _ awayNick: String, _ awayCity: String, _ kickoff: String, _ broadcasts: [String] = []) -> LinkerEvent {
    LinkerEvent(id: "e", league: "hockey/nhl", kickoff: utc(kickoff),
                home: .init(name: home, short: homeNick, nick: homeNick, city: homeCity), away: .init(name: away, short: awayNick, nick: awayNick, city: awayCity), broadcasts: broadcasts)
}

@Suite("StreamLinker — real-data golden tests")
struct StreamLinkerTests {

    private let panthers = nhl("Carolina Hurricanes", "Hurricanes", "Carolina", "Florida Panthers", "Panthers", "Florida", "2026-09-29T21:00Z", ["ESPN"])

    @Test("A live listing whose DESCRIPTION contains 'at <stadium>' is still confirmed (the shipped matcher rejected this)")
    func descriptionDoesNotBreakTitleMatch() {
        let feeds = linker.link(panthers)
        let espn = feeds.first { $0.key == "g:espn.us" }
        #expect(espn?.tier == .liveListing)
        #expect((espn?.confidence ?? 0) >= 0.9)
        #expect(espn?.streamIDs.count == 2, "both mirrors of the feed are returned")
    }

    @Test("Same game, other languages and separators: 'A - B', 'A @ B', 'A x B'")
    func otherSeparatorsAndLanguages() {
        let keys = Set(linker.link(panthers).filter { $0.tier == .liveListing }.map(\.key))
        #expect(keys.isSuperset(of: ["g:espn.us", "g:espn3.nl", "g:premiersports1.uk", "g:skysportmix.de", "g:sporttv2.pt"]))
    }

    @Test("Generic title with the fixture only in the description is a lower-confidence description match")
    func descriptionOnlyListing() {
        let bein = linker.link(panthers).first { $0.key == "g:beinsports1.fr" }
        #expect(bein?.tier == .listingByDescription)
        #expect((bein?.confidence ?? 1) < 0.8)
    }

    @Test("A different game on the same network is not linked")
    func otherGameNotLinked() {
        let tntGames = linker.link(panthers).filter { $0.key == "g:tnt.us" }
        #expect(tntGames.isEmpty)
    }

    @Test("Rights partners respect region and the channel's own guide")
    func rightsAreRegionGated() {
        let kings = nhl("Colorado Avalanche", "Avalanche", "Colorado", "Los Angeles Kings", "Kings", "Los Angeles", "2026-10-01T02:00Z", ["TNT", "truTV"])
        let feeds = linker.link(kings)
        #expect(feeds.contains { $0.key == "r:tnt.us" && $0.tier == .likelyRights }, "US TNT's guide ends before kickoff -> likely partner")
        #expect(!feeds.contains { $0.key == "r:tnt.es" }, "TNT Spain is a different network")
        #expect(feeds.contains { $0.key == "t:kings" && $0.tier == .teamChannel }, "dedicated team channel named after a participant")
    }

    @Test("Event-slot channel names are matched, but only when the stated kickoff time agrees")
    func eventChannelNames() {
        let phillies = LinkerEvent(id: "m", league: "baseball/mlb", kickoff: utc("2026-09-29T18:00Z"),
                                   home: .init(name: "Atlanta Braves", short: "Braves", nick: "Braves", city: "Atlanta"), away: .init(name: "Philadelphia Phillies", short: "Phillies", nick: "Phillies", city: "Philadelphia"))
        #expect(linker.link(phillies).contains { $0.key == "n:mlb01" && $0.tier == .eventChannel })          // 2:00 PM ET == 18:00Z
        let wrongTime = LinkerEvent(id: "m2", league: "baseball/mlb", kickoff: utc("2026-09-29T23:30Z"),
                                    home: .init(name: "Atlanta Braves", short: "Braves", nick: "Braves", city: "Atlanta"), away: .init(name: "Philadelphia Phillies", short: "Phillies", nick: "Phillies", city: "Philadelphia"))
        #expect(!linker.link(wrongTime).contains { $0.key == "n:mlb01" })
    }

    @Test("Placeholders, replays and coverage shows are not confirmations")
    func noiseIsRejectedOrDemoted() {
        let sox = LinkerEvent(id: "s", league: "baseball/mlb", kickoff: utc("2026-09-30T00:00Z"),
                              home: .init(name: "New York Yankees", short: "Yankees", nick: "Yankees", city: "New York"), away: .init(name: "Boston Red Sox", short: "Red Sox", nick: "Red Sox", city: "Boston"))
        let feeds = linker.link(sox)
        #expect(feeds.first { $0.key == "g:bostonredsox.mlb" }?.tier == .liveListing, "the real listing beats the 'Next Game' placeholder around it")
        #expect(feeds.first { $0.key == "g:sportsgrid.us" }?.tier == .coverage, "'In-Game Live' analysis is demoted")

        let mets = LinkerEvent(id: "r", league: "baseball/mlb", kickoff: utc("2026-09-30T23:30Z"),
                               home: .init(name: "Washington Nationals", short: "Nationals", nick: "Nationals", city: "Washington"), away: .init(name: "New York Mets", short: "Mets", nick: "Mets", city: "New York"))
        #expect(!linker.link(mets).contains { $0.key == "g:sny.us" }, "'Classics' is a replay")
    }

    @Test("Bare place words never confirm a game: 'Louis' and 'York' inside a news description")
    func placeWordsAreNotAliases() {
        let stlouis = LinkerEvent(id: "m", league: "soccer/usa.1", kickoff: utc("2026-09-30T23:30Z"),
                                  home: .init(name: "Red Bull New York", short: "Red Bull New York"), away: .init(name: "St. Louis CITY SC", short: "St. Louis CITY SC", nick: "CITY SC", city: "St. Louis"))
        #expect(!linker.link(stlouis).contains { $0.key == "g:spectrumnews1newyork.us" })
    }

    @Test("National teams are matched in Italian, Dutch, Greek, Polish")
    func nationalTeamsInEveryLanguage() {
        let ev = LinkerEvent(id: "n", league: "soccer/uefa.nations", kickoff: utc("2026-09-29T18:45Z"), home: .init(name: "Spain", short: "Spain"), away: .init(name: "Croatia", short: "Croatia"), isNational: true)
        let keys = Set(linker.link(ev).filter { $0.tier == .liveListing }.map(\.key))
        #expect(keys.isSuperset(of: ["g:skysportarena.it", "g:ziggosport2.nl", "g:cytavisionsports4.cy", "g:polsatsport1.pl"]))
    }

    @Test("Non-Latin scripts (Cyrillic) work")
    func cyrillic() {
        let ev = LinkerEvent(id: "n", league: "soccer/uefa.nations", kickoff: utc("2026-09-29T18:45Z"), home: .init(name: "Luxembourg", short: "Luxembourg"), away: .init(name: "Iceland", short: "Iceland"), isNational: true)
        #expect(linker.link(ev).contains { $0.key == "g:diemasport.bg" && $0.tier == .liveListing })
    }

    @Test("Club-name variants ('Celta B' vs 'RC Celta Fortuna') match through the fuzzy fixture fallback")
    func fuzzyClubNames() {
        let ev = LinkerEvent(id: "c", league: "soccer/esp.2", kickoff: utc("2026-09-26T16:30Z"), home: .init(name: "RC Celta Fortuna", short: "Celta Fortuna"), away: .init(name: "CD Sabadell", short: "Sabadell"))
        let f = linker.link(ev).first { $0.key == "g:laligasmartbanktv2.es" }
        #expect(f != nil && f!.confidence >= 0.7)
    }

    @Test("Feeds collapse into families and mirrors are ordered best-quality first")
    func familiesAndMirrors() {
        let feeds = linker.link(panthers)
        let families = feeds.groupedByFamily()
        #expect(families.count <= feeds.count)
        #expect(feeds.first { $0.key == "g:espn.us" }?.streamIDs.first == "espn-fhd")
    }
}
