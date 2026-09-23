import Foundation
import Testing
import Darwin
@testable import F1Core

@main struct Runner {
    static func main() async {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--snapshot-smoke") {
            let updates = await F1LiveSnapshotService.shared.snapshot()
            print("Discovery snapshot topics: \(updates.map(\.topic).sorted())")
            _exit(updates.contains { $0.topic == "SessionInfo" } ? 0 : 1)
        }
        if CommandLine.arguments.contains("--archive-smoke") {
            do {
                let session = F1ScheduledSession(id: "2025.1.Race", meeting: "Australian Grand Prix", circuit: "Albert Park", name: "Race", start: F1Date.parse("2025-03-16T04:00:00Z") ?? .distantPast, season: 2025, round: 1)
                guard let path = try await F1ArchiveService.shared.path(for: session) else { print("Archive session not found"); exit(1) }
                let store = F1TopicStateStore(identity: session.id)
                for update in try await F1ArchiveService.shared.updates(path: path) { await store.apply(update) }
                let state = await store.normalized()
                print("Archive: \(state.meeting), \(state.name), \(state.status), \(state.drivers.count) drivers, \(state.messages.count) control messages, \(state.radio.count) radios, \(state.pitStops.count) pit stops")
                guard !state.drivers.isEmpty, !state.messages.isEmpty else { exit(1) }
            } catch { print("Archive smoke failed: \(error)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--live-smoke") {
            let client = F1SignalRClient()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await client.run { event in
                        switch event {
                        case .connection(let state, let attempts): print("Connection: \(state), attempts \(attempts)")
                        case .snapshot(let updates): print("Snapshot topics: \(updates.map(\.topic).sorted())")
                        case .update(let update): print("Topic: \(update.topic)")
                        case .error(let text): print("Feed error: \(text)")
                        case .activity: break
                        }
                        fflush(stdout)
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(12))
                    print("Simulating connection interruption")
                    await client.reconnect()
                    try? await Task.sleep(for: .seconds(33))
                }
                await group.next(); group.cancelAll()
            }
            _exit(0)
        }
        let result: CInt = await Testing.__swiftPMEntryPoint(); exit(result)
    }
}
