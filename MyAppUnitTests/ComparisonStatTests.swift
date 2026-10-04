import Foundation
import Testing
@testable import BannerTV

@Suite("ComparisonStat")
struct ComparisonStatTests {

    @Test("Two plain counts parse as a share visualization")
    func countsParseAsShare() {
        let stat = ComparisonStat.parse(id: "sog", label: "Shots", away: "36", home: "24", teamAwayName: "Away", teamHomeName: "Home")
        #expect(stat != nil)
        guard case .share(let a, let h) = stat?.visualization else { Issue.record("expected .share"); return }
        #expect(a == 36 && h == 24)
        #expect(stat?.leader == .away)
    }

    @Test("Two percentages parse as a percent-split visualization")
    func percentagesParseAsSplit() {
        let stat = ComparisonStat.parse(id: "fo", label: "Faceoff %", away: "51.6%", home: "48.4%", teamAwayName: "Away", teamHomeName: "Home")
        guard case .percentSplit(let a, let h) = stat?.visualization else { Issue.record("expected .percentSplit"); return }
        #expect(a == 51.6 && h == 48.4)
        #expect(stat?.leader == .away)
    }

    @Test("Made/attempted fractions parse as a fraction visualization")
    func fractionsParse() {
        let stat = ComparisonStat.parse(id: "pp", label: "Power Play", away: "2/3", home: "1/2", teamAwayName: "Away", teamHomeName: "Home")
        guard case .fraction(let am, let aa, let hm, let ha) = stat?.visualization else { Issue.record("expected .fraction"); return }
        #expect(am == 2 && aa == 3 && hm == 1 && ha == 2)
    }

    @Test("A missing value returns nil rather than fabricating zero")
    func missingValueReturnsNil() {
        #expect(ComparisonStat.parse(id: "x", label: "X", away: "", home: "5", teamAwayName: "Away", teamHomeName: "Home") == nil)
        #expect(ComparisonStat.parse(id: "x", label: "X", away: "5", home: "   ", teamAwayName: "Away", teamHomeName: "Home") == nil)
    }

    @Test("lowerIsBetter flips which side is treated as the leader")
    func lowerIsBetterFlipsLeader() {
        let stat = ComparisonStat.parse(id: "giveaways", label: "Giveaways", away: "10", home: "4", lowerIsBetter: true, teamAwayName: "Away", teamHomeName: "Home")
        #expect(stat?.leader == .home, "Home has fewer giveaways, which is the better outcome")
    }

    @Test("Equal values have no leader")
    func equalValuesHaveNoLeader() {
        let stat = ComparisonStat.parse(id: "x", label: "X", away: "10", home: "10", teamAwayName: "Away", teamHomeName: "Home")
        #expect(stat?.leader == .none)
    }
}
