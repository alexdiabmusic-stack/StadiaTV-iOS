import Foundation
import Testing
@testable import EPLCore

func fixtureData(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    #endif
    return try Data(contentsOf: url)
}
func fixture(_ name: String) throws -> EPLValue { try JSONDecoder().decode(EPLValue.self, from: fixtureData(name)) }

@Suite("EPL status and clock mapping")
struct EPLStatusClockTests {
    @Test func knownPeriods() {
        #expect(EPLStatusMapper.status(period: "PreMatch") == .scheduled)
        #expect(EPLStatusMapper.status(period: "FirstHalf") == .firstHalf)
        #expect(EPLStatusMapper.status(period: "HalfTime") == .halftime)
        #expect(EPLStatusMapper.status(period: "SecondHalf") == .secondHalf)
        #expect(EPLStatusMapper.status(period: "FullTime") == .fullTime)
        #expect(EPLStatusMapper.status(period: "Postponed") == .postponed)
    }
    @Test func unknownPeriodNeverCrashes() {
        #expect(EPLStatusMapper.status(period: "SomeFutureState") == .unknown("SomeFutureState"))
        #expect(EPLStatusMapper.status(period: nil) == .scheduled)
    }
    @Test func firstHalfStoppageTime() {
        let clock = EPLClockMapper.clock(status: .firstHalf, rawClock: "47")
        #expect(clock?.minute == 45); #expect(clock?.addedMinute == 2); #expect(clock?.display == "45+2'")
    }
    @Test func secondHalfStoppageTime() {
        let clock = EPLClockMapper.clock(status: .secondHalf, rawClock: "94")
        #expect(clock?.minute == 90); #expect(clock?.addedMinute == 4); #expect(clock?.display == "90+4'")
    }
    @Test func regulationTimeHasNoAddedMinute() {
        let clock = EPLClockMapper.clock(status: .firstHalf, rawClock: "23")
        #expect(clock?.minute == 23); #expect(clock?.addedMinute == nil); #expect(clock?.display == "23'")
    }
    @Test func halftimeAndFulltimeDisplay() {
        #expect(EPLClockMapper.clock(status: .halftime, rawClock: "45")?.display == "HT")
        #expect(EPLClockMapper.clock(status: .fullTime, rawClock: "97")?.display == "FT")
    }
}

@Suite("EPL match fixture normalization")
struct EPLMatchFixtureTests {
    @Test func fullTimeMatch() throws {
        let raw = try fixture("match-fulltime")
        let match = try #require(EPLMatchMapper.match(raw))
        #expect(match.id == "2645241")
        #expect(match.status == .fullTime)
        #expect(match.home.score == 5); #expect(match.away.score == 3)
        #expect(match.home.team.abbreviation == "MCI"); #expect(match.away.team.abbreviation == "SUN")
        #expect(match.clock?.display == "FT")
    }
    @Test func preMatchHasNoScoreAndDefaultsRedCardsToZero() throws {
        // Verified live 2026-09-23: a scheduled match's homeTeam/awayTeam omit
        // score/halfTimeScore/redCards entirely rather than sending zeros.
        let raw = try fixture("match-prematch")
        let match = try #require(EPLMatchMapper.match(raw))
        #expect(match.status == .scheduled)
        #expect(match.home.score == nil); #expect(match.away.score == nil)
        #expect(match.home.redCards == 0); #expect(match.away.redCards == 0)
    }
    @Test(arguments: [("match-firsthalf-stoppage", SoccerMatchStatus.firstHalf, "45+2'"), ("match-secondhalf-stoppage", .secondHalf, "90+4'"), ("match-halftime", .halftime, "HT")])
    func liveStates(_ name: String, _ status: SoccerMatchStatus, _ display: String) throws {
        let raw = try fixture(name)
        let match = try #require(EPLMatchMapper.match(raw))
        #expect(match.status == status)
        #expect(match.clock?.display == display)
    }
    @Test func postponedMatchHasNoScoreAndUnknownFieldsSurviveDecoding() throws {
        let raw = try fixture("match-postponed")
        let match = try #require(EPLMatchMapper.match(raw))
        #expect(match.status == .postponed)
        #expect(match.home.score == nil)
    }
    @Test func scoreIsNeverReconstructedFromEvents() throws {
        // The match endpoint is the sole score authority (Steps 63-64) — this just
        // asserts the mapper reads score directly off the match payload, full stop.
        let raw = try fixture("match-fulltime")
        let match = try #require(EPLMatchMapper.match(raw))
        #expect(match.home.score == 5)
    }
}

@Suite("EPL event mapping")
struct EPLEventMappingTests {
    @Test func realMatchEvents() throws {
        let raw = try fixture("events")
        let events = EPLEventMapper.events(raw, matchID: "2645241", homeTeamID: "43", awayTeamID: "56")
        #expect(events.count == 14)
        #expect(Set(events.map(\.id)).count == events.count) // every synthesized id is unique
        let goals = events.filter { $0.type == .goal }
        #expect(goals.count == 8)
        let subs = events.filter { $0.type == .substitution }
        #expect(subs.count == 5)
        // Sorted ascending by timestamp/minute — first event should be the earliest card.
        #expect(events.first?.minute == 8)
        #expect(events.first?.type == .yellowCard)
    }
    @Test func unknownGoalAndCardTypesSurvive() throws {
        let raw = try fixture("events-unknown-types")
        let events = EPLEventMapper.events(raw, matchID: "M", homeTeamID: "43", awayTeamID: "56")
        let goal = try #require(events.first { $0.teamID == "43" && $0.minute == 70 })
        #expect(goal.type == .unknown("Bicycle Kick"))
        let card = try #require(events.first { $0.teamID == "43" && $0.minute == 75 })
        #expect(card.type == .unknown("Orange"))
    }
    @Test func multipleSubstitutionsInSameMinuteBothSurviveWithStableOrder() throws {
        let raw = try fixture("events-unknown-types")
        let events = EPLEventMapper.events(raw, matchID: "M", homeTeamID: "43", awayTeamID: "56")
        let subs = events.filter { $0.type == .substitution }
        #expect(subs.count == 2)
        #expect(Set(subs.map(\.id)).count == 2) // same minute+timestamp, distinct ordinal keeps identity unique
        #expect(subs.map(\.ordinal) == [0, 1])
    }
    @Test func assistAndSubstitutionSlotsAreNeverTheSamePlayer() throws {
        let raw = try fixture("events")
        let events = EPLEventMapper.events(raw, matchID: "2645241", homeTeamID: "43", awayTeamID: "56")
        for event in events where event.type == .substitution {
            #expect(event.playerID != event.secondaryPlayerID)
        }
    }
}

@Suite("EPL lineup mapping")
struct EPLLineupMappingTests {
    private let mci = SoccerTeam(id: "43", name: "Manchester City", shortName: "Man City", abbreviation: "MCI")
    private let sun = SoccerTeam(id: "56", name: "Sunderland", shortName: "Sunderland", abbreviation: "SUN")

    @Test func announcedLineupHasFormationAndFullSquad() throws {
        let raw = try fixture("lineups-announced")
        let home = try #require(EPLLineupMapper.lineup(raw["home_team"], team: mci))
        #expect(home.starters.count == 11)
        #expect(home.substitutes.count == 9)
        #expect(home.formation?.raw == "4-2-3-1")
        #expect(home.formation?.rows.count == 5) // GK + 4 tactical rows for 4-2-3-1
        #expect(home.managerName == "Enzo Maresca")
        #expect(home.starters.allSatisfy { !$0.reference.fullName.isEmpty })
    }
    @Test func notAnnouncedLineupMapsToNilNotEmpty() throws {
        // HTTP 200 with an empty players array (verified live) must read as
        // "not announced yet", never as an error or an empty-but-real lineup.
        let raw = try fixture("lineups-not-announced")
        #expect(EPLLineupMapper.lineup(raw["home_team"], team: mci) == nil)
        #expect(EPLLineupMapper.lineup(raw["away_team"], team: sun) == nil)
    }
    @Test func missingFormationFallsBackToStartingXIRatherThanDroppingRoster() throws {
        let raw = try fixture("lineups-missing-formation")
        let home = try #require(EPLLineupMapper.lineup(raw["home_team"], team: mci))
        #expect(home.formation == nil)
        #expect(home.starters.count == 2) // both listed players survive despite no formation grouping
        #expect(home.substitutes.isEmpty)
    }
}

@Suite("EPL stats mapping")
struct EPLStatsMappingTests {
    @Test func statsWithExpectedGoals() throws {
        let raw = try fixture("stats")
        let sides = raw.array
        #expect(sides.count == 2)
        let home = try #require(sides.first { $0["teamId"].string == "43" })
        let stats = EPLStatKeyMapper.stats(home["stats"], teamID: "43")
        #expect(stats.expectedGoals != nil)
        #expect(stats.possession == 55.0)
        #expect(stats.shots == 16.0)
        #expect(!stats.raw.isEmpty) // unmapped raw Opta keys are preserved for future expansion
    }
    @Test func missingExpectedGoalsNeverFakesZero() throws {
        let raw = try fixture("stats-no-xg")
        let sides = raw.array
        let home = try #require(sides.first { $0["teamId"].string == "43" })
        let stats = EPLStatKeyMapper.stats(home["stats"], teamID: "43")
        #expect(stats.expectedGoals == nil) // must be nil, never a fabricated 0.0
        #expect(stats.possession != nil) // other metrics remain unaffected
    }
}

@Suite("EPL officials and commentary mapping")
struct EPLOfficialsCommentaryTests {
    @Test func officials() throws {
        let raw = try fixture("officials")
        let officials = EPLOfficialsMapper.officials(raw)
        #expect(officials.count == 6)
        #expect(officials.contains { $0.role == "Referee" && $0.name == "Robert Jones" })
    }
    @Test func commentaryDeduplicatesMultiLanguageEntries() throws {
        // Verified live 2026-09-23: the feed returns the same moment 2-3x, once per
        // language, with no per-entry language field — only (timestamp, type) reliably groups them.
        let raw = try fixture("commentary")
        let entries = EPLCommentaryMapper.entries(raw, matchID: "2645241")
        #expect(entries.count < EPLPagedResponse(raw).data.count)
        #expect(entries.count == 4)
    }
    @Test func commentaryPreservesBlankMinuteAsNil() throws {
        let raw = try fixture("commentary")
        let entries = EPLCommentaryMapper.entries(raw, matchID: "2645241")
        // The full-time entry's "time" field is a bare space in the raw feed.
        #expect(entries.contains { $0.minuteDisplay == nil })
    }
    @Test func paginationCursorIsPreservedVerbatim() throws {
        let raw = try fixture("commentary")
        let page = EPLPagedResponse(raw)
        #expect(page.nextCursor != nil)
        let raw2 = try fixture("commentary-page2")
        let entries2 = EPLCommentaryMapper.entries(raw2, matchID: "2645241")
        #expect(!entries2.isEmpty)
    }
}

@Suite("EPL standings mapping")
struct EPLStandingsMappingTests {
    @Test func officialTable() throws {
        let raw = try fixture("standings")
        let table = EPLMatchMapper.standingsTable(raw, live: false)
        #expect(table.isLive == false)
        #expect(table.entries.count == 20)
        #expect(table.entries.allSatisfy { $0.overall.position != nil })
    }
    @Test func liveAndOfficialTablesStayDistinct() throws {
        // Same payload shape either way — the `isLive` flag is caller-supplied, not
        // derived from the JSON, so official and live projections can never collapse
        // into each other (Step 80).
        let raw = try fixture("standings")
        let official = EPLMatchMapper.standingsTable(raw, live: false)
        let live = EPLMatchMapper.standingsTable(raw, live: true)
        #expect(official.isLive != live.isLive)
        #expect(official.entries.count == live.entries.count)
    }
}
