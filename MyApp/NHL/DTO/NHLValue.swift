import Foundation

/// Variable NHL scalar fields stay at the transport boundary, never in views.
nonisolated enum NHLValue: Codable, Sendable, Equatable {
    case object([String: NHLValue]), array([NHLValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: NHLValue].self) { self = .object(v) }
        else { self = .array(try c.decode([NHLValue].self)) }
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
    subscript(_ key: String) -> NHLValue { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var array: [NHLValue] { if case .array(let v) = self { return v }; return [] }
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
    var localized: String? { self["default"].string ?? self["en"].string ?? string }
}
nonisolated struct NHLLocalizedName: Codable, Sendable, Equatable {
    let translations: [String: String]
    var value: String { translations["default"] ?? translations["en"] ?? "" }
    init(_ value: NHLValue) {
        if case .object(let object) = value { translations = object.compactMapValues(\.string) }
        else { translations = ["default": value.string ?? ""] }
    }
}
