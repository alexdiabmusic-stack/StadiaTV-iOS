import Foundation

actor F1TopicStateStore {
    private var topics: [String: F1Value] = [:]
    private var timestamps: [String: Date] = [:]
    private var telemetry: [String: F1TelemetrySample] = [:]
    private var positions: [String: F1TrackPosition] = [:]
    private var trails: [String: F1RingBuffer<F1TrackPosition>] = [:]
    private var history: [String: F1RingBuffer<F1TelemetrySample>] = [:]
    private var frozen: F1SessionState?
    let identity: String
    init(identity: String) { self.identity = identity }
    func reset() { topics = [:]; timestamps = [:]; telemetry = [:]; positions = [:]; trails = [:]; history = [:]; frozen = nil }
    @discardableResult func apply(_ update: F1TopicUpdate) -> Bool {
        do {
            var payload = update.payload
            if update.topic.hasSuffix(".z") {
                guard let text = payload.string else { throw F1LiveTimingError.decompression }
                payload = try F1CompressedPayloadDecoder.decode(text)
            } else if let text = payload.string, let data = text.data(using: .utf8), let decoded = try? JSONDecoder().decode(F1Value.self, from: data) { payload = decoded }
            let name = update.topic.replacingOccurrences(of: ".z", with: "")
            if let old = timestamps[name], update.timestamp < old { return false }
            timestamps[name] = update.timestamp
            if name == "CarData" { ingestCars(payload, time: update.timestamp); topics[name] = payload; return true }
            if name == "Position" { ingestPositions(payload, time: update.timestamp); topics[name] = payload; return true }
            topics[name] = update.snapshot ? payload : F1DeltaMerger.merge(topics[name] ?? .null, payload)
            if name == "TimingData" || name == "TimingDataF1" {
                topics["CanonicalTiming"] = F1DeltaMerger.merge(topics["CanonicalTiming"] ?? .null, payload)
            }
            #if DEBUG
            if !F1LiveTimingEndpoint.topics.contains(update.topic) { print("F1 unknown topic: \(update.topic)") }
            #endif
            return true
        } catch {
            #if DEBUG
            print("F1 skipped \(update.topic): \(error)")
            #endif
            return false
        }
    }
    func normalized() -> F1SessionState {
        var state = F1TimingMapper.normalize(topics, identity: identity, time: timestamps.values.max() ?? .distantPast)
        if let frozen { state.drivers = frozen.drivers; state.status = frozen.status }
        else if state.finalised { frozen = state }
        return state
    }
    func fastState() -> F1HighFrequencyState {
        F1HighFrequencyState(telemetry: telemetry, positions: positions, trails: trails.mapValues(\.values))
    }
    func samples(driver: String) -> [F1TelemetrySample] { history[driver]?.values ?? [] }
    func rawTopics() -> [String: F1Value] { topics.filter { !["CarData", "Position"].contains($0.key) } }
    private func ingestCars(_ raw: F1Value, time: Date) {
        for entry in raw["Entries"].array {
            let timestamp = F1Date.utc(entry["Utc"].string) ?? time
            for (number, car) in entry["Cars"].object {
                if let old = telemetry[number], old.time > timestamp { continue }
                let c = car["Channels"]
                let sample = F1TelemetrySample(time: timestamp, speed: c["2"].double.flatMap { (0...1000).contains($0) ? $0 : nil }, rpm: c["0"].double.flatMap { (0...100000).contains($0) ? $0 : nil }, gear: c["3"].int.flatMap { (-1...20).contains($0) ? $0 : nil }, throttle: c["4"].double.flatMap { (0...100).contains($0) ? $0 : nil }, brake: c["5"].double.flatMap { (0...100).contains($0) ? $0 : nil },
                    activeAero: F1ActiveAeroState(rawValue: c["45"].double), unknownChannels: c.object.filter { !["0","2","3","4","5","45"].contains($0.key) }.compactMapValues(\.double))
                telemetry[number] = sample
                var ring = history[number] ?? F1RingBuffer(capacity: 150); ring.append(sample); history[number] = ring
            }
        }
    }
    private func ingestPositions(_ raw: F1Value, time: Date) {
        for frame in raw["Position"].array {
            let timestamp = F1Date.utc(frame["Timestamp"].string) ?? time
            for (number, value) in frame["Entries"].object {
                guard let x = value["X"].double, let y = value["Y"].double, abs(x) < 100_000_000, abs(y) < 100_000_000 else { continue }
                if let old = positions[number], old.time > timestamp { continue }
                let position = F1TrackPosition(time: timestamp, x: x, y: y, z: value["Z"].double)
                positions[number] = position
                var ring = trails[number] ?? F1RingBuffer(capacity: 1500); ring.append(position); trails[number] = ring
            }
        }
    }
}
