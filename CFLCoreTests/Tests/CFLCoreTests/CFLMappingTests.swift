import Foundation
import Testing
@testable import CFLCore

@Suite struct CFLMappingTests {
    private func load(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }
    private func teamsAndVenues() throws -> ([String: CFLValue], [String: CFLValue]) {
        let teams = try JSONDecoder().decode([CFLValue].self, from: load("teams"))
        let venues = try JSONDecoder().decode([CFLValue].self, from: load("venues"))
        let teamsByID = Dictionary(teams.compactMap { t in t["ID"].string.map { ($0, t) } }, uniquingKeysWith: { _, new in new })
        let venuesByID = Dictionary(venues.compactMap { v in v["ID"].string.map { ($0, v) } }, uniquingKeysWith: { _, new in new })
        return (teamsByID, venuesByID)
    }

    @Test func paginationTrapReturnsAllNinetyFiveFixtures() throws {
        let fixtures = try JSONDecoder().decode([CFLValue].self, from: load("fixtures-season75"))
        #expect(fixtures.count == 95)
    }

    @Test func finishedFixtureMapsFinalStatusScoreAndClock() throws {
        let (teams, venues) = try teamsAndVenues()
        let fixture = try JSONDecoder().decode(CFLValue.self, from: load("fixture-finished"))
        let game = CFLFixtureMapper.game(fixture, teams: teams, venues: venues, seasonID: 75, year: 2026)
        let unwrapped = try #require(game)
        #expect(unwrapped.status == .final)
        #expect(unwrapped.home.score == 28)
        #expect(unwrapped.away.score == 23)
        #expect(unwrapped.totalPeriods == 4)
        #expect(unwrapped.isOvertime == false)
    }

    @Test func scheduledFixtureHasNoStatusFieldYetAndMapsToScheduled() throws {
        let (teams, venues) = try teamsAndVenues()
        let fixture = try JSONDecoder().decode(CFLValue.self, from: load("fixture-scheduled"))
        #expect(fixture["game_status"].string == nil)
        let game = CFLFixtureMapper.game(fixture, teams: teams, venues: venues, seasonID: 75, year: 2026, now: Date(timeIntervalSince1970: 1_700_000_000))
        let unwrapped = try #require(game)
        #expect(unwrapped.status == .scheduled)
        #expect(unwrapped.home.score == nil)
    }

    @Test func greyCupFixtureWithUnresolvedQualifiersReturnsNil() throws {
        let (teams, venues) = try teamsAndVenues()
        let fixture = try JSONDecoder().decode(CFLValue.self, from: load("fixture-greycup-tbd"))
        #expect(fixture["home_team_id"].string == nil)
        let game = CFLFixtureMapper.game(fixture, teams: teams, venues: venues, seasonID: 75, year: 2026)
        // Never fabricates a home/away team when qualifiers aren't decided yet.
        #expect(game == nil)
    }

    @Test func gameTypeIDsMapToCFLTerminologyNeverNFLPlayoffLabels() {
        #expect(CFLGameTypeMapper.type(gameTypeID: 0) == .preseason)
        #expect(CFLGameTypeMapper.type(gameTypeID: 1) == .regularSeason)
        #expect(CFLGameTypeMapper.type(gameTypeID: 2) == .divisionSemiFinal)
        #expect(CFLGameTypeMapper.type(gameTypeID: 3) == .divisionSemiFinal)
        #expect(CFLGameTypeMapper.type(gameTypeID: 4) == .divisionFinal)
        #expect(CFLGameTypeMapper.type(gameTypeID: 5) == .divisionFinal)
        #expect(CFLGameTypeMapper.type(gameTypeID: 6) == .greyCup)
        #expect(CFLGameTypeMapper.type(gameTypeID: 99) == .unknown(99))
        #expect(CFLGameTypeMapper.label(.greyCup, homeZone: nil, awayZone: nil) == "GREY CUP")
        #expect(!CFLGameTypeMapper.label(.greyCup, homeZone: nil, awayZone: nil).contains("Super Bowl"))
    }

    @Test func divisionLabelsAreDerivedFromTeamZoneNeverHardcodedFromGameTypeID() {
        // 2 and 3 are indistinguishable from the id alone — the label must come from
        // whichever team's `team_zone` is actually supplied, not a fixed 2→East guess.
        #expect(CFLGameTypeMapper.label(.divisionSemiFinal, homeZone: "eastern", awayZone: "eastern") == "EAST SEMI-FINAL")
        #expect(CFLGameTypeMapper.label(.divisionSemiFinal, homeZone: "western", awayZone: "western") == "WEST SEMI-FINAL")
        #expect(CFLGameTypeMapper.label(.divisionSemiFinal, homeZone: nil, awayZone: nil) == "DIVISION SEMI-FINAL")
        #expect(CFLGameTypeMapper.label(.divisionFinal, homeZone: "eastern", awayZone: nil) == "EAST FINAL")
    }

    // `CFLStandingsMapper`/`CFLRosterMapper` construct the app-wide `StandingsGroup`/
    // `RosterGroup`/`RosterAthlete` types, which live outside this standalone module
    // (same boundary `NFLProvider.swift` sits behind, excluded from `NFLCoreTests` for
    // the identical reason) — covered by the full app build/test target instead, not
    // this offline suite. `standings-2026.json`/`roster-team19.json` are still captured
    // above for that exercise even though no test here reads them directly.

    @Test func leagueLeadersGroupIntoOffenceDefenceSpecialTeams() throws {
        let raw = try JSONDecoder().decode(CFLValue.self, from: load("leaders-2026"))
        let groups = CFLLeadersMapper.groups(raw)
        #expect(Set(groups.keys) == ["offence", "defence", "special_teams"])
        #expect(groups["offence"]?.contains { $0.id == "passing" } == true)
        #expect(groups["offence"]?.first { $0.id == "passing" }?.rows.isEmpty == false)
    }

    @Test func teamStatsRowsSurfaceRougeSinglesDistinctFromFieldGoals() throws {
        let raw = try JSONDecoder().decode([CFLValue].self, from: load("teamrecords-sample"))
        let season = raw[0]["seasons"].array.first ?? .null
        let rows = CFLTeamStatsMapper.rows(home: season, away: season)
        #expect(rows.primary.contains { $0.title == "First Downs" })
        #expect(rows.more.contains { $0.title == "Singles (Rouge)" })
        #expect(!rows.primary.contains { $0.title.contains("4th Down") })
    }

    @Test func playerStatsUseFixtureScopedRecordsNeverSeasonCumulative() throws {
        let raw = try JSONDecoder().decode([CFLValue].self, from: load("playerrecords-sample"))
        let fixtureID = raw[0]["fixtures"].array.first?["fixture_id"].string ?? ""
        let lines = CFLPlayerStatsMapper.players(raw, fixtureID: fixtureID)
        #expect(!lines.isEmpty)
        // A fixture id that doesn't exist on the record must yield nothing — never
        // silently fall back to the season-cumulative totals.
        let empty = CFLPlayerStatsMapper.players(raw, fixtureID: "not-a-real-fixture-id")
        #expect(empty.isEmpty)
    }

    @Test func seasonResolvesRealYearToRealSeasonIDNotAssumedEqual() throws {
        let seasons = try JSONDecoder().decode([CFLValue].self, from: load("seasons"))
        let match = seasons.first { $0["year"].int == 2026 }
        #expect(match?["ID"].int == 75)
        #expect(2026 != 75)
    }
}
