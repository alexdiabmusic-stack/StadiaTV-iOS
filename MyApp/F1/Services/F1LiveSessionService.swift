import Foundation
import Observation

@MainActor @Observable final class F1HighFrequencyViewModel {
    var state = F1HighFrequencyState()
}
@MainActor @Observable final class F1RaceCentreViewModel {
    private(set) var state: F1SessionState?
    private(set) var connection: F1ConnectionState = .disconnected
    private(set) var lastMessageReceivedAt: Date?
    private(set) var lastHeartbeatAt: Date?
    private(set) var lastDataReceivedAt: Date?
    private(set) var reconnectAttempts = 0
    private(set) var error: String?
    private(set) var cached = false
    let highFrequency = F1HighFrequencyViewModel()
    private let stream: any F1Streaming
    private let cache: F1SessionCache
    private let replaying: Bool
    private var generation = UUID()
    private var lastSlowUpdate = Date.distantPast
    private var lastFastUpdate = Date.distantPast
    private var lastSave = Date.distantPast
    private var acceptedLiveSession = false
    private var pendingPublish: Task<Void, Never>?
    #if DEBUG
    var recorder: F1FixtureRecorder?
    #endif
    init(stream: (any F1Streaming)? = nil, cache: F1SessionCache = .shared) { self.stream = stream ?? F1SignalRClient(); self.cache = cache; self.replaying = stream is F1ReplayClient }
    func run(session: F1ScheduledSession, active: Bool) async {
        let token = UUID(); generation = token; connection = .disconnected; acceptedLiveSession = false
        pendingPublish?.cancel(); pendingPublish = nil
        defer { if token == generation { pendingPublish?.cancel(); pendingPublish = nil } }
        if state?.identity != session.id { state = nil; highFrequency.state = F1HighFrequencyState(); error = nil; acceptedLiveSession = false }
        if state == nil {
            let restored = await cache.load(session.id)
            guard token == generation, !Task.isCancelled else { return }
            state = restored; cached = restored != nil
        }
        guard token == generation, !Task.isCancelled else { return }
        guard active else { if let state { await cache.save(state) }; return }
        while !replaying && session.start.timeIntervalSinceNow > 3600 {
            do { try await Task.sleep(for: .seconds(min(300, session.start.timeIntervalSinceNow - 3600))) } catch { return }
            guard token == generation, !Task.isCancelled else { return }
        }
        let store = F1TopicStateStore(identity: session.id)
        if !replaying && session.start < Date().addingTimeInterval(-4 * 3600) {
            do {
                if let path = try await F1ArchiveService.shared.path(for: session) {
                    let updates = try await F1ArchiveService.shared.updates(path: path)
                    for update in updates { await store.apply(update) }
                    let normalized = await store.normalized()
                    guard token == generation, !Task.isCancelled else { return }
                    state = normalized; cached = false; await cache.save(normalized)
                    if let official = try? await F1ResultsService.shared.result(for: session) {
                        guard token == generation, !Task.isCancelled else { return }
                        let enriched = F1ResultsService.merge(official, into: normalized)
                        state = enriched; await cache.save(enriched)
                    }
                    return
                }
            } catch { if token == generation && !Task.isCancelled { self.error = error.localizedDescription } }
        }
        if !replaying && session.start < Date().addingTimeInterval(-4 * 3600),
           let official = try? await F1ResultsService.shared.result(for: session) {
            guard token == generation, !Task.isCancelled else { return }
            state = official; cached = false; error = nil; await cache.save(official); return
        }
        // A future meeting must never display the feed's different current event.
        guard replaying || (session.start < Date().addingTimeInterval(3600) && session.start > Date().addingTimeInterval(-12 * 3600)) else { if state == nil && session.start < Date() { error = "Archived timing is not available for this session yet." }; return }
        await stream.run { [weak self] event in
            await self?.receive(event, store: store, session: session, token: token)
        }
    }
    private func receive(_ event: F1StreamEvent, store: F1TopicStateStore, session: F1ScheduledSession, token: UUID) async {
        guard token == generation, !Task.isCancelled else { return }
        switch event {
        case .connection(let connection, let attempts):
            self.connection = connection; reconnectAttempts = attempts
            if connection == .reconnecting || connection == .negotiating { acceptedLiveSession = false }
        case .activity(let date): lastMessageReceivedAt = date
        case .error(let text): error = text
        case .snapshot(let updates):
            let info = updates.first { $0.topic == "SessionInfo" }?.payload
            guard let info, matches(info, session) else { acceptedLiveSession = false; error = "The live feed is currently serving another session."; return }
            await store.reset()
            guard token == generation, !Task.isCancelled else { return }
            acceptedLiveSession = true; lastDataReceivedAt = Date()
            if updates.contains(where: { $0.topic == "Heartbeat" }) { lastHeartbeatAt = Date() }
            for update in updates {
                await store.apply(update)
                #if DEBUG
                try? await recorder?.record(update)
                #endif
            }
            await publish(store: store, token: token, force: true)
        case .update(let update):
            if update.topic == "SessionInfo" {
                let previousPath = state?.path
                if update.payload["StartDate"].string != nil && !matches(update.payload, session) { acceptedLiveSession = false; error = "The live feed has moved to another session."; return }
                if let path = update.payload["Path"].string, let previousPath, path != previousPath { acceptedLiveSession = false; return }
            }
            guard acceptedLiveSession else { return }
            #if DEBUG
            try? await recorder?.record(update)
            #endif
            let accepted = await store.apply(update)
            guard accepted else { return }
            lastDataReceivedAt = Date()
            if update.topic == "Heartbeat" { lastHeartbeatAt = Date() }
            if update.topic == "CarData.z" || update.topic == "Position.z" {
                if Date().timeIntervalSince(lastFastUpdate) >= 0.2 {
                    let fast = await store.fastState()
                    guard token == generation else { return }
                    highFrequency.state = fast; lastFastUpdate = Date()
                }
            } else { await publish(store: store, token: token, force: update.topic == "RaceControlMessages" || update.topic == "SessionStatus") }
        }
    }
    private func matches(_ info: F1Value, _ session: F1ScheduledSession) -> Bool {
        guard let start = F1ArchiveService.utcStart(info), abs(start.timeIntervalSince(session.start)) < 3600 else { return false }
        let type = F1SessionType(info["Name"].string ?? info["Type"].string ?? "")
        if type == .practice && info["Name"].string != session.name { return false }
        return type == session.type
    }
    private func publish(store: F1TopicStateStore, token: UUID, force: Bool) async {
        guard force || Date().timeIntervalSince(lastSlowUpdate) >= 0.5 else {
            if pendingPublish == nil {
                pendingPublish = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, token == self.generation else { return }
                    self.pendingPublish = nil
                    await self.publish(store: store, token: token, force: true)
                }
            }
            return
        }
        pendingPublish?.cancel(); pendingPublish = nil
        let normalized = await store.normalized()
        guard token == generation, !Task.isCancelled else { return }
        if state != normalized { state = normalized }
        lastSlowUpdate = Date(); cached = false; error = nil
        if normalized.finalised || Date().timeIntervalSince(lastSave) > 30 { await cache.save(normalized); lastSave = Date() }
    }
    #if DEBUG
    static func configuredForDebugReplay() -> F1RaceCentreViewModel {
        if let path = ProcessInfo.processInfo.environment["F1_REPLAY_FILE"],
           let updates = try? F1ReplayClient.load(URL(fileURLWithPath: path)) {
            return F1RaceCentreViewModel(stream: F1ReplayClient(updates: updates))
        }
        return F1RaceCentreViewModel()
    }
    #endif
    func isLive(at date: Date) -> Bool { state?.active == true && connection == .connected && !cached && date.timeIntervalSince(lastMessageReceivedAt ?? .distantPast) < 30 && date.timeIntervalSince(lastDataReceivedAt ?? .distantPast) < 30 }
}
