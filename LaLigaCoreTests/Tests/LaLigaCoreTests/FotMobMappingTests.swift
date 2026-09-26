import Foundation
import Testing
@testable import LaLigaCore

func fotmobFixture(_ name: String) throws -> FotMobValue { try JSONDecoder().decode(FotMobValue.self, from: fixtureData(name)) }

@Suite("FotMob status mapping")
struct FotMobStatusMapperTests {
    // Only the finished shape was directly observed live 2026-09-24; pregame/live
    // fixtures here are hand-modified from that real payload (disclosed in
    // LALIGA-INTEGRATION.md), not independently captured.
    @Test func finishedMatch() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        #expect(FotMobStatusMapper.status(raw["header"]["status"]) == .fullTime)
    }
    @Test func pregameMatch() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-pregame")
        #expect(FotMobStatusMapper.status(raw["header"]["status"]) == .scheduled)
    }
    @Test func liveFirstHalf() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-live-firsthalf")
        #expect(FotMobStatusMapper.status(raw["header"]["status"]) == .firstHalf)
    }
    @Test func unknownReasonKeyNeverCrashes() {
        let raw = FotMobValue.object(["started": .bool(true), "finished": .bool(false), "reason": .object(["shortKey": .string("some_future_state")])])
        #expect(FotMobStatusMapper.status(raw) == .unknown("some_future_state"))
    }
}

@Suite("FotMob match overlay")
struct FotMobMatchMapperTests {
    @Test func overlaysScoreClockStatusOntoOfficialBase() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let base = SoccerMatch(id: "102249", competitionID: "1", season: "2026", matchWeek: 1, phase: nil,
            kickoff: Date(), status: .scheduled, clock: nil,
            home: SoccerTeamMatchState(team: SoccerTeam(id: "16", name: "Deportivo Alavés", shortName: "Alavés", abbreviation: "ALA"), score: nil, halfTimeScore: nil, redCards: 0),
            away: SoccerTeamMatchState(team: SoccerTeam(id: "25", name: "Getafe", shortName: "Getafe", abbreviation: "GET"), score: nil, halfTimeScore: nil, redCards: 0),
            ground: "Mendizorrotza", attendance: nil, resultType: nil)
        let overlaid = FotMobMatchMapper.apply(raw, to: base)
        #expect(overlaid.home.score == 3)
        #expect(overlaid.away.score == 0)
        #expect(overlaid.status == .fullTime)
        // Identity fields are never touched by the overlay (Step 19).
        #expect(overlaid.id == "102249")
        #expect(overlaid.ground == "Mendizorrotza")
        #expect(overlaid.home.team.name == "Deportivo Alavés")
    }

    @Test func fotmobMatchIDDistinctFromOfficialID() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        #expect(FotMobMatchMapper.matchID(raw) == "5868011")
    }
}

@Suite("FotMob event mapping")
struct FotMobEventMapperTests {
    private func events() throws -> [SoccerMatchEvent] {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        return FotMobEventMapper.events(raw, matchID: "102249", homeTeamID: "OFFICIAL_HOME", awayTeamID: "OFFICIAL_AWAY")
    }

    @Test func teamIDComesFromOfficialSpaceNeverFotMobNumericID() throws {
        let all = try events()
        #expect(!all.isEmpty)
        #expect(all.allSatisfy { $0.teamID == "OFFICIAL_HOME" || $0.teamID == "OFFICIAL_AWAY" })
    }

    @Test func goalsMapped() throws {
        let goals = try events().filter { $0.type == .goal }
        #expect(goals.count == 3) // verified live 2026-09-24: 3 non-penalty, non-shootout goals
    }

    @Test func cardsMapped() throws {
        let all = try events()
        // Verified live 2026-09-24: 9 Card rows total (8 "Yellow", 1 "Red").
        #expect(all.filter { $0.type == .yellowCard }.count == 8)
        #expect(all.filter { $0.type == .redCard }.count == 1)
    }

    @Test func substitutionsCarryOnAndOffPlayerIDs() throws {
        let subs = try events().filter { $0.type == .substitution }
        #expect(subs.count == 10)
        let first = subs.first { $0.minute == 46 }
        #expect(first?.playerID == "464486") // Enes Ünal — coming on (swap[0])
        #expect(first?.secondaryPlayerID == "1676086") // Davinchi — going off (swap[1])
    }

    @Test func addedTimeAndCommentDropped() throws {
        let all = try events()
        #expect(!all.contains { $0.type == .unknown("addedtime") })
        // "Comment"/"AddedTime" carry no real incident — verified they never
        // surface as a synthesized `.unknown` row either.
        #expect(all.allSatisfy { $0.detail != "+ 3 minutes added" })
    }

    @Test func eventIDsAreUniqueAndStable() throws {
        let all = try events()
        #expect(Set(all.map(\.id)).count == all.count)
    }
}

@Suite("FotMob lineup mapping")
struct FotMobLineupMapperTests {
    @Test func derivesFormationRowsFromCoordinatesAndFormationString() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let home = raw["content"]["lineup"]["homeTeam"]
        let team = SoccerTeam(id: "16", name: "Deportivo Alavés", shortName: "Alavés", abbreviation: "ALA")
        let lineup = FotMobLineupMapper.lineup(home, team: team)
        #expect(lineup?.starters.count == 11)
        #expect(lineup?.formation?.raw == "3-5-2")
        // rows[0] = keeper, then two more lines (3 + 5 + 2 outfield = 10, plus keeper = 11).
        #expect(lineup?.formation?.rows.count == 4)
        #expect(lineup?.formation?.rows[0].count == 1)
        #expect(lineup?.formation?.rows[1].count == 3)
        #expect(lineup?.formation?.rows[2].count == 5)
        #expect(lineup?.formation?.rows[3].count == 2)
    }

    @Test func carriesFotMobRatingLabelledSeparately() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let home = raw["content"]["lineup"]["homeTeam"]
        let team = SoccerTeam(id: "16", name: "Deportivo Alavés", shortName: "Alavés", abbreviation: "ALA")
        let lineup = FotMobLineupMapper.lineup(home, team: team)
        #expect(lineup?.starters.contains { $0.rating != nil } == true)
    }

    @Test func managerNameFromCoach() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let home = raw["content"]["lineup"]["homeTeam"]
        let lineup = FotMobLineupMapper.lineup(home, team: SoccerTeam(id: "16", name: "Alavés", shortName: "Alavés", abbreviation: "ALA"))
        #expect(lineup?.managerName == "Quique Sánchez Flores")
    }
}

@Suite("FotMob stats mapping")
struct FotMobStatsMapperTests {
    @Test func flattensSectionsAndSkipsHeaderDuplicates() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let sides = FotMobStatsMapper.stats(raw, homeTeamID: "H", awayTeamID: "A")
        #expect(sides.home.possession == 52)
        #expect(sides.away.possession == 48)
        #expect(sides.home.shots == 18)
        #expect(sides.away.shots == 6)
        #expect(sides.home.expectedGoals == 1.93)
    }

    @Test func passesCompletedParsesLeadingNumberFromDisplayString() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let sides = FotMobStatsMapper.stats(raw, homeTeamID: "H", awayTeamID: "A")
        #expect(sides.home.passesCompleted == 287) // raw value was "287 (81%)"
    }

    @Test func unmappedFieldsStayNilNeverZero() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let sides = FotMobStatsMapper.stats(raw, homeTeamID: "H", awayTeamID: "A")
        #expect(sides.home.tacklesWon == nil)
        #expect(sides.home.finalThirdEntries == nil)
    }
}

@Suite("FotMob shot map mapping")
struct FotMobShotMapperTests {
    @Test func mapsShotsWithXGWhenSupplied() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let shots = FotMobShotMapper.shots(raw, matchID: "102249", fotmobHomeTeamID: "9866", homeTeamID: "OFFICIAL_HOME", awayTeamID: "OFFICIAL_AWAY")
        #expect(shots.count == 24)
        #expect(shots.allSatisfy { $0.teamID == "OFFICIAL_HOME" || $0.teamID == "OFFICIAL_AWAY" })
        #expect(shots.contains { $0.expectedGoals != nil })
        #expect(shots.contains { $0.outcome == .saved })
    }
}

@Suite("FotMob momentum mapping")
struct FotMobMomentumMapperTests {
    @Test func mapsMinuteValuePairs() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let samples = FotMobMomentumMapper.samples(raw)
        #expect(!samples.isEmpty)
        #expect(samples[0].minute == 0)
    }
}

@Suite("FotMob live ticker: gzip + mapping")
struct FotMobCommentaryMapperTests {
    @Test func derivesURLUsingRealLangCodeNotBareCode() throws {
        let raw = try fotmobFixture("fotmob-matchdetails-finished")
        let url = FotMobCommentaryMapper.ltcURL(fotmobMatchID: "5868011", matchDetails: raw)
        // Verified live 2026-09-24: bare "en" 403s, "en_gen" (from the real `langs`
        // field) is required.
        #expect(url == "https://data.fotmob.com/webcl/ltc/gsm/5868011_en_gen.json.gz")
    }

    @Test func decompressesRealGzipBytesAndMapsEntries() throws {
        // A real captured `.gz` ticker file (verified live 2026-09-24) — not
        // synthetic. Confirms `FotMobGZip` correctly inflates FotMob's gzip
        // container, which `URLSession` never auto-decompresses for this route.
        let data = try fixtureData("fotmob-ticker-finished", ext: "json.gz")
        let entries = try #require(FotMobCommentaryMapper.entries(data))
        #expect(!entries.isEmpty)
        #expect(entries.contains { $0.text.contains("Match ends") })
    }

    @Test func malformedBytesReturnNilNeverCrash() {
        #expect(FotMobCommentaryMapper.entries(Data([0x00, 0x01, 0x02])) == nil)
    }
}
