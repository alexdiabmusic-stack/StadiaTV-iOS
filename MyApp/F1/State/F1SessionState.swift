import Foundation

nonisolated enum F1SessionType: Codable, Sendable, Equatable {
    case practice, qualifying, sprintQualifying, sprint, race, unknown(String)
    init(_ name: String) {
        switch name.lowercased() {
        case "practice", "practice 1", "practice 2", "practice 3": self = .practice
        case "qualifying": self = .qualifying
        case "sprint qualifying", "sprint shootout": self = .sprintQualifying
        case "sprint": self = .sprint
        case "race": self = .race
        default: self = .unknown(name)
        }
    }
    var isRace: Bool { self == .race || self == .sprint }
    var isQualifying: Bool { self == .qualifying || self == .sprintQualifying }
}
nonisolated struct F1Driver: Codable, Sendable, Equatable, Identifiable {
    var id: String { number }
    let number: String
    let name: String
    let tla: String
    let team: String
    let colour: String?
    let country: String?
    let headshot: URL?
}
nonisolated enum F1Performance: String, Codable, Sendable { case neutral, personalBest, overallBest, unknown }
nonisolated struct F1Sector: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let time: String?
    let performance: F1Performance
    let segments: [F1Performance]
}
nonisolated struct F1Stint: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let compound: String
    let laps: Int?
    let new: Bool?
    var completedLaps: Int? = nil
    let startLap: Int?
}
nonisolated struct F1PitStop: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let driverNumber: String
    let number: Int?
    let lap: Int?
    let duration: String?
    let laneTime: String?
}
nonisolated struct F1DriverTimingState: Codable, Sendable, Equatable, Identifiable {
    var id: String { driver.number }
    let driver: F1Driver
    var position: Int?
    let gap: String?
    let interval: String?
    let lastLap: String?
    let bestLap: String?
    let qualifyingTimes: [String]
    let laps: Int?
    let sectors: [F1Sector]
    let speeds: [String: String]
    let bestSectors: [String]
    let stints: [F1Stint]
    let inPit: Bool
    let pitOut: Bool
    let stops: Int?
    let retired: Bool
    let stopped: Bool
    let knockedOut: Bool
    let overallFastest: Bool
    let personalFastest: Bool
    var classificationStatus: String? = nil
}
nonisolated struct F1RaceControlMessage: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let time: Date?
    let category: String
    let flag: String?
    let scope: String?
    let driverNumber: String?
    let text: String
    let lap: Int?
    var important: Bool { flag == "RED" || category == "SafetyCar" || text.localizedCaseInsensitiveContains("penalty") }
}
nonisolated struct F1TeamRadioMessage: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let driverNumber: String?
    let time: Date?
    let url: URL?
}
nonisolated struct F1WeatherState: Codable, Sendable, Equatable {
    let air: Double?
    let track: Double?
    let humidity: Double?
    let pressure: Double?
    let windDirection: Double?
    let windKPH: Double?
    let raining: Bool?
}
nonisolated struct F1Clock: Codable, Sendable, Equatable {
    let remaining: Double?
    let utc: Date?
    let extrapolating: Bool
    func seconds(at now: Date) -> Int? {
        guard let remaining else { return nil }
        let elapsed = extrapolating ? max(0, now.timeIntervalSince(utc ?? now)) : 0
        return Int(max(0, remaining - elapsed))
    }
}
nonisolated struct F1SessionState: Codable, Sendable, Equatable {
    let identity: String
    var path: String?
    var meeting = "Formula 1"
    var circuit: String?
    var name = "Session"
    var type: F1SessionType = .unknown("")
    var status = "Unknown"
    var phase: Int?
    var currentLap: Int?
    var totalLaps: Int?
    var clock: F1Clock?
    var drivers: [F1DriverTimingState] = []
    var trackStatus = "Track status unavailable"
    var trackCode: String?
    var weather: F1WeatherState?
    var messages: [F1RaceControlMessage] = []
    var radio: [F1TeamRadioMessage] = []
    var pitStops: [F1PitStop] = []
    var availableTopics: Set<String> = []
    var updatedAt = Date.distantPast
    var completed: Bool { ["Finalised", "Ends"].contains(status) }
    var finalised: Bool { status == "Finalised" }
    var active: Bool { status == "Started" || status == "Resumed" }
}
nonisolated struct F1ActiveAeroState: Codable, Sendable, Equatable { let rawValue: Double? }
nonisolated struct F1TelemetrySample: Codable, Sendable, Equatable {
    let time: Date
    let speed: Double?
    let rpm: Double?
    let gear: Int?
    let throttle: Double?
    let brake: Double?
    let activeAero: F1ActiveAeroState
    let unknownChannels: [String: Double]
}
nonisolated struct F1TrackPosition: Codable, Sendable, Equatable {
    let time: Date
    let x: Double
    let y: Double
    let z: Double?
}
nonisolated struct F1HighFrequencyState: Sendable, Equatable {
    var telemetry: [String: F1TelemetrySample] = [:]
    var positions: [String: F1TrackPosition] = [:]
    var trails: [String: [F1TrackPosition]] = [:]
}
/// Fixed-capacity ring; high-frequency samples never grow for the session lifetime.
nonisolated struct F1RingBuffer<Element: Sendable>: Sendable {
    private var storage: [Element] = []
    private var cursor = 0
    let capacity: Int
    mutating func append(_ value: Element) {
        guard capacity > 0 else { return }
        if storage.count < capacity { storage.append(value) }
        else { storage[cursor] = value; cursor = (cursor + 1) % capacity }
    }
    var values: [Element] { storage.count < capacity ? storage : Array(storage[cursor...] + storage[..<cursor]) }
}
