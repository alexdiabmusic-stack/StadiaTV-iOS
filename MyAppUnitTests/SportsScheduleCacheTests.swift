import Foundation
import Testing
@testable import BannerTV

@Suite("Shared sports schedule cache")
struct SportsScheduleCacheTests {
    @Test("Same local-day requests from different tabs share one fetch")
    func coalescesDayRequests() async throws {
        let path = "test/\(UUID().uuidString)"
        let provider = ScheduleProbe(path: path)
        let repository = SportsRepository(providers: [provider])
        let league = League(name: "Test", shortName: "Test", path: path, group: .soccer)
        let day = Calendar.current.startOfDay(for: Date())
        async let first = repository.legacyScoreboards(for: league, starting: day.addingTimeInterval(60), days: 7)
        async let second = repository.legacyScoreboards(for: league, starting: day.addingTimeInterval(120), days: 7)
        _ = try await (first, second)
        #expect(await provider.requests == 1)
        #expect(await provider.lastStart == day)
    }

    @Test("Zero-day requests do not call the provider")
    func emptyWindow() async throws {
        let path = "test/\(UUID().uuidString)"
        let provider = ScheduleProbe(path: path)
        let repository = SportsRepository(providers: [provider])
        let league = League(name: "Test", shortName: "Test", path: path, group: .soccer)
        #expect(try await repository.legacyScoreboards(for: league, starting: Date(), days: 0).isEmpty)
        #expect(await provider.requests == 0)
    }
}

private actor ScheduleProbe: NativeSportsProvider {
    nonisolated let leaguePath: String
    var requests = 0
    var lastStart: Date?
    init(path: String) { leaguePath = path }
    func schedule(start: Date, days: Int) async throws -> [Match] {
        requests += 1
        lastStart = start
        try await Task.sleep(for: .milliseconds(20))
        return []
    }
    func scores(on date: Date?) async throws -> [Match] { [] }
    func teams() async throws -> [Team] { [] }
    func standings() async throws -> [StandingsGroup] { [] }
    func roster(teamID: String) async throws -> [RosterGroup] { [] }
    func playerOverview(id: String) async throws -> AthleteOverview {
        throw SportsDataError.unsupportedCapability(.players)
    }
}
