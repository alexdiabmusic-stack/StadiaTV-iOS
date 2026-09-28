import Foundation

/// A golfer's tournament state, kept strictly separate from their scoring
/// value. CUT/WD/DQ/MDF are states, never numbers — leaderboard sorting must
/// consult this (and the provider's own sort fields) instead of coercing
/// these labels into a score.
nonisolated enum GolfPlayerState: Sendable, Hashable {
    case active
    case notStarted
    case finished
    case cut
    case missedCut
    case withdrawn
    case disqualified
    case didNotFinish
    case unknown(String)

    /// `positionDisplay` is checked first because the provider commonly
    /// encodes CUT/WD/DQ/MDF there (e.g. `position: "CUT"`) rather than in a
    /// dedicated state field; `playerStateRaw` is the fallback/primary signal
    /// otherwise (e.g. "COMPLETE", "ACTIVE").
    init(playerStateRaw: String?, positionDisplay: String?) {
        let positionUpper = positionDisplay?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        switch positionUpper {
        case "CUT": self = .cut; return
        case "MDF": self = .missedCut; return
        case "WD": self = .withdrawn; return
        case "DQ": self = .disqualified; return
        case "DNF": self = .didNotFinish; return
        default: break
        }
        guard let raw = playerStateRaw, !raw.isEmpty else { self = .unknown(""); return }
        switch raw.uppercased() {
        case "ACTIVE", "IN_PROGRESS", "PLAYING": self = .active
        case "NOT_STARTED", "NOTSTARTED", "SCHEDULED": self = .notStarted
        case "COMPLETE", "COMPLETED", "FINISHED", "F": self = .finished
        case "CUT": self = .cut
        case "MDF": self = .missedCut
        case "WD", "WITHDRAWN": self = .withdrawn
        case "DQ", "DISQUALIFIED": self = .disqualified
        case "DNF": self = .didNotFinish
        default: self = .unknown(raw)
        }
    }

    /// Whether this player's row represents an active/finished score
    /// competing on the board, as opposed to a fixed non-scoring state.
    var isScoring: Bool {
        switch self {
        case .active, .finished: return true
        case .notStarted, .cut, .missedCut, .withdrawn, .disqualified, .didNotFinish, .unknown: return false
        }
    }

    var isOnCourse: Bool { self == .active }

    var shortLabel: String? {
        switch self {
        case .cut: return "CUT"
        case .missedCut: return "MDF"
        case .withdrawn: return "WD"
        case .disqualified: return "DQ"
        case .didNotFinish: return "DNF"
        default: return nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .active: return "on course"
        case .notStarted: return "not started"
        case .finished: return "finished"
        case .cut: return "missed the cut"
        case .missedCut: return "did not make the cut after 54 holes"
        case .withdrawn: return "withdrawn"
        case .disqualified: return "disqualified"
        case .didNotFinish: return "did not finish"
        case .unknown(let raw): return raw
        }
    }
}
