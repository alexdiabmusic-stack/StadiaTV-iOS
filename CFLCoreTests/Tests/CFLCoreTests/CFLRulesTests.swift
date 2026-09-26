import Foundation
import Testing
@testable import CFLCore

/// Verifies the specific rules CFL must not silently inherit from NFL — each of these
/// would pass trivially if CFL secretly reused NFL's config, so every assertion compares
/// the two configs directly rather than checking CFL's values in isolation.
@Suite struct CFLRulesTests {
    @Test func cflHasThreeDownsNFLHasFour() {
        #expect(FootballLeagueConfiguration.cfl.downs == 3)
        #expect(FootballLeagueConfiguration.nfl.downs == 4)
        #expect(FootballLeagueConfiguration.cfl.downs != FootballLeagueConfiguration.nfl.downs)
    }

    @Test func cflFieldIsOneHundredTenYardsWithTwentyYardEndZones() {
        #expect(FootballLeagueConfiguration.cfl.fieldLength == 110)
        #expect(FootballLeagueConfiguration.cfl.endZoneLength == 20)
        #expect(FootballLeagueConfiguration.nfl.fieldLength == 100)
        #expect(FootballLeagueConfiguration.nfl.endZoneLength == 10)
    }

    @Test func fieldGeometryProducesGenuinelyDifferentBallOffsetsNotARelabeledCopy() {
        // Same "25 yards to goal" input, two different fields — if these ever converge,
        // the geometry stopped being parameterized and became a relabeled NFL view.
        let cflOffset = FootballFieldGeometry.cfl.ballOffsetFraction(yardsToGoal: 25)
        let nflOffset = FootballFieldGeometry.nfl.ballOffsetFraction(yardsToGoal: 25)
        #expect(cflOffset != nflOffset)
        #expect(abs(cflOffset - (85.0 / 110.0)) < 0.0001)
        #expect(abs(nflOffset - (75.0 / 100.0)) < 0.0001)
        #expect(FootballFieldGeometry.cfl.tickCount != FootballFieldGeometry.nfl.tickCount)
    }

    @Test func ordinalHandlesDownsBeyondFourWithoutAFixedFourEntryTable() {
        #expect(footballOrdinal(1) == "1ST")
        #expect(footballOrdinal(2) == "2ND")
        #expect(footballOrdinal(3) == "3RD")
        #expect(footballOrdinal(4) == "4TH")
        // A hand-written {1,2,3,4} dictionary would crash or blank out here; the real
        // implementation must not be capped at NFL's down count.
        #expect(footballOrdinal(11) == "11TH")
        #expect(footballOrdinal(21) == "21ST")
    }

    @Test func singleRougeIsDistinctFromExtraPointConvert() {
        #expect(FootballPlayType.single != FootballPlayType.extraPoint)
        #expect(FootballPlayType.single.label.localizedCaseInsensitiveContains("rouge"))
        #expect(!FootballPlayType.extraPoint.label.localizedCaseInsensitiveContains("rouge"))
    }

    @Test func footballPlayCarriesItsOwnDownCountRatherThanALeagueGlobal() {
        let cflPlay = FootballPlay(id: "1", sequence: 1, driveSequence: nil, quarter: 1, clock: "10:00",
            down: 3, distance: 5, goalToGo: false, field: "CFL 45", type: .run, text: "Run for 2 yards",
            yards: 2, scoring: false, turnover: false, penalty: false, teamID: nil, participants: [], totalDowns: 3)
        let nflPlay = FootballPlay(id: "2", sequence: 1, driveSequence: nil, quarter: 1, clock: "10:00",
            down: 4, distance: 5, goalToGo: false, field: "NFL 45", type: .run, text: "Run for 2 yards",
            yards: 2, scoring: false, turnover: false, penalty: false, teamID: nil, participants: [], totalDowns: 4)
        #expect(cflPlay.totalDowns == 3)
        #expect(nflPlay.totalDowns == 4)
        // A down value of 4 is only ever valid to *display* on the NFL play, never the CFL one.
        #expect((1...cflPlay.totalDowns).contains(cflPlay.down!))
        #expect(!(1...cflPlay.totalDowns).contains(nflPlay.down!))
    }
}
