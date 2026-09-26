import Foundation
import Testing
@testable import LaLigaCore

func fixtureData(_ name: String, ext: String = "json") throws -> Data {
    #if SWIFT_PACKAGE
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    #else
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).\(ext)")
    #endif
    return try Data(contentsOf: url)
}
func laligaFixture(_ name: String) throws -> LaLigaValue { try JSONDecoder().decode(LaLigaValue.self, from: fixtureData(name)) }

@Suite("LaLiga status mapping")
struct LaLigaStatusMapperTests {
    // Only "PreMatch" and "FullTime" were directly observed live 2026-09-24 — the
    // rest are inferred from PulseLive's equivalent PascalCase vocabulary.
    @Test func observedStatuses() {
        #expect(LaLigaStatusMapper.status("PreMatch") == .scheduled)
        #expect(LaLigaStatusMapper.status("FullTime") == .fullTime)
    }
    @Test func inferredStatuses() {
        #expect(LaLigaStatusMapper.status("FirstHalf") == .firstHalf)
        #expect(LaLigaStatusMapper.status("HalfTime") == .halftime)
        #expect(LaLigaStatusMapper.status("SecondHalf") == .secondHalf)
        #expect(LaLigaStatusMapper.status("Postponed") == .postponed)
        #expect(LaLigaStatusMapper.status("Suspended") == .suspended)
    }
    @Test func unknownNeverCrashes() {
        #expect(LaLigaStatusMapper.status("SomeFutureState") == .unknown("SomeFutureState"))
        #expect(LaLigaStatusMapper.status(nil) == .scheduled)
    }
}

@Suite("LaLiga match mapping")
struct LaLigaMatchMapperTests {
    @Test func preMatchHasNilScoresNeverZero() throws {
        let raw = try laligaFixture("official-matches-prematch")
        let row = raw["matches"].array[0]
        let match = LaLigaMatchMapper.match(row, season: "2026")
        #expect(match?.status == .scheduled)
        #expect(match?.home.score == nil)
        #expect(match?.away.score == nil)
        #expect(match?.matchWeek == 38)
        #expect(match?.ground == "Anoeta")
    }

    @Test func finishedMatchHasRealScores() throws {
        let raw = try laligaFixture("official-matches-finished")
        let row = raw["matches"].array[0]
        let match = LaLigaMatchMapper.match(row, season: "2026")
        #expect(match?.status == .fullTime)
        #expect(match?.home.score == 3)
        #expect(match?.away.score == 0)
        #expect(match?.matchWeek == 1)
    }

    @Test func teamAbbreviationUsesShortname() throws {
        let raw = try laligaFixture("official-matches-prematch")
        let team = LaLigaMatchMapper.team(raw["matches"].array[0]["home_team"])
        #expect(team?.name == "Real Sociedad de Fútbol SAD")
        #expect(team?.shortName == "Real Sociedad")
        #expect(team?.abbreviation == "RSO")
    }
}

@Suite("LaLiga standings mapping")
struct LaLigaStandingsMapperTests {
    @Test func mapsAllTwentyRows() throws {
        let raw = try laligaFixture("official-standing")
        let table = LaLigaMatchMapper.standingsTable(raw)
        #expect(table.entries.count == 20)
        #expect(table.isLive == false) // Step 30 — never a live table
        let first = table.entries.first { $0.overall.position == 1 }
        #expect(first?.team.name == "Fútbol Club Barcelona")
        #expect(first?.overall.points == 94)
        #expect(first?.overall.goalDifference == 59)
    }
}

@Suite("LaLiga squad mapping")
struct LaLigaSquadMapperTests {
    @Test func mapsActivePlayersOnlyByDefault() throws {
        let raw = try laligaFixture("official-squad")
        let roster = LaLigaSquadMapper.roster(raw)
        #expect(!roster.isEmpty)
        #expect(roster.allSatisfy { !$0.reference.id.isEmpty })
    }

    @Test func usesOptaIDNotPersonIDOrRowID() throws {
        let raw = try laligaFixture("official-squad")
        let row = raw["squads"].array[0]
        let player = LaLigaSquadMapper.player(row)
        // Verified live 2026-09-24: row.id=84728, person.id=560, opta_id="p60772" — the
        // reference id must be the opta_id, not either numeric id.
        #expect(player?.reference.id == "p60772")
        #expect(player?.reference.firstName == "Thibaut")
        #expect(player?.reference.lastName == "Courtois")
    }

    @Test func positionIDTranslatesToEnglishLabel() throws {
        let raw = try laligaFixture("official-squad")
        let goalkeeperRow = raw["squads"].array[0]
        #expect(LaLigaSquadMapper.player(goalkeeperRow)?.position == "Goalkeeper")
    }
}

@Suite("LaLiga rounds mapping")
struct LaLigaRoundsMapperTests {
    @Test func flattensGameweeksAcrossRounds() throws {
        let raw = try laligaFixture("official-rounds")
        let rounds = LaLigaRoundsMapper.rounds(raw)
        #expect(!rounds.isEmpty)
        #expect(rounds.contains { $0.week == 38 })
        #expect(rounds.allSatisfy { $0.startDate != nil })
    }
}
