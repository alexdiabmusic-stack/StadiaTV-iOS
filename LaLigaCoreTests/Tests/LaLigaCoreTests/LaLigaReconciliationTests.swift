import Foundation
import Testing
@testable import LaLigaCore

private struct StubFotMobClient: FotMobClientProtocol {
    var matchesResponse: FotMobValue = .null
    func leagues(id: Int, season: String?) async throws -> FotMobValue { .null }
    func matches(date: String, timezone: String?) async throws -> FotMobValue { matchesResponse }
    func matchDetails(matchId: String) async throws -> FotMobValue { .null }
    func liveTickerRaw(ltcUrl: String) async throws -> Data { Data() }
}

private func temporaryStore() -> SoccerProviderMappingStore {
    SoccerProviderMappingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
}

@Suite("La Liga team alias normalization")
struct LaLigaFotMobTeamAliasesTests {
    @Test func stripsDiacriticsToMatchFotMobsCasualNames() {
        // Verified live 2026-09-24: official "Deportivo Alavés" vs FotMob "Deportivo Alaves".
        #expect(LaLigaFotMobTeamAliases.normalize("Deportivo Alavés") == LaLigaFotMobTeamAliases.normalize("Deportivo Alaves"))
    }
    @Test func explicitAliasForStructurallyDifferentNames() {
        #expect(LaLigaFotMobTeamAliases.normalize("Athletic Club") == LaLigaFotMobTeamAliases.normalize("Athletic Bilbao"))
    }
    @Test func formalLegalNameCollapsesToCasualName() {
        #expect(LaLigaFotMobTeamAliases.normalize("Fútbol Club Barcelona") == LaLigaFotMobTeamAliases.normalize("Barcelona"))
    }
}

@Suite("La Liga <-> FotMob match resolver")
struct LaLigaFotMobMatchResolverTests {
    @Test func resolvesRealFixtureByTeamNamesAndKickoffWindow() async throws {
        let raw = try fotmobFixture("fotmob-day-matches")
        let client = StubFotMobClient(matchesResponse: raw)
        let resolver = LaLigaFotMobMatchResolver(client: client, store: temporaryStore())
        let kickoff = ISO8601DateFormatter().date(from: "2026-08-15T17:30:00Z")!
        let fotmobID = await resolver.resolve(officialMatchID: "102249", homeTeamID: "16", awayTeamID: "25",
            homeTeamName: "Deportivo Alavés", awayTeamName: "Getafe", kickoff: kickoff)
        #expect(fotmobID == "5868011")
    }

    @Test func unresolvedNeverGuessesFromAWrongTeamPairing() async throws {
        let raw = try fotmobFixture("fotmob-day-matches")
        let client = StubFotMobClient(matchesResponse: raw)
        let resolver = LaLigaFotMobMatchResolver(client: client, store: temporaryStore())
        let kickoff = ISO8601DateFormatter().date(from: "2026-08-15T17:30:00Z")!
        // Real teams, but not actually playing each other on this date — must
        // stay unresolved rather than guessing from a same-day/same-score coincidence.
        let fotmobID = await resolver.resolve(officialMatchID: "999999", homeTeamID: "1", awayTeamID: "2",
            homeTeamName: "Real Madrid", awayTeamName: "Barcelona", kickoff: kickoff)
        #expect(fotmobID == nil)
    }

    @Test func confirmedMappingIsCachedAndReusedWithoutRefetching() async throws {
        let store = temporaryStore()
        await store.confirmMatch(officialID: "102249", fotmobID: "5868011")
        // `.null` matchesResponse would fail to extract any candidate — proving the
        // resolver never re-consulted FotMob because the cached mapping short-circuits it.
        let client = StubFotMobClient(matchesResponse: .null)
        let resolver = LaLigaFotMobMatchResolver(client: client, store: store)
        let fotmobID = await resolver.resolve(officialMatchID: "102249", homeTeamID: "16", awayTeamID: "25",
            homeTeamName: "Deportivo Alavés", awayTeamName: "Getafe", kickoff: Date())
        #expect(fotmobID == "5868011")
    }
}

@Suite("Optional player reconciliation")
struct LaLigaFotMobPlayerResolverTests {
    @Test func matchesOnNormalizedNameAndShirtNumber() {
        let official = SoccerRosterPlayer(reference: SoccerPlayerReference(id: "p60772", firstName: "Thibaut", lastName: "Courtois"), position: "Goalkeeper", shirtNumber: "1", nationality: "BE", dateOfBirth: nil)
        let candidates = [SoccerLineupPlayer(reference: SoccerPlayerReference(id: "530468", firstName: "Thibaut", lastName: "Courtois"), shirtNumber: "1", position: nil, isCaptain: false, isStarter: true)]
        #expect(LaLigaFotMobPlayerResolver.resolve(officialPlayer: official, fotmobCandidates: candidates) == "530468")
    }

    @Test func ambiguousDuplicateNameStaysUnresolved() {
        let official = SoccerRosterPlayer(reference: SoccerPlayerReference(id: "p1", firstName: "John", lastName: "Smith"), position: nil, shirtNumber: "9", nationality: nil, dateOfBirth: nil)
        // Two same-name candidates with no shirt number on file — genuinely ambiguous.
        let candidates = [
            SoccerLineupPlayer(reference: SoccerPlayerReference(id: "a", firstName: "John", lastName: "Smith"), shirtNumber: nil, position: nil, isCaptain: false, isStarter: true),
            SoccerLineupPlayer(reference: SoccerPlayerReference(id: "b", firstName: "John", lastName: "Smith"), shirtNumber: nil, position: nil, isCaptain: false, isStarter: false),
        ]
        #expect(LaLigaFotMobPlayerResolver.resolve(officialPlayer: official, fotmobCandidates: candidates) == nil)
    }

    @Test func noMatchStaysUnresolved() {
        let official = SoccerRosterPlayer(reference: SoccerPlayerReference(id: "p1", firstName: "Jane", lastName: "Doe"), position: nil, shirtNumber: "7", nationality: nil, dateOfBirth: nil)
        let candidates = [SoccerLineupPlayer(reference: SoccerPlayerReference(id: "a", firstName: "John", lastName: "Smith"), shirtNumber: "7", position: nil, isCaptain: false, isStarter: true)]
        #expect(LaLigaFotMobPlayerResolver.resolve(officialPlayer: official, fotmobCandidates: candidates) == nil)
    }
}
