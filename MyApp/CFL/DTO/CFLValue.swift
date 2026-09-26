import Foundation

/// Dynamic JSON boundary for `echo.pims.cfl.ca`/`api.stats.cfl.ca` — a genuinely separate
/// type from `NFLValue`/`WNBAValue` since CFL's schema (verified live this session against
/// both real hosts) shares no vocabulary with either.
nonisolated enum CFLValue: Codable, Sendable, Equatable {
    case object([String: CFLValue]), array([CFLValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: CFLValue].self) { self = .object(v) }
        else { self = .array(try c.decode([CFLValue].self)) }
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
    subscript(_ key: String) -> CFLValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var object: [String: CFLValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [CFLValue] { if case .array(let v) = self { return v }; return [] }
    var string: String? {
        switch self { case .string(let v): return v; case .number(let v): return v == v.rounded() ? String(format: "%.0f", v) : String(v); default: return nil }
    }
    var int: Int? { guard let value = double else { return nil }; return Int(exactly: value.rounded()) }
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
    var bool: Bool? {
        switch self {
        case .bool(let v): return v
        case .string(let v): return ["1", "true"].contains(v.lowercased()) ? true : ["0", "false"].contains(v.lowercased()) ? false : nil
        case .number(let v): return v == 1 ? true : v == 0 ? false : nil
        default: return nil
        }
    }
}
