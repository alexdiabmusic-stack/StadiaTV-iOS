import Foundation

/// Dynamic JSON currency for the LaLiga official API, mirroring `EPLValue`/`MLSValue`.
/// The schema isn't formally documented (reverse-engineered from laliga.com's own
/// frontend — see LALIGA-INTEGRATION.md), so mapping code reads defensively off this
/// instead of strict Codable DTOs — an unknown/missing field degrades to nil rather
/// than a decode failure. Unlike PulseLive, LaLiga's numeric identifiers are real
/// JSON numbers (verified live 2026-09-24), but `.string` still tolerates either
/// representation so mapping code never has to care which one shows up.
nonisolated enum LaLigaValue: Codable, Sendable, Equatable {
    case object([String: LaLigaValue]), array([LaLigaValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: LaLigaValue].self) { self = .object(v) }
        else { self = .array(try c.decode([LaLigaValue].self)) }
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
    subscript(_ key: String) -> LaLigaValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var object: [String: LaLigaValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [LaLigaValue] { if case .array(let v) = self { return v }; return [] }
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
