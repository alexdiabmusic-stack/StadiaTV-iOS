import Foundation
import Testing
@testable import MLSCore

private let mia = SoccerTeam(id: "MLS-CLU-000008", name: "Inter Miami CF", shortName: "Miami", abbreviation: "MIA")
private let sd = SoccerTeam(id: "MLS-CLU-000065", name: "San Diego FC", shortName: "San Diego", abbreviation: "SD")

private func sampleMatch(status: SoccerMatchStatus = .firstHalf, homeScore: Int = 1, awayScore: Int = 0) -> SoccerMatch {
    SoccerMatch(id: "M", competitionID: "MLS-COM-000001", season: "2026", matchWeek: 27, phase: "MATCHWEEK 27", kickoff: Date(), status: status, clock: nil,
        home: SoccerTeamMatchState(team: mia, score: homeScore, halfTimeScore: nil, redCards: 0),
        away: SoccerTeamMatchState(team: sd, score: awayScore, halfTimeScore: nil, redCards: 0), ground: nil, attendance: nil, resultType: nil)
}

private func sampleEvent(id: String, minute: Int, type: SoccerEventType = .goal, ordinal: Int = 0) -> SoccerMatchEvent {
    SoccerMatchEvent(id: id, matchID: "M", teamID: "MLS-CLU-000008", type: type, period: "firstHalf", minute: minute, timestamp: Date(), playerID: "P1", secondaryPlayerID: nil, ordinal: ordinal)
}

// This suite exercises the shared `SoccerGameCentreReducer` — the same reducer
// promoted out of the EPL-specific code in Phase 1 of the MLS integration — via
// MLS-flavored fixtures, plus the new merge behaviors this integration added
// (conference standings, player match stats, penalty shootout).
@Suite("MLS Game Centre reducer")
struct MLSReducerTests {
    @Test func staleOutOfOrderResponseIsRejected() {
        let baseline = SoccerGameCentreSnapshot(matchID: "M", fetchedAt: Date())
        let stale = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date().addingTimeInterval(-30), match: sampleMatch(homeScore: 9))
        let result = SoccerGameCentreReducer.apply(stale, to: baseline)
        #expect(result.fetchedAt == baseline.fetchedAt)
        #expect(result.match == nil)
    }

    @Test func mismatchedMatchIDIsRejected() {
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
        let firstPoll = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date().addingTimeInterval(-5), events: [sampleEvent(id: "M|1", minute: 10)])
        snapshot = SoccerGameCentreReducer.apply(firstPoll, to: snapshot)
        #expect(snapshot.events.count == 1)
        let secondPoll = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), events: [sampleEvent(id: "M|1", minute: 10), sampleEvent(id: "M|2", minute: 31)])
        snapshot = SoccerGameCentreReducer.apply(secondPoll, to: snapshot)
        #expect(snapshot.events.count == 2)
    }

    @Test func correctedEventReplacesInPlaceRatherThanDuplicating() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.events = [sampleEvent(id: "M|1", minute: 10, type: .goal)]
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        // A VAR review disallows the goal and reclassifies it as an own goal at the same id.
        let correction = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), events: [sampleEvent(id: "M|1", minute: 10, type: .ownGoal)])
        let result = SoccerGameCentreReducer.apply(correction, to: snapshot)
        #expect(result.events.count == 1)
        #expect(result.events.first?.type == .ownGoal)
    }

    @Test func lineupThatHasLoadedSurvivesANotAnnouncedRegression() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.homeLineup = SoccerLineup(team: mia, formation: nil, starters: [], substitutes: [])
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let regression = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), homeLineup: .some(nil))
        let result = SoccerGameCentreReducer.apply(regression, to: snapshot)
        #expect(result.homeLineup != nil)
    }

    @Test func officialsAreNeverClearedByAnEmptyResponse() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.officials = [SoccerOfficial(name: "Rosendo Mendoza", role: "referee")]
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), officials: [])
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.officials.count == 1)
    }

    @Test func commentaryMergesByIdAndSortsNewestFirst() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let older = SoccerCommentaryEntry(id: "c1", timestamp: Date().addingTimeInterval(-60), minuteDisplay: "10'", text: "Kickoff", rawType: "KickOff")
        let newer = SoccerCommentaryEntry(id: "c2", timestamp: Date(), minuteDisplay: "45'", text: "Half time", rawType: "HalfTime")
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), commentary: [older, newer])
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.commentary.map(\.id) == ["c2", "c1"])
    }

    @Test func playerDirectoryMergesAdditivelyAndNeverShrinks() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.playerDirectory = ["P1": SoccerPlayerReference(id: "P1", firstName: "Leo", lastName: "Messi")]
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), playerDirectory: ["P2": SoccerPlayerReference(id: "P2", firstName: "Luis", lastName: "Suárez")])
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.playerDirectory.count == 2)
        #expect(result.playerDirectory["P1"] != nil)
    }

    @Test func liveStandingsNeverOverwritesOrIsOverwrittenByOfficialTable() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let liveTable = SoccerStandingsTable(matchWeek: 27, entries: [], isLive: true)
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), liveStandings: liveTable)
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.liveStandings?.isLive == true)
    }

    @Test func conferenceStandingsMergeIndependentlyOfLiveStandings() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let east = SoccerStandingsTable(matchWeek: 27, entries: [], isLive: true, groupLabel: "EASTERN CONFERENCE")
        let west = SoccerStandingsTable(matchWeek: 27, entries: [], isLive: true, groupLabel: "WESTERN CONFERENCE")
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), conferenceStandings: [east, west])
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.conferenceStandings.map(\.groupLabel) == ["EASTERN CONFERENCE", "WESTERN CONFERENCE"])
        #expect(result.liveStandings == nil)  // independent slot — this update never touched it
    }

    @Test func playerMatchStatsReplaceWhenPresent() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        let stats = [SoccerPlayerMatchStats(matchID: "M", playerID: "MLS-OBJ-000396", teamID: "MLS-CLU-000008", goals: 1)]
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), playerMatchStats: stats)
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.playerMatchStats.count == 1)
        #expect(result.playerMatchStats.first?.goals == 1)
    }

    @Test func penaltyShootoutOnlyAppearsWhenProviderReportsOne() {
        var snapshot = SoccerGameCentreSnapshot(matchID: "M")
        snapshot.fetchedAt = Date().addingTimeInterval(-10)
        #expect(snapshot.penaltyShootout == nil)
        let shootout = SoccerPenaltyShootout(homeTeamID: "MLS-CLU-000008", awayTeamID: "MLS-CLU-000065", kicks: [], homeScore: 4, awayScore: 3, isComplete: true)
        let update = SoccerGameCentreUpdate(matchID: "M", requestedAt: Date(), penaltyShootout: shootout)
        let result = SoccerGameCentreReducer.apply(update, to: snapshot)
        #expect(result.penaltyShootout?.homeScore == 4)
    }
}
