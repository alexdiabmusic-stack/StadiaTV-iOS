import Foundation

/// Remembers how individual streams behaved across sessions so Auto can start on a
/// source that worked last time and deprioritise ones that keep failing.
///
/// Keyed by stream ID (the provider channel ID). Stored in UserDefaults and capped so
/// large playlists don't grow it without bound.
@MainActor
final class StreamHealthStore {
    static let shared = StreamHealthStore()

    struct Record: Codable, Equatable, Sendable {
        var lastSuccess: Date?
        var lastTTFFMs: Int?
        var lastFailure: Date?

        /// True when the most recent outcome was a successful start.
        var lastOutcomeWasSuccess: Bool {
            guard let lastSuccess else { return false }
            return lastFailure.map { lastSuccess > $0 } ?? true
        }

        fileprivate var lastActivity: Date {
            max(lastSuccess ?? .distantPast, lastFailure ?? .distantPast)
        }
    }

    private let defaultsKey = "bannertv.streamHealth.v1"
    private let maxRecords = 600
    private var records: [String: Record]
    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func record(for streamID: String) -> Record? {
        records[streamID]
    }

    func records(for streamIDs: [String]) -> [String: Record] {
        var result: [String: Record] = [:]
        for id in streamIDs {
            if let record = records[id] { result[id] = record }
        }
        return result
    }

    func recordSuccess(streamID: String, ttffMs: Int?) {
        var record = records[streamID] ?? Record()
        record.lastSuccess = Date()
        if let ttffMs { record.lastTTFFMs = ttffMs }
        records[streamID] = record
        scheduleSave()
    }

    func recordFailure(streamID: String) {
        var record = records[streamID] ?? Record()
        record.lastFailure = Date()
        records[streamID] = record
        scheduleSave()
    }

    /// The stream among `streamIDs` that most recently started successfully and hasn't failed since.
    func lastKnownGood(among streamIDs: [String]) -> String? {
        streamIDs
            .compactMap { id in records[id].flatMap { $0.lastOutcomeWasSuccess ? (id, $0.lastSuccess ?? .distantPast) : nil } }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Coalesces writes; playback start/failure can fire several times in a second.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        if records.count > maxRecords {
            let keep = records.sorted { $0.value.lastActivity > $1.value.lastActivity }.prefix(maxRecords)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
