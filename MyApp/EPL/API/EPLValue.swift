import Foundation

/// Dynamic JSON currency for the undocumented PulseLive/SDP API, mirroring
/// MLBValue/NBAValue. The schema is unstable and unversioned, so mapping code reads
/// defensively off this instead of strict Codable DTOs — an unknown/missing field
/// degrades to nil rather than a decode failure. Note PulseLive returns most numeric
/// identifiers (matchId, team id, playerId) as JSON strings, not numbers — `.string`
/// (below) accepts either representation so mapping code doesn't need to care.
nonisolated enum EPLValue: Codable, Sendable, Equatable {
    case object([String: EPLValue]), array([EPLValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: EPLValue].self) { self = .object(v) }
        else { self = .array(try c.decode([EPLValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> EPLValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var object: [String: EPLValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [EPLValue] { if case .array(let v) = self { return v }; return [] }
    var string: String? {
        switch self { case .string(let v): return v; case .number(let v): return v == v.rounded() ? String(format: "%.0f", v) : String(v); default: return nil }
    }
    var int: Int? {
        guard let value = double else { return nil }
        return Int(exactly: value)
    }
    var double: Double? {
        let value: Double?
        switch self {
        case .number(let number): value = number
        case .string(let string): value = Double(string)
        default: value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
}
