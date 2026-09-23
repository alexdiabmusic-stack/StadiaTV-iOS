import Foundation

/// Lightweight, coalesced discovery for shared live-score surfaces. The full Race
/// Centre owns its continuous stream; schedule refreshes only need one snapshot.
actor F1LiveSnapshotService {
    static let shared = F1LiveSnapshotService()
    private var cached: (Date, [F1TopicUpdate])?
    private var pending: Task<[F1TopicUpdate], Never>?
    func snapshot() async -> [F1TopicUpdate] {
        if let (date, updates) = cached, Date().timeIntervalSince(date) < 30 { return updates }
        if let pending { return await pending.value }
        let request = Task { await Self.fetch() }
        pending = request
        let updates = await request.value
        cached = (Date(), updates); pending = nil
        return updates
    }
    private static func fetch() async -> [F1TopicUpdate] {
        let client = await MainActor.run { F1SignalRClient(topics: ["SessionInfo", "SessionStatus", "SessionData", "DriverList", "TimingData", "LapCount", "ExtrapolatedClock"]) }
        let (events, continuation) = AsyncStream<F1StreamEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        let connection = Task {
            await client.run { continuation.yield($0) }
            continuation.finish()
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            continuation.finish(); connection.cancel()
        }
        var result: [F1TopicUpdate] = []
        for await event in events {
            if case .snapshot(let updates) = event { result = updates; break }
            if case .connection(.failed, _) = event { break }
        }
        deadline.cancel(); connection.cancel(); continuation.finish()
        await connection.value
        return result
    }
}
