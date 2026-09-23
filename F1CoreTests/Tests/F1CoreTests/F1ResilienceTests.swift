import Foundation
import Testing
@testable import F1Core

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let code = Int(url.lastPathComponent) ?? 200
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "120"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"value\":42}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Suite("F1 resilience") struct F1ResilienceTests {
    @Test(arguments: [404, 429, 503]) func typedHTTPFailure(_ code: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let client = F1HTTPClient(session: URLSession(configuration: configuration))
        let url = try #require(URL(string: "https://fixture.invalid/\(code)"))
        do { _ = try await client.json(url); Issue.record("Expected HTTP failure") }
        catch F1LiveTimingError.http(let returned) { #expect(returned == code) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
    @Test func safeDurationAndRetryAfter() {
        #expect(F1Date.duration("NaN") == nil)
        #expect(F1Date.duration("1e300") == nil)
        #expect(F1Date.duration("00:04:18") == 258)
        #expect(F1RetryPolicy.delay("120") == 120)
        #expect(F1RetryPolicy.delay("invalid") == 60)
        #expect(F1RetryPolicy.delay("Tue, 22 Sep 2026 12:02:00 GMT", now: F1Date.parse("2026-09-22T12:00:00Z") ?? .distantPast) == 120)
    }
    @Test func usedTyresAndAmbiguousRestart() throws {
        let stints = F1StrategyMapper.stints(try value(#"[{"Compound":"HARD","TotalLaps":12,"StartLaps":2,"New":"false"},{"Compound":"SOFT","TotalLaps":5,"StartLaps":0}]"#))
        #expect(stints[0].laps == 12); #expect(stints[0].completedLaps == 10); #expect(stints[1].startLap == 11)
        let restarted = F1StrategyMapper.stints(try value(#"[{"TotalLaps":4,"StartLaps":3,"TyresNotChanged":"1"}]"#))
        #expect(restarted.first?.startLap == nil)
        #expect(restarted.first?.completedLaps == 1)
    }
    @Test(arguments: [1,2,3]) func qualifyingPhaseDoesNotUseEarlierTime(_ phase: Int) throws {
        let topics: [String:F1Value] = ["SessionInfo": try value(#"{"Name":"Qualifying"}"#), "DriverList": try value(#"{"4":{"RacingNumber":"4"}}"#), "TimingData": .object(["SessionPart": .number(Double(phase)), "Lines": try value(#"{"4":{"BestLapTimes":[{"Value":"1:22.000"}],"BestLapTime":{"Value":"1:22.000"}}}"#)])]
        let state = F1TimingMapper.normalize(topics, identity: "qualifying", time: .now)
        #expect(state.drivers.first?.bestLap == (phase == 1 ? "1:22.000" : nil))
    }
    @Test(arguments: [0,1,99]) func weatherSensorMeaning(_ rainfall: Int) throws {
        let state = F1TimingMapper.normalize(["WeatherData": .object(["Rainfall": .string(String(rainfall)), "WindSpeed": .string("10")])], identity: "weather", time: .now)
        #expect(state.weather?.raining == (rainfall == 0 ? false : rainfall == 1 ? true : nil))
        #expect(state.weather?.windKPH == 36)
    }
    @Test func driverFlagsAndOfficialPenalty() throws {
        let topics: [String:F1Value] = ["DriverList": try value(#"{"4":{"RacingNumber":"4"}}"#), "TimingData": try value(#"{"Lines":{"4":{"Retired":true,"Stopped":true,"InPit":true,"LastLapTime":{"OverallFastest":true,"PersonalFastest":true},"IntervalToPositionAhead":{"Value":""}}}}"#), "RaceControlMessages": try value(#"{"Messages":[{"Category":"Other","RacingNumber":"4","Message":"CAR 4 - 5 SECOND TIME PENALTY"}]}"#)]
        let state = F1TimingMapper.normalize(topics, identity: "flags", time: .now)
        #expect(state.drivers.first?.retired == true); #expect(state.drivers.first?.stopped == true)
        #expect(state.drivers.first?.inPit == true); #expect(state.drivers.first?.overallFastest == true)
        #expect(state.drivers.first?.interval == nil); #expect(state.messages.first?.important == true)
    }
}
