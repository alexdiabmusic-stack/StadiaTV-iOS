import Foundation

nonisolated struct F1TopicUpdate: Codable, Sendable, Equatable {
    let topic: String
    let payload: F1Value
    let timestamp: Date
    var snapshot = false
}
nonisolated enum F1HubEvent: Sendable {
    case handshake, subscribed([F1TopicUpdate]), update(F1TopicUpdate), ping, closed(String)
}
/// SignalR Core JSON hub framing. A WebSocket message may contain several hub
/// records, or only part of a record; never discard its unconsumed suffix.
nonisolated struct F1SignalRProtocol: Sendable {
    private var buffer = Data()
    private var handshaken = false
    static let separator: UInt8 = 0x1e
    static var handshake: String { "{\"protocol\":\"json\",\"version\":1}\u{1e}" }
    static func subscription(topics: [String] = F1LiveTimingEndpoint.topics) throws -> String {
        let value: F1Value = .object(["type": .number(1), "invocationId": .string("0"), "target": .string("Subscribe"), "arguments": .array([.array(topics.map(F1Value.string))])])
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self) + "\u{1e}"
    }
    mutating func receive(_ data: Data, now: Date = Date()) throws -> [F1HubEvent] {
        buffer.append(data)
        guard buffer.count <= 16 * 1024 * 1024 else { throw F1LiveTimingError.oversizedPayload }
        var output: [F1HubEvent] = []
        while let end = buffer.firstIndex(of: Self.separator) {
            let record = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard !record.isEmpty else { continue }
            let frame = try JSONDecoder().decode(F1Value.self, from: record)
            if !handshaken {
                if let error = frame["error"].string { throw F1LiveTimingError.protocolFailure(error) }
                guard frame.object.isEmpty else { throw F1LiveTimingError.protocolFailure("Invalid handshake") }
                handshaken = true; output.append(.handshake); continue
            }
            switch frame["type"].int {
            case 1 where frame["target"].string?.lowercased() == "feed":
                let arguments = frame["arguments"].array
                guard arguments.count >= 2, let topic = arguments[0].string else { continue }
                output.append(.update(F1TopicUpdate(topic: topic, payload: arguments[1], timestamp: arguments.count > 2 ? F1Date.utc(arguments[2].string) ?? now : now)))
            case 3 where frame["invocationId"].string == "0":
                if let error = frame["error"].string { throw F1LiveTimingError.protocolFailure(error) }
                output.append(.subscribed(frame["result"].object.map { F1TopicUpdate(topic: $0.key, payload: $0.value, timestamp: now, snapshot: true) }))
            case 6: output.append(.ping)
            case 7: output.append(.closed(frame["error"].string ?? "Connection closed"))
            default: break
            }
        }
        return output
    }
}
