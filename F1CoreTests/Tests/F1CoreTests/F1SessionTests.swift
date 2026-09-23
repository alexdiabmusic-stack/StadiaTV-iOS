import Foundation
import Testing
@testable import F1Core

func fixture(_ name: String) throws -> F1Value {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/" + name + ".json")
    return try JSONDecoder().decode(F1Value.self, from: Data(contentsOf: url))
}
@Suite("Recorded F1 session") struct F1SessionTests {
    @Test(arguments: ["CarData", "Position"]) func recordedRawDeflate(_ topic: String) throws {
        let encoded = try #require(fixture(topic + ".z").string)
        let raw = try F1CompressedPayloadDecoder.decode(encoded)
        #expect(!raw[topic == "CarData" ? "Entries" : "Position"].array.isEmpty)
    }
    @Test func officialResultsPreserveArchiveDetails() throws {
        let session = F1ScheduledSession(id: "2025.1.Race", meeting: "Australian Grand Prix", circuit: "Albert Park", name: "Race", start: .distantPast, season: 2025, round: 1)
        let result = try #require(F1ResultsService.normalize(fixture("JolpicaResults"), session: session))
        #expect(result.finalised); #expect(result.drivers.count == 20)
        #expect(result.drivers.first?.driver.tla == "NOR")
        let archive = F1TimingMapper.normalize(["DriverList": try fixture("DriverList"), "TimingData": try fixture("TimingData"), "TimingAppData": try fixture("TimingAppData")], identity: session.id, time: .now)
        let merged = F1ResultsService.merge(result, into: archive)
        #expect(merged.finalised)
        #expect(merged.drivers.first?.position == 1)
        #expect(merged.drivers.first?.stints.isEmpty == false)
        let other = F1ScheduledSession(id: "2026.1.Race", meeting: "Other", circuit: "Other", name: "Race", start: .distantPast, season: 2026, round: 1)
        #expect(try F1ResultsService.normalize(fixture("JolpicaResults"), session: other) == nil)
    }
    @Test func movingTelemetryAndPositions() async throws {
        let store = F1TopicStateStore(identity: "2025.1.Race")
        await store.apply(F1TopicUpdate(topic: "CarData.z", payload: try fixture("CarData.moving.z"), timestamp: .now))
        await store.apply(F1TopicUpdate(topic: "Position.z", payload: try fixture("Position.moving.z"), timestamp: .now))
        let fast = await store.fastState()
        #expect((fast.telemetry["1"]?.speed ?? 0) > 100)
        #expect((fast.telemetry["1"]?.rpm ?? 0) > 10000)
        #expect(fast.telemetry["6"]?.throttle == nil)
        #expect(fast.telemetry["6"]?.brake == nil)
        #expect(fast.positions["1"]?.x != 0)
        #expect(fast.positions["1"]?.y != 0)
        #expect(!(fast.trails["1"] ?? []).isEmpty)
        #expect(!(await store.samples(driver: "1")).isEmpty)
    }
    @Test func archivedSessionNormalizes() async throws {
        let store = F1TopicStateStore(identity: "2025.1.Race")
        for topic in ["DriverList", "SessionInfo", "TimingData", "TimingStats", "TimingAppData", "SessionData", "TrackStatus", "WeatherData", "RaceControlMessages", "TeamRadio", "LapCount", "ExtrapolatedClock"] {
            await store.apply(F1TopicUpdate(topic: topic, payload: try fixture(topic), timestamp: Date()))
        }
        let state = await store.normalized()
        #expect(state.drivers.count == 20)
        #expect(state.type == .race)
        #expect(state.drivers.contains { !$0.stints.isEmpty })
        #expect(!state.messages.isEmpty)
        #expect(state.messages.allSatisfy { $0.time != nil })
        #expect(state.radio.contains { $0.url?.host == "livetiming.formula1.com" })
        #expect(state.weather?.track != nil)
    }
    @Test(arguments: [("Practice 1", F1SessionType.practice), ("Qualifying", .qualifying), ("Sprint Qualifying", .sprintQualifying), ("Sprint", .sprint), ("Race", .race), ("Future", .unknown("Future"))])
    func sessionTypes(_ pair: (String, F1SessionType)) { #expect(F1SessionType(pair.0) == pair.1) }
    @Test(arguments: [("1", "Green flag"), ("2", "Yellow flag"), ("4", "Safety Car"), ("5", "Red flag"), ("6", "Virtual Safety Car"), ("7", "VSC ending"), ("future", "Track status unavailable")])
    func trackFlags(_ pair: (String, String)) { #expect(F1TrackStatusMapper.label(pair.0) == pair.1) }
    @Test func twentyTwoDriversAndUnknownChannels() async throws {
        let store = F1TopicStateStore(identity: "test")
        let drivers = Dictionary(uniqueKeysWithValues: (1...22).map { (String($0), F1Value.object(["RacingNumber": .string(String($0)), "FullName": .string("Fixture driver")])) })
        await store.apply(F1TopicUpdate(topic: "DriverList", payload: .object(drivers), timestamp: .now))
        await store.apply(F1TopicUpdate(topic: "CarData", payload: try value(#"{"Entries":[{"Cars":{"1":{"Channels":{"2":312,"45":999,"123":7}}}}]}"#), timestamp: .now))
        let state = await store.normalized(), fast = await store.fastState()
        #expect(state.drivers.count == 22); #expect(state.drivers.allSatisfy { $0.driver.headshot == nil })
        #expect(fast.telemetry["1"]?.activeAero.rawValue == 999)
        #expect(fast.telemetry["1"]?.unknownChannels["123"] == 7)
        #expect(fast.positions.isEmpty)
    }
    @Test func staleUpdateAndCorruptionPreserveState() async throws {
        let store = F1TopicStateStore(identity: "test"), now = Date()
        await store.apply(F1TopicUpdate(topic: "TrackStatus", payload: try value(#"{"Status":"4"}"#), timestamp: now))
        #expect(await store.apply(F1TopicUpdate(topic: "TrackStatus", payload: try value(#"{"Status":"1"}"#), timestamp: now.addingTimeInterval(-1))) == false)
        #expect(await store.apply(F1TopicUpdate(topic: "CarData.z", payload: .string("invalid"), timestamp: now)) == false)
        #expect(await store.normalized().trackStatus == "Safety Car")
        await store.apply(F1TopicUpdate(topic: "FutureTopic", payload: .object([:]), timestamp: now))
        #expect(await store.normalized().availableTopics.contains("FutureTopic"))
    }
    @Test func finalClassificationFrozen() async throws {
        let store = F1TopicStateStore(identity: "test")
        await store.apply(F1TopicUpdate(topic: "DriverList", payload: try value(#"{"4":{"RacingNumber":"4"}}"#), timestamp: .now))
        await store.apply(F1TopicUpdate(topic: "TimingData", payload: try value(#"{"Lines":{"4":{"Position":"1"}}}"#), timestamp: .now))
        await store.apply(F1TopicUpdate(topic: "SessionStatus", payload: try value(#"{"Status":"Finalised"}"#), timestamp: .now))
        #expect(await store.normalized().drivers.first?.position == 1)
        await store.apply(F1TopicUpdate(topic: "TimingData", payload: try value(#"{"Lines":{"4":{"Position":"2"}}}"#), timestamp: .now))
        #expect(await store.normalized().drivers.first?.position == 1)
        await store.reset()
        #expect(await store.normalized().drivers.isEmpty)
    }
    @Test func boundedMemoryAndClock() {
        var ring = F1RingBuffer<Int>(capacity: 150)
        for value in 0..<10000 { ring.append(value) }
        #expect(ring.values.count == 150); #expect(ring.values.first == 9850); #expect(ring.values.last == 9999)
        let now = Date()
        #expect(F1Clock(remaining: 120, utc: now, extrapolating: true).seconds(at: now.addingTimeInterval(12)) == 108)
        #expect(F1Clock(remaining: 120, utc: now, extrapolating: false).seconds(at: now.addingTimeInterval(12)) == 120)
    }
    @Test func qualifyingPhaseAndNestedPitStop() throws {
        let topics = ["SessionInfo": try value(#"{"Name":"Qualifying"}"#), "DriverList": try value(#"{"4":{"RacingNumber":"4"}}"#), "TimingData": try value(#"{"SessionPart":3,"Lines":{"4":{"BestLapTimes":[{"Value":"1:22"},{"Value":"1:21"},{"Value":"1:20"}],"KnockedOut":true}}}"#), "PitStopSeries": try value(#"{"PitTimes":{"4":[{"PitStop":{"Lap":"20","PitStopTime":"2.4"}}]}}"#)]
        let state = F1TimingMapper.normalize(topics, identity: "test", time: .now)
        #expect(state.phase == 3); #expect(state.drivers.first?.bestLap == "1:20")
        #expect(state.drivers.first?.knockedOut == true)
        #expect(state.pitStops.first?.duration == "2.4"); #expect(state.pitStops.first?.lap == 20)
    }
}
