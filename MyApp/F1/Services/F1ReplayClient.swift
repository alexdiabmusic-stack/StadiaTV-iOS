import Foundation

nonisolated struct F1ReplayClient: F1Streaming {
    let updates: [F1TopicUpdate]
    var speed = 1.0
    func run(deliver: @escaping @Sendable (F1StreamEvent) async -> Void) async {
        await deliver(.connection(.connected, 0))
        var index = 0
        var last: Date?
        while index < updates.count {
            guard !Task.isCancelled else { return }
            let update = updates[index]
            if let last, speed > 0 {
                do { try await Task.sleep(for: .seconds(max(0, update.timestamp.timeIntervalSince(last)) / speed)) } catch { return }
            }
            if update.snapshot {
                let start = index
                while index < updates.count && updates[index].snapshot { index += 1 }
                await deliver(.snapshot(Array(updates[start..<index])))
            } else {
                await deliver(.update(update)); index += 1
            }
            await deliver(.activity(update.timestamp)); last = update.timestamp
        }
        await deliver(.connection(.disconnected, 0))
    }
    static func load(_ url: URL) throws -> [F1TopicUpdate] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(F1TopicUpdate.self, from: Data($0.utf8)) }
    }
}
#if DEBUG
actor F1FixtureRecorder {
    private let url: URL
    private var bytes = 0
    init(url: URL) { self.url = url }
    func record(_ update: F1TopicUpdate) throws {
        guard bytes < 64 * 1024 * 1024 else { return }
        var data = try JSONEncoder().encode(update); data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data); bytes += data.count
    }
}
#endif
