import Foundation
import Testing
@testable import F1Core

private struct ControlledFeed: F1Streaming {
    let events: [F1StreamEvent]
    let delay: Duration
    func run(deliver: @escaping @Sendable (F1StreamEvent) async -> Void) async {
        // Deliberately deliver even after cancellation to exercise the UI generation guard.
        try? await Task.sleep(for: delay)
        for event in events { await deliver(event) }
    }
}
@Suite("F1 lifecycle") struct F1LifecycleTests {
    private func session(_ id: String, start: Date) -> F1ScheduledSession { F1ScheduledSession(id: id, meeting: "Recorded session", circuit: "Albert Park", name: "Race", start: start, season: 2026, round: 1) }
    private func updates(start: Date) throws -> [F1TopicUpdate] {
        var info = try fixture("SessionInfo").object
        info["StartDate"] = .string(ISO8601DateFormatter().string(from: start)); info["GmtOffset"] = .string("00:00:00")
        return [F1TopicUpdate(topic: "SessionInfo", payload: .object(info), timestamp: start, snapshot: true),
                F1TopicUpdate(topic: "DriverList", payload: try fixture("DriverList"), timestamp: start, snapshot: true),
                F1TopicUpdate(topic: "SessionStatus", payload: try value(#"{"Status":"Started"}"#), timestamp: start, snapshot: true)]
    }
    @Test @MainActor func switchingAndBackgroundRejectInFlightSnapshot() async throws {
        let now = Date(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = ControlledFeed(events: [.snapshot(try updates(start: now))], delay: .milliseconds(80))
        let model = F1RaceCentreViewModel(stream: feed, cache: F1SessionCache(directory: directory))
        let first = Task { await model.run(session: session("A", start: now), active: true) }
        try await Task.sleep(for: .milliseconds(15))
        first.cancel()
        await model.run(session: session("B", start: now), active: false)
        await first.value
        #expect(model.state == nil)
        #expect(model.connection == .disconnected)
        await model.run(session: session("B", start: now), active: true)
        #expect(model.state?.identity == "B")
        #expect(model.state?.drivers.count == 20)
        await model.run(session: session("B", start: now), active: false)
        #expect(model.state?.drivers.count == 20)
        #expect(model.isLive(at: .now) == false)
    }
    @Test @MainActor func wrongSessionRejectedAndCacheRetained() async throws {
        let now = Date(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = F1SessionCache(directory: directory)
        var cached = F1SessionState(identity: "expected"); cached.meeting = "Cached meeting"
        await cache.save(cached)
        let feed = ControlledFeed(events: [.snapshot(try updates(start: now.addingTimeInterval(-86400)))], delay: .zero)
        let model = F1RaceCentreViewModel(stream: feed, cache: cache)
        await model.run(session: session("expected", start: now), active: true)
        #expect(model.state?.meeting == "Cached meeting")
        #expect(model.cached)
        #expect(model.error != nil)
    }
    @Test @MainActor func replayBuildsCanonicalState() async throws {
        let now = Date(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = F1RaceCentreViewModel(stream: F1ReplayClient(updates: try updates(start: now), speed: 0), cache: F1SessionCache(directory: directory))
        await model.run(session: session("replay", start: now), active: true)
        #expect(model.state?.drivers.count == 20)
        #expect(model.state?.identity == "replay")
    }
}
