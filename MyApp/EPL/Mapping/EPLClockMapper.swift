import Foundation

/// SDP's `clock` field is a bare total elapsed minute (`"95"`, `"97"`, observed on
/// completed matches) — never a pre-formatted `"90+5"` string. Proper football
/// stoppage-time display (`45+3'`, `90+7'`) must be derived from that total plus the
/// match period/status, never displayed as a raw minute count past regulation.
nonisolated enum EPLClockMapper {
    static func clock(status: SoccerMatchStatus, rawClock: String?) -> SoccerMatchClock? {
        guard let rawClock, let total = Int(rawClock) else {
            return staticDisplay(for: status).map { SoccerMatchClock(minute: nil, addedMinute: nil, display: $0) }
        }
        switch status {
        case .firstHalf:
            return total > 45
                ? SoccerMatchClock(minute: 45, addedMinute: total - 45, display: "45+\(total - 45)'")
                : SoccerMatchClock(minute: total, addedMinute: nil, display: "\(total)'")
        case .secondHalf, .stoppageTime:
            return total > 90
                ? SoccerMatchClock(minute: 90, addedMinute: total - 90, display: "90+\(total - 90)'")
                : SoccerMatchClock(minute: total, addedMinute: nil, display: "\(total)'")
        case .halftime: return SoccerMatchClock(minute: 45, addedMinute: nil, display: "HT")
        case .fullTime: return SoccerMatchClock(minute: total, addedMinute: nil, display: "FT")
        case .delayed, .suspended, .postponed, .cancelled, .abandoned, .scheduled, .pregame:
            return staticDisplay(for: status).map { SoccerMatchClock(minute: nil, addedMinute: nil, display: $0) }
        // Extra time/penalties: not observed on EPL league play (no PulseLive league
        // match reaches these), kept only so this switch stays exhaustive against the
        // shared `SoccerMatchStatus` enum that MLS's cup/playoff matches do use.
        case .extraFirstHalf, .extraSecondHalf:
            return total > 105
                ? SoccerMatchClock(minute: 105, addedMinute: total - 105, display: "105+\(total - 105)'")
                : SoccerMatchClock(minute: total, addedMinute: nil, display: "\(total)'")
        case .extraHalftime: return SoccerMatchClock(minute: 105, addedMinute: nil, display: "HT (ET)")
        case .penalties: return SoccerMatchClock(minute: nil, addedMinute: nil, display: "PEN")
        case .unknown:
            // Unrecognized status but a clock value exists — show the raw minute
            // rather than guessing at added-time math for an unverified state.
            return SoccerMatchClock(minute: total, addedMinute: nil, display: "\(total)'")
        }
    }

    private static func staticDisplay(for status: SoccerMatchStatus) -> String? {
        switch status {
        case .halftime: return "HT"
        case .fullTime: return "FT"
        case .postponed: return "PPD"
        case .suspended: return "Suspended"
        case .abandoned: return "Abandoned"
        case .delayed: return "Delayed"
        case .cancelled: return "Cancelled"
        default: return nil
        }
    }
}
