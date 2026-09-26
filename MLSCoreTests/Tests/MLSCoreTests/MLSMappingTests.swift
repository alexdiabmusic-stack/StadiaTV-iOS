import Foundation
import Testing
@testable import MLSCore

func fixtureData(_ name: String) throws -> Data {
    #if SWIFT_PACKAGE
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    #endif
    return try Data(contentsOf: url)
}
func fixture(_ name: String) throws -> MLSValue { try JSONDecoder().decode(MLSValue.self, from: fixtureData(name)) }

@Suite("MLS status and clock mapping")
struct MLSStatusClockTests {
    // Only "scheduled" and "finalWhistle" were directly observed live; the rest are
    // inferred from MLS's own camelCase convention — see MLSStatusMapper's doc comment.
    @Test func observedStatuses() {
        #expect(MLSStatusMapper.status(matchStatus: "scheduled") == .scheduled)
        #expect(MLSStatusMapper.status(matchStatus: "finalWhistle") == .fullTime)
    }
    @Test func inferredLiveStatuses() {
        #expect(MLSStatusMapper.status(matchStatus: "firstHalf") == .firstHalf)
        #expect(MLSStatusMapper.status(matchStatus: "halftime") == .halftime)
        #expect(MLSStatusMapper.status(matchStatus: "secondHalf") == .secondHalf)
        #expect(MLSStatusMapper.status(matchStatus: "extraFirstHalf") == .extraFirstHalf)
        #expect(MLSStatusMapper.status(matchStatus: "extraHalftime") == .extraHalftime)
        #expect(MLSStatusMapper.status(matchStatus: "extraSecondHalf") == .extraSecondHalf)
        #expect(MLSStatusMapper.status(matchStatus: "penalties") == .penalties)
    }
    @Test func inferredTerminalStatuses() {
        #expect(MLSStatusMapper.status(matchStatus: "postponed") == .postponed)
        #expect(MLSStatusMapper.status(matchStatus: "suspended") == .suspended)
        #expect(MLSStatusMapper.status(matchStatus: "abandoned") == .abandoned)
        #expect(MLSStatusMapper.status(matchStatus: "delayed") == .delayed)
        #expect(MLSStatusMapper.status(matchStatus: "cancelled") == .cancelled)
    }
    @Test func unknownStatusNeverCrashes() {
        #expect(MLSStatusMapper.status(matchStatus: "someFutureState") == .unknown("someFutureState"))
        #expect(MLSStatusMapper.status(matchStatus: nil) == .scheduled)
    }
    @Test func caseInsensitive() {
        #expect(MLSStatusMapper.status(matchStatus: "FinalWhistle") == .fullTime)
    }

    @Test func stoppageTimeParsedFromProviderString() {
        // MLS's minute_of_play is already stoppage-formatted — never recomputed.
        let clock = MLSClockMapper.clock(status: .secondHalf, minuteOfPlay: "90+7")
        #expect(clock?.minute == 90); #expect(clock?.addedMinute == 7); #expect(clock?.display == "90+7'")
    }
    @Test func regulationTimeHasNoAddedMinute() {
        let clock = MLSClockMapper.clock(status: .firstHalf, minuteOfPlay: "23")
        #expect(clock?.minute == 23); #expect(clock?.addedMinute == nil); #expect(clock?.display == "23'")
    }
    @Test func fullTimeShowsStaticDisplay() {
        let clock = MLSClockMapper.clock(status: .fullTime, minuteOfPlay: "97")
        #expect(clock?.display == "FT"); #expect(clock?.minute == 97)
    }
    @Test func penaltiesHasNoNumericMinute() {
        let clock = MLSClockMapper.clock(status: .penalties, minuteOfPlay: nil)
        #expect(clock?.display == "PEN")
    }
}

@Suite("MLS match fixture normalization")
struct MLSMatchMappingTests {
    @Test func scheduleEntriesNormalize() throws {
        let raw = try fixture("schedule")
        let matches = raw["schedule"].array.compactMap { MLSMatchMapper.scheduleMatch($0) }
        #expect(matches.count == 5)
        let scheduled = try #require(matches.first { $0.status == .scheduled })
        #expect(scheduled.home.score == 0); #expect(scheduled.away.score == 0)
        let finished = try #require(matches.first { $0.status == .fullTime })
        #expect(finished.home.score != nil && finished.away.score != nil)
        // Conference label ("WESTERN CONFERENCE") is preserved verbatim, not parsed further.
        #expect(matches.contains { $0.conference?.contains("CONFERENCE") == true })
    }

    @Test func overviewMatchNormalizes() throws {
        let raw = try fixture("match-overview-fulltime")
        let match = try #require(MLSMatchMapper.overviewMatch(raw))
        #expect(match.status == .fullTime)
        #expect(match.home.score == 2); #expect(match.away.score == 2)
        #expect(match.competitionName == "Major League Soccer - Regular Season")
        #expect(match.ground != nil)
    }

    @Test func playerTeamMapCoversBothSides() throws {
        let raw = try fixture("match-overview-fulltime")
        let map = MLSMatchMapper.playerTeamMap(fromOverview: raw)
        #expect(map.count > 20)
        #expect(Set(map.values).count == 2)
    }

    @Test func clubMapsToSoccerTeam() throws {
        let raw = try fixture("clubs")
        let clubs = raw["clubs"].array.compactMap { MLSMatchMapper.club($0) }
        #expect(!clubs.isEmpty)
        #expect(clubs.allSatisfy { !$0.name.isEmpty })
    }
}

@Suite("MLS event mapping")
struct MLSEventMappingTests {
    @Test func realMatchEventsMapWithoutCrashing() throws {
        let overview = try fixture("match-overview-fulltime")
        let raw = try fixture("key-events")
        let map = MLSMatchMapper.playerTeamMap(fromOverview: overview)
        let events = MLSEventMapper.events(raw, matchID: "MLS-MAT-0009LX", playerTeamMap: map)
        #expect(!events.isEmpty)
        // kick_off/final_whistle are intentionally not emitted (no team of their own).
        #expect(!events.contains { $0.type == .periodStart || $0.type == .periodEnd })
    }
    @Test func shotAtGoalsResolvesTeamFromPlayerMap() throws {
        let overview = try fixture("match-overview-fulltime")
        let raw = try fixture("key-events")
        let map = MLSMatchMapper.playerTeamMap(fromOverview: overview)
        let events = MLSEventMapper.events(raw, matchID: "M", playerTeamMap: map)
        let shots = events.filter { [.goal, .shotSaved, .shotBlocked, .shotOffTarget].contains($0.type) }
        #expect(!shots.isEmpty)
        #expect(shots.allSatisfy { !$0.teamID.isEmpty })
    }
    @Test func cardsAndSubstitutionsCarryStructuredPlayers() throws {
        let raw = try fixture("key-events")
        let events = MLSEventMapper.events(raw, matchID: "M", playerTeamMap: [:])
        let subs = events.filter { $0.type == .substitution }
        #expect(!subs.isEmpty)
        #expect(subs.allSatisfy { $0.playerID != nil && $0.secondaryPlayerID != nil && $0.playerID != $0.secondaryPlayerID })
    }
    @Test func eventIdentityIsStableProviderEventID() throws {
        let raw = try fixture("key-events")
        let events = MLSEventMapper.events(raw, matchID: "M", playerTeamMap: [:])
        #expect(Set(events.map(\.id)).count == events.count)  // no duplicate identities
    }
    @Test func unknownTopLevelTypeSurvivesAsUnknown() {
        let raw: MLSValue = .object(["events": .array([.object([
            "type": .string("var_review"), "sub_type": .string(""),
            "event": .object(["event_id": .string("999"), "team_id": .string("T1"), "minute_of_play": .string("55")])
        ])])])
        let events = MLSEventMapper.events(raw, matchID: "M", playerTeamMap: [:])
        #expect(events.first?.type == .unknown("var_review"))
    }
    @Test func directoryHydratesFromInlineEventNames() throws {
        let raw = try fixture("key-events")
        let directory = MLSEventMapper.playerDirectory(fromKeyEvents: raw)
        #expect(directory.values.contains { $0.fullName == "Leo Messi" })
    }
}

@Suite("MLS lineup mapping")
struct MLSLineupMappingTests {
    @Test func announcedLineupHasFormationLabelButNoInventedRows() throws {
        let raw = try fixture("match-overview-fulltime")
        let team = SoccerTeam(id: "MLS-CLU-000008", name: "Inter Miami CF", shortName: "Miami", abbreviation: "MIA")
        let lineup = try #require(MLSLineupMapper.lineup(raw["home"], team: team))
        #expect(!lineup.starters.isEmpty)
        #expect(lineup.formation?.raw == "4-3-3")
        // No coordinate data exists in this payload — rows must stay empty, never invented.
        #expect(lineup.formation?.rows.isEmpty == true)
    }
    @Test func notAnnouncedLineupMapsToNilNotEmpty() {
        let empty: MLSValue = .object(["players": .array([])])
        let team = SoccerTeam(id: "T", name: "T", shortName: "T", abbreviation: "T")
        #expect(MLSLineupMapper.lineup(empty, team: team) == nil)
    }
    @Test func managerNameComesFromHeadCoachRole() throws {
        let raw = try fixture("match-overview-fulltime")
        let team = SoccerTeam(id: "MLS-CLU-000008", name: "Inter Miami CF", shortName: "Miami", abbreviation: "MIA")
        let lineup = try #require(MLSLineupMapper.lineup(raw["home"], team: team))
        #expect(lineup.managerName != nil)
    }
}

@Suite("MLS stats mapping")
struct MLSStatsMappingTests {
    @Test func teamStatsMapKnownFields() throws {
        let raw = try fixture("team-match-stats")
        let list = raw["match_statistics_list"].array
        let teamEntries = list.first?["match_statistics"]["team_statistics"].array ?? []
        #expect(teamEntries.count == 2)
        let mia = try #require(teamEntries.first { $0["team_id"].string == "MLS-CLU-000008" })
        let stats = MLSStatKeyMapper.stats(mia, teamID: "MLS-CLU-000008")
        #expect(stats.possession != nil)
        #expect(stats.expectedGoals != nil)
        #expect(!stats.attackingZones.isEmpty)
    }
    @Test func missingMetricsNeverFakeZero() throws {
        let raw = try fixture("team-match-stats")
        let teamEntries = raw["match_statistics_list"].array.first?["match_statistics"]["team_statistics"].array ?? []
        let stats = MLSStatKeyMapper.stats(teamEntries[0], teamID: "x")
        #expect(stats.tackles == nil)     // unconfirmed metric, must stay nil not 0
        #expect(stats.duelsWon == nil)
    }
    @Test func playerMatchStatsMapRealPlayer() throws {
        let raw = try fixture("player-match-stats")
        let stats = MLSPlayerStatsMapper.stats(raw, matchID: "MLS-MAT-0009LX")
        #expect(stats.count == 40)
        let messi = try #require(stats.first { $0.playerID == "MLS-OBJ-000396" })
        #expect(messi.goals == 1)
    }
}

@Suite("MLS officials and commentary mapping")
struct MLSOfficialsCommentaryTests {
    @Test func officialsIncludeMainReferee() throws {
        let raw = try fixture("match-overview-fulltime")
        let officials = MLSOfficialsMapper.officials(raw)
        #expect(officials.contains { $0.role == "referee" })
        #expect(officials.count == 6)
    }
    @Test func commentaryEntriesHaveStableIdentity() throws {
        let raw = try fixture("commentary")
        let entries = MLSCommentaryMapper.entries(raw, matchID: "M")
        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.id)).count == entries.count)
    }
    @Test func blankCommentaryTextIsSkipped() {
        let raw: MLSValue = .object(["commentary": .array([.object([
            "event_id": .string("1"), "commentary": .string(""), "type": .string("Foo")
        ])])])
        #expect(MLSCommentaryMapper.entries(raw, matchID: "M").isEmpty)
    }
}

@Suite("MLS standings mapping")
struct MLSStandingsMappingTests {
    @Test func overallTableHasNoGroupLabel() throws {
        let raw = try fixture("standings-overall")
        let tables = MLSStandingsMapper.tables(raw, isLive: false)
        #expect(tables.count == 1)
        #expect(tables[0].groupLabel == nil)
        #expect(tables[0].entries.count == 30)
    }
    @Test func conferenceTablesSplitEastAndWest() throws {
        let raw = try fixture("standings-conference")
        let tables = MLSStandingsMapper.tables(raw, isLive: false)
        #expect(tables.count == 2)
        #expect(Set(tables.map(\.groupLabel)) == Set(["EASTERN CONFERENCE", "WESTERN CONFERENCE"]))
        #expect(tables.allSatisfy { $0.entries.count == 15 })
    }
}
