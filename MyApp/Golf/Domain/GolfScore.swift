import Foundation

/// Golf scores are provider display strings ("-12", "E", "+3"). This is the
/// single place that interprets them — domain models and mappers keep the
/// raw display string and expose this as a computed value so UI never
/// re-parses score text itself.
nonisolated enum GolfScore: Hashable, Sendable {
    case underPar(Int)
    case even
    case overPar(Int)
    case unknown(String)

    init(raw: String?) {
        guard let raw else { self = .unknown(""); return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-", trimmed != "—" else { self = .unknown(trimmed); return }
        if trimmed.uppercased() == "E" { self = .even; return }
        if let value = Int(trimmed) {
            if value == 0 { self = .even }
            else if value < 0 { self = .underPar(-value) }
            else { self = .overPar(value) }
            return
        }
        self = .unknown(trimmed)
    }

    /// Always includes the sign or "E" — never bare digits, per this app's
    /// golf-scoring display convention (STEP 65: always pair color with text).
    var display: String {
        switch self {
        case .underPar(let value): return "-\(value)"
        case .even: return "E"
        case .overPar(let value): return "+\(value)"
        case .unknown(let raw): return raw
        }
    }

    /// Ascending sort key: more-under-par sorts first. Non-numeric values
    /// (blank, "-") sort last; player *state* (WD/CUT/DQ) governs their
    /// placement, not this value — see `GolfPlayerState`.
    var sortValue: Int {
        switch self {
        case .underPar(let value): return -value
        case .even: return 0
        case .overPar(let value): return value
        case .unknown: return Int.max
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .underPar(let value): return "\(value) under par"
        case .even: return "even par"
        case .overPar(let value): return "\(value) over par"
        case .unknown(let raw): return raw.isEmpty ? "no score" : raw
        }
    }
}
