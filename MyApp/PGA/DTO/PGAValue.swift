import Foundation

/// Tolerant JSON AST for PGA TOUR responses. Subscripting a missing key or
/// wrong-shape value never throws — it degrades to `.null`/`nil` — because
/// the upstream API is an undocumented consumer surface that adds, removes,
/// and renames fields without notice. PGA DTOs and mappers work through this
/// type; raw JSON never reaches a mapper or a SwiftUI view directly.
nonisolated enum PGAValue: Codable, Sendable, Equatable {
    case object([String: PGAValue])
    case array([PGAValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: PGAValue].self) { self = .object(value) }
        else { self = .array(try container.decode([PGAValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> PGAValue {
        if case .object(let value) = self { return value[key] ?? .null }
        return .null
    }

    subscript(_ index: Int) -> PGAValue {
        if case .array(let value) = self, value.indices.contains(index) { return value[index] }
        return .null
    }

    var object: [String: PGAValue] { if case .object(let value) = self { return value }; return [:] }
    var array: [PGAValue] { if case .array(let value) = self { return value }; return [] }
    var isNull: Bool { if case .null = self { return true }; return false }

    var string: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(format: "%.0f", value) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
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

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value): return ["true", "1"].contains(value.lowercased()) ? true : ["false", "0"].contains(value.lowercased()) ? false : nil
        case .number(let value): return value == 1 ? true : value == 0 ? false : nil
        default: return nil
        }
    }
}
