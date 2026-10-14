import Foundation
import Testing
@testable import BannerTV

@Suite("CarPlay foundation")
struct CarPlayFoundationTests {
    @Test("Unrelated channels stay excluded even in a sports group",
          arguments: ["CNN News", "Disney Junior", "CPAC", "CNBC", "Cartoon Network"])
    func excludesUnrelatedChannels(_ name: String) {
        #expect(!BannerSportsChannelClassifier.isSportsChannel(name: name, group: "Sports"))
    }

    @Test("Sports networks use complete tokens",
          arguments: ["TSN5 HD", "CA | Sportsnet Ontario", "ESPN2", "TVA Sports"])
    func recognizesSports(_ name: String) {
        #expect(BannerSportsChannelClassifier.isSportsChannel(name: name, group: nil))
    }

    @Test("General broadcasters and embedded network names are not sports proof",
          arguments: ["ABC", "FOX", "TNT", "NBC", "FOXNEWS", "Random ESPNish"])
    func rejectsAmbiguousNetworks(_ name: String) {
        #expect(!BannerSportsChannelClassifier.isSportsChannel(name: name, group: nil))
    }

    @MainActor
    @Test("Releasing the previous owner cannot clear the new media owner")
    func ownershipHandoff() {
        let ownership = NowPlayingOwnership()
        let podcast = UUID()
        let live = UUID()
        var releases = 0
        ownership.claim(podcast) {
            releases += 1
            #expect(!ownership.release(podcast))
        }
        ownership.claim(live) {}
        #expect(releases == 1)
        #expect(ownership.owns(live))
        ownership.claim(live) { Issue.record("Same owner should not be revoked") }
        #expect(releases == 1)
        #expect(ownership.release(live))
        #expect(!ownership.owns(live))
    }

    @Test("NHL intermission removes a stale clock from shared presentation")
    func intermission() {
        let period = HockeyPeriod(raw: .object(["number": .number(1), "periodType": .string("REG"), "maxRegulationPeriods": .number(3)]))
        let home = HockeyTeam(id: 9, abbreviation: "OTT", name: "Ottawa", logo: nil, score: 2, shots: 10)
        let away = HockeyTeam(id: 10, abbreviation: "TOR", name: "Toronto", logo: nil, score: 1, shots: 8)
        let game = HockeyGame(id: 123, start: Date(), status: .live, period: period, clock: "11:47",
                              secondsRemaining: 707, clockRunning: true, intermission: true,
                              home: home, away: away, broadcasts: [], venue: nil, gameCenterURL: nil)
        guard let league = League.all.first(where: { $0.path == "hockey/nhl" }) else {
            Issue.record("Missing NHL league")
            return
        }
        let match = NHLGameMapper.match(game, league: league)
        #expect(!match.statusDetail.contains("11:47"))
        #expect(match.liveContext.clock?.displayValue == nil)
        #expect(match.liveContext.clock?.remainingSeconds == nil)
        #expect(match.liveContext.clock?.isRunning == false)
    }
}
