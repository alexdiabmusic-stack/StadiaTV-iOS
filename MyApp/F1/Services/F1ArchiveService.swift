import Foundation

actor F1ArchiveService {
    static let shared = F1ArchiveService()
    private let client: F1HTTPClient
    private var indices: [Int: (Date, F1Value)] = [:]
    init(client: F1HTTPClient = .shared) { self.client = client }
    func path(for session: F1ScheduledSession) async throws -> String? {
        let index: F1Value
        if let (date, cached) = indices[session.season], Date().timeIntervalSince(date) < 300 { index = cached }
        else { index = try await client.json(F1LiveTimingEndpoint.archive("\(session.season)/Index.json")); indices[session.season] = (Date(), index) }
        // Match archive session type and UTC start, never assume archive meeting
        // number equals championship round (testing meetings are also indexed).
        return index["Meetings"].array.flatMap { $0["Sessions"].array }.first { raw in
            guard F1SessionType(raw["Name"].string ?? raw["Type"].string ?? "") == session.type,
                  let start = Self.utcStart(raw) else { return false }
            if session.type == .practice && raw["Name"].string != session.name { return false }
            return abs(start.timeIntervalSince(session.start)) < 3600
        }?["Path"].string
    }
    nonisolated static func utcStart(_ raw: F1Value) -> Date? {
        guard let text = raw["StartDate"].string else { return nil }
        if let date = F1Date.parse(text) { return date }
        guard let local = F1Date.parse(text + "Z") else { return nil }
        let offset = raw["GmtOffset"].string ?? "00:00:00"
        let sign: Double = offset.hasPrefix("-") ? -1 : 1
        let seconds = F1Date.duration(offset.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))) ?? 0
        return local.addingTimeInterval(-sign * seconds)
    }
    func updates(path: String) async throws -> [F1TopicUpdate] {
        let index = try? await client.json(F1LiveTimingEndpoint.archive(path + "Index.json"))
        let available = Set(index?["Feeds"].object.keys.map { $0 } ?? [])
        let topics = F1LiveTimingEndpoint.topics.filter { !$0.hasSuffix(".z") && (available.isEmpty || available.contains($0)) }
        var result: [F1TopicUpdate] = []
        // Four concurrent requests at a time keeps the archive load bounded.
        for start in stride(from: 0, to: topics.count, by: 4) {
            try await withThrowingTaskGroup(of: F1TopicUpdate?.self) { group in
                for topic in topics[start..<min(start + 4, topics.count)] {
                    group.addTask {
                        do {
                            let raw = try await self.client.json(F1LiveTimingEndpoint.archive(path + topic + ".json"))
                            return F1TopicUpdate(topic: topic, payload: raw, timestamp: Date(), snapshot: true)
                        } catch is CancellationError { throw CancellationError() }
                        catch { return nil }
                    }
                }
                for try await update in group { if let update { result.append(update) } }
            }
        }
        guard result.contains(where: { $0.topic == "TimingData" || $0.topic == "TimingDataF1" }) else { throw F1LiveTimingError.invalidResponse }
        return result
    }
}
