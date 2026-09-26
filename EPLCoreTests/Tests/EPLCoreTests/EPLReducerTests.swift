import Foundation
import Testing
@testable import EPLCore

private let mci = SoccerTeam(id: "43", name: "Manchester City", shortName: "Man City", abbreviation: "MCI")
private let sun = SoccerTeam(id: "56", name: "Sunderland", shortName: "Sunderland", abbreviation: "SUN")

private func sampleMatch(status: SoccerMatchStatus = .firstHalf, homeScore: Int = 1, awayScore: Int = 0) -> SoccerMatch {
    SoccerMatch(id: "M", competitionID: "8", season: "2026", matchWeek: 5, phase: "1", kickoff: Date(), status: status, clock: nil,
        home: SoccerTeamMatchState(team: mci, score: homeScore, halfTimeScore: nil, redCards: 0),
        away: SoccerTeamMatchState(team: sun, score: awayScore, halfTimeScore: nil, redCards: 0), ground: nil, attendance: nil, resultType: nil)
}

private func sampleEvent(id: String, minute: Int, type: SoccerEventType = .goal, ordinal: Int = 0) -> SoccerMatchEvent {
    SoccerMatchEvent(id: id, matchID: "M", teamID: "43", type: type, period: "FirstHalf", minute: minute, timestamp: Date(), playerID: "P1", secondaryPlayerID: nil, ordinal: ordinal)
}

@Suite("EPL Game Centre reducer")
struct EPLReducerTests {
    @Test func staleOutOfOrderResponseIsRejected() {
        let baseline = SoccerGameCentreSnapshot(matchID: "M", fetchedAt: Date())
        let stale = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date().addingTimeInterval(-30), match: sampleMatch(homeScore: 9))
        let result = SoccerGameCentreReducer.apply(stale, to: baseline)
        #expect(result.fetchedAt == baseline.fetchedAt)
        #expect(result.match == nil)
    }

    @Test func mismatchedMatchIDIsRejected() {
        // The structural half of the Step 77 game-switch race guard: a response for
        // a different match must never merge into this snapshot, regardless of timing.
        var snapshotForB = SoccerGameCentreSnapshot(matchID: "B")
        snapshotForB.fetchedAt = Date().addingTimeInterval(-5)
        let responseForA = SoccerGameCentreUpdate(matchID: "A", requestedAt: Date(), match: sampleMatch())
        let result = SoccerGameCentreReducer.apply(responseForA, to: snapshotForB)
        #expect(result.match == nil)
        #expect(result.matchID == "B")
    }

    @Test func eventsMergeByIdentityWithoutDuplicating() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let firstPoll = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date().addingTimeInterval(-5), events: [sampleEvent(id: "e1", minute: 10)])
        snapshot = SoccerGameCentreReducer.apply(firstPoll, to: snapshot)
        #expect(snapshot.events.count == 1)
        // Second poll re-delivers e1 plus a genuinely new e2 — count must grow by exactly one.
        let secondPoll = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), events: [sampleEvent(id: "e1", minute: 10), sampleEvent(id: "e2", minute: 31)])
        snapshot = SoccerGameCentreReducer.apply(secondPoll, to: snapshot)
        #expect(snapshot.events.count == 2)
    }

    @Test func correctedEventReplacesInPlaceRatherThanDuplicating() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.events = [sampleEvent(id: "e1", minute: 10, type: .goal)]
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        // A VAR review disallows the goal and reclassifies it as an own goal at the same id.
        let correction = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), events: [sampleEvent(id: "e1", minute: 10, type: .ownGoal)])
        let result = SoccerGameCentreReducer.apply(correction, to: snapshot)
        #expect(result.events.count == 1)
        #expect(result.events.first?.type == .ownGoal)
    }

    @Test func lineupThatHasLoadedSurvivesANotAnnouncedRegression() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.homeLineup = SoccerLineup(team: mci, formation: nil, starters: [], substitutes: [])
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let regression = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), homeLineup: .some(nil))
        let result = SoccerGameCentreReducer.apply(regression, to: snapshot)
        #expect(result.homeLineup != nil)
    }

    @Test func lineupNotYetLoadedAcceptsAnAnnouncedResponse() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let announcement = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), homeLineup: .some(SoccerLineup(team: mci, formation: nil, starters: [], substitutes: [])))
        let result = SoccerGameCentreReducer.apply(announcement, to: snapshot)
        #expect(result.homeLineup != nil)
        #expect(result.lineupsLoaded == true)
    }

    @Test func officialsAreNeverClearedByAnEmptyResponse() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.officials = [SoccerOfficial(name: "Robert Jones", role: "Referee")]
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), officials: [])
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.officials.count == 1)
    }

    @Test func commentaryMergesByIdAndSortsNewestFirst() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let older = SoccerCommentaryEntry(id: "c1", timestamp: Date().addingTimeInterval(-60), minuteDisplay: "10'", text: "Kickoff", rawType: "start")
        let newer = SoccerCommentaryEntry(id: "c2", timestamp: Date(), minuteDisplay: "45'", text: "Half time", rawType: "end")
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), commentary: [older, newer])
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.commentary.map(\.id) == ["c2", "c1"])
    }

    @Test func playerDirectoryMergesAdditivelyAndNeverShrinks() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.playerDirectory = ["P1": SoccerPlayerReference(id: "P1", firstName: "Erling", lastName: "Haaland")]
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), playerDirectory: ["P2": SoccerPlayerReference(id: "P2", firstName: "Phil", lastName: "Foden")])
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.playerDirectory.count == 2)
        #expect(result.playerDirectory["P1"] != nil)
    }

    @Test func liveStandingsNeverOverwritesOrIsOverwrittenByOfficialTable() {
        // Step 80: the two tables are independent slots on the snapshot, not the same field.
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let liveTable = SoccerStandingsTable(matchWeek: 5, entries: [], isLive: true)
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), liveStandings: liveTable)
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.liveStandings?.isLive == true)
    }
}
