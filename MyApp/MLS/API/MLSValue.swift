import Foundation

/// Dynamic JSON currency for the MLS Sportec stats API, mirroring EPLValue/MLBValue.
/// Unlike PulseLive, most MLS numeric fields (season, match_day, shirt_number) are
/// genuine JSON numbers, but IDs are always Sportec strings (`MLS-MAT-...`) and a
/// few boolean-shaped fields arrive as the literal strings `"true"`/`"false"`
/// (observed on `starting`/`is_on_field` in match overview player entries) rather
/// than JSON booleans — `.bool` below tolerates that string form too, so mapping
/// code never has to special-case it per field.
nonisolated enum MLSValue: Codable, Sendable, Equatable {
    case object([String: MLSValue]), array([MLSValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: MLSValue].self) { self = .object(v) }
        else { self = .array(try c.decode([MLSValue].self)) }
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
    subscript(_ key: String) -> MLSValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var object: [String: MLSValue] { if case .object(let v) = self { return v }; return [:] }
    var array: [MLSValue] { if case .array(let v) = self { return v }; return [] }
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
    var bool: Bool? {
        switch self {
        case .bool(let v): return v
        case .string(let v) where v == "true": return true
        case .string(let v) where v == "false": return false
        default: return nil
        }
    }
}
