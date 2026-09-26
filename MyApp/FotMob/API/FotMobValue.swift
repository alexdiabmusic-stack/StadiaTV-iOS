import Foundation

/// Dynamic JSON currency for FotMob's keyless web JSON routes, mirroring
/// `LaLigaValue`/`EPLValue`. FotMob's payload is not formally documented (reverse-
/// engineered — see LALIGA-INTEGRATION.md) and is known to mix numeric and
/// string-formatted values for the same concept (e.g. stat rows can carry `null`,
/// an `Int`, or a `"287 (81%)"` display string) — mapping code reads defensively
/// off this instead of strict Codable DTOs.
nonisolated enum FotMobValue: Codable, Sendable, Equatable {
    case object([String: FotMobValue]), array([FotMobValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: FotMobValue].self) { self = .object(v) }
        else { self = .array(try c.decode([FotMobValue].self)) }
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
    subscript(_ key: String) -> FotMobValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var object: [String: FotMobValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [FotMobValue] { if case .array(let v) = self { return v }; return [] }
    var string: String? {
        switch self { case .string(let v): return v; case .number(let v): return v == v.rounded() ? String(format: "%.0f", v) : String(v); default: return nil }
    }
    var int: Int? {
        guard let value = double else { return nil }
        return Int(exactly: value.rounded())
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

    /// Some FotMob stat values are display strings with trailing text (`"287
    /// (81%)"`, `"18 (45%)"`) — this pulls the leading numeric prefix rather than
    /// failing outright the way `.double` does for a non-pure-numeric string.
    var leadingNumber: Double? {
        if let value = double { return value }
        guard let raw = string else { return nil }
        let prefix = raw.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(prefix)
    }
}
