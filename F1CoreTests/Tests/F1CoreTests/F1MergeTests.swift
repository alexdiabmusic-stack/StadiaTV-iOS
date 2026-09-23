import Foundation
import Testing
@testable import F1Core

func value(_ json: String) throws -> F1Value { try JSONDecoder().decode(F1Value.self, from: Data(json.utf8)) }
@Suite("F1 protocol and merge") struct F1MergeTests {
    @Test func partialNestedDelta() throws {
        let old = try value(#"{"Lines":{"4":{"Position":"2","Gap":"+1.2","Tyre":"MEDIUM","Sectors":[{"Value":"25.1","Segments":[{"Status":2048},{"Status":2049}]}],"Speeds":{"ST":{"Value":"310"}},"Stints":[{"Compound":"MEDIUM","TotalLaps":14}]}}}"#)
        let patch = try value(#"{"Lines":{"4":{"Gap":"+0.8","Sectors":{"0":{"Segments":{"1":{"Status":2051}}}},"Stints":{"0":{"TotalLaps":15}}}}}"#)
        let merged = F1DeltaMerger.merge(old, patch)["Lines"]["4"]
        #expect(merged["Position"].string == "2"); #expect(merged["Gap"].string == "+0.8"); #expect(merged["Tyre"].string == "MEDIUM")
        #expect(merged["Sectors"].array[0]["Value"].string == "25.1")
        #expect(merged["Sectors"].array[0]["Segments"].array.map { $0["Status"].int } == [2048,2051])
        #expect(merged["Stints"].array[0]["Compound"].string == "MEDIUM"); #expect(merged["Stints"].array[0]["TotalLaps"].int == 15)
        #expect(merged["Speeds"]["ST"]["Value"].string == "310")
    }
    @Test func replacementNullDeletionAndSparseIndices() throws {
        #expect(F1DeltaMerger.merge(try value(#"{"x":1}"#), try value(#"{"x":null}"#))["x"] == .null)
        #expect(F1DeltaMerger.merge(try value(#"[{"Value":"a"}]"#), try value(#"{"3":{"Value":"b"}}"#)).array.count == 4)
        #expect(F1DeltaMerger.merge(try value(#"{"4":{"Position":"1"}}"#), try value(#"{"4":{"_deleted":true}}"#)).object.isEmpty)
    }
    @Test func fragmentedAndCombinedFrames() throws {
        var parser = F1SignalRProtocol()
        #expect(try parser.receive(Data("{".utf8)).isEmpty)
        let events = try parser.receive(Data("}\u{1e}{\"type\":1,\"target\":\"feed\",\"arguments\":[\"TimingData\",{\"Lines\":{}},\"2026-01-01T00:00:00Z\"]}\u{1e}".utf8))
        #expect(events.count == 2)
        let subscription = try F1SignalRProtocol.subscription()
        #expect(subscription.contains("Subscribe")); #expect(subscription.contains("CarData.z"))
    }
    @Test func boundedReconnect() { #expect((1...6).map(F1SignalRClient.backoff) == [2,4,8,16,30,30]) }
    @Test func corruptCompressionDoesNotDecode() {
        #expect(throws: (any Error).self) { try F1CompressedPayloadDecoder.decode("not base64") }
    }
}
