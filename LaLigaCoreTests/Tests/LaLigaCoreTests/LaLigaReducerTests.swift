import Foundation
import Testing
@testable import LaLigaCore

/// Covers only the Phase 1 shared-reducer additions La Liga introduced (shots,
/// momentum, providerMatchIDs) — the pre-existing EPL/MLS reducer behavior
/// (ordering gate, event/commentary merge, lineup regression guard) is already
/// covered by EPLCoreTests/MLSCoreTests and untouched here except where a new
/// field's presence could plausibly interact with it (last test below).
@Suite("Soccer reducer — La Liga additions")
struct LaLigaReducerAdditionsTests {
    @Test func shotsMergeByIDAndSortByMinute() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "m1")
        let shot1 = SoccerShot(id: "s1", matchID: "m1", teamID: "H", playerReference: SoccerPlayerReference(id: "p1", firstName: "A", lastName: "B"),
            minute: 10, x: 90, y: 50, expectedGoals: 0.1, outcome: .saved, bodyPart: "RightFoot", situation: "OpenPlay")
        snapshot = SoccerGameCentreReducer.apply(SoccerGameCentreUpdate(matchID: "m1", requestedAt: Date(), shots: [shot1]), to: snapshot)
        #expect(snapshot.shots.count == 1)

        // A later poll corrects shot1's outcome (e.g. a delayed VAR confirmation)
        // and adds a new, earlier-minute shot.
        let correctedShot1 = SoccerShot(id: "s1", matchID: "m1", teamID: "H", playerReference: shot1.playerReference,
            minute: 10, x: 90, y: 50, expectedGoals: 0.1, outcome: .goal, bodyPart: "RightFoot", situation: "OpenPlay")
        let shot0 = SoccerShot(id: "s0", matchID: "m1", teamID: "A", playerReference: SoccerPlayerReference(id: "p2", firstName: "C", lastName: "D"),
            minute: 3, x: 80, y: 40, expectedGoals: nil, outcome: .missed, bodyPart: nil, situation: nil)
        snapshot = SoccerGameCentreReducer.apply(SoccerGameCentreUpdate(matchID: "m1", requestedAt: Date().addingTimeInterval(1), shots: [correctedShot1, shot0]), to: snapshot)
        #expect(snapshot.shots.count == 2)
        #expect(snapshot.shots.first?.id == "s0") // sorted by minute ascending
        #expect(snapshot.shots.last?.outcome == .goal) // corrected in place, not duplicated
    }

    @Test func momentumReplacesWholesaleNotMerged() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "m1")
        snapshot = SoccerGameCentreReducer.apply(SoccerGameCentreUpdate(matchID: "m1", requestedAt: Date(), momentum: [SoccerMomentumSample(minute: 1, value: 5)]), to: snapshot)
        snapshot = SoccerGameCentreReducer.apply(SoccerGameCentreUpdate(matchID: "m1", requestedAt: Date().addingTimeInterval(1),
            momentum: [SoccerMomentumSample(minute: 1, value: 5), SoccerMomentumSample(minute: 2, value: -3)]), to: snapshot)
        #expect(snapshot.momentum.count == 2)
    }

    @Test func providerMatchIDsReplacedWhenPresentNeverClearedWhenAbsent() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "m1")
        snapshot = SoccerGameCentreReducer.apply(SoccerGameCentreUpdate(matchID: "m1", requestedAt: Date(),
            providerMatchIDs: SoccerProviderMatchIDs(laligaOfficial: "m1", fotmob: nil)), to: snapshot)
        #expect(snapshot.providerMatchIDs?.fotmob == nil)

        snapshot = SoccerGameCentreReducer.apply(SoccerGameCentreUpdate(matchID: "m1", requestedAt: Date().addingTimeInterval(1),
            providerMatchIDs: SoccerProviderMatchIDs(laligaOfficial: "m1", fotmob: "fm1")), to: snapshot)
        #expect(snapshot.providerMatchIDs?.fotmob == "fm1")

        // A poll that never touches reconciliation (`providerMatchIDs == nil`)
        // must never wipe out an already-confirmed mapping.
        snapshot = SoccerGameCentreReducer.apply(SoccerGameCentreUpdate(matchID: "m1", requestedAt: Date().addingTimeInterval(2)), to: snapshot)
        #expect(snapshot.providerMatchIDs?.fotmob == "fm1")
    }

    @Test func staleOutOfOrderUpdateRejectedWholesaleEvenWithNewFieldsPresent() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "m1")
        let now = Date()
        let shot = SoccerShot(id: "s1", matchID: "m1", teamID: "H", playerReference: SoccerPlayerReference(id: "p1", firstName: nil, lastName: nil),
            minute: 1, x: nil, y: nil, expectedGoals: nil, outcome: .goal, bodyPart: nil, situation: nil)
        snapshot = SoccerGameCentreReducer.apply(SoccerGameCentreUpdate(matchID: "m1", requestedAt: now, shots: [shot]), to: snapshot)
        let stale = SoccerGameCentreUpdate(matchID: "m1", requestedAt: now.addingTimeInterval(-10), shots: [])
        let result = SoccerGameCentreReducer.apply(stale, to: snapshot)
        #expect(result.shots.count == 1) // the pre-existing ordering gate rejected the stale update wholesale
    }
}
