import Foundation
import Testing
@testable import MLBCore

private actor DelayedMLBService: MLBGameCenterServing {
    let feed: MLBGameFeedResponse
    private(set) var requested: [Int] = []
    init(feed: MLBGameFeedResponse) { self.feed = feed }
    func fetch(gamePk: Int, tab: MLBGameTab, full: Bool, includeContent: Bool) async throws -> MLBGameCenterUpdate {
        requested.append(gamePk)
        if gamePk == feed.gamePk {
            try? await Task.sleep(for: .milliseconds(100))
            return MLBGameCenterUpdate(gamePk: gamePk, requestedAt: Date(), feed: feed)
        }
        return MLBGameCenterUpdate(gamePk: gamePk, requestedAt: Date(), errors: ["overview": "Offline"])
    }
}
@MainActor private func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await predicate()) {
        guard ContinuousClock.now < end else { throw NSError(domain: "MLBTestTimeout", code: 1) }
        try await Task.sleep(for: .milliseconds(10))
    }
}
@Suite("MLB lifecycle")
struct MLBLifecycleTests {
    @Test @MainActor func gameSwitchRejectsLateResponse() async throws {
        let service = DelayedMLBService(feed: try fixture("final"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MLBGameCenterViewModel(service: service, cache: MLBGameCenterCache(directory: directory))
        let first = Task { await model.run(gamePk: 744834, active: true) }
        try await waitUntil { await service.requested.count == 1 }
        first.cancel()
        let second = Task { await model.run(gamePk: 999, active: true) }
        try await waitUntil { model.errors["overview"] == "Offline" }
        await first.value
        #expect(model.snapshot?.gamePk == 999); #expect(model.snapshot?.atBats.isEmpty == true)
        second.cancel(); await second.value
    }
    @Test @MainActor func backgroundStopsForegroundRefreshes() async throws {
        let service = DelayedMLBService(feed: try fixture("live-early"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MLBGameCenterViewModel(service: service, cache: MLBGameCenterCache(directory: directory))
        let first = Task { await model.run(gamePk: 744834, active: true) }
        try await waitUntil { model.snapshot?.game != nil && !model.isRefreshing }
        #expect(model.pollInterval == 10)
        first.cancel(); await first.value
        await model.run(gamePk: 744834, active: false)
        #expect(await service.requested.count == 1)
        let second = Task { await model.run(gamePk: 744834, active: true) }
        try await waitUntil { await service.requested.count == 2 && !model.isRefreshing }
        second.cancel(); await second.value
    }
    @Test @MainActor func finalStopsAndDelaySlows() async throws {
        for name in ["final", "rain-delay", "between-innings", "warmup"] {
            let service = DelayedMLBService(feed: try fixture(name))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let model = MLBGameCenterViewModel(service: service, cache: MLBGameCenterCache(directory: directory))
            let task = Task { await model.run(gamePk: 744834, active: true) }
            try await waitUntil { model.snapshot?.game != nil && !model.isRefreshing }
            if name == "final" { await task.value; #expect(await service.requested.count == 1) }
            if name == "rain-delay" { #expect(model.pollInterval == 30) }
            if name == "between-innings" || name == "warmup" { #expect(model.pollInterval == 25) }
            task.cancel(); await task.value; try? FileManager.default.removeItem(at: directory)
        }
    }
}
