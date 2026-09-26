import Foundation

/// Derives a display clock from `header.status`. Verified live 2026-09-24 only
/// against a finished match, which carries no live minute field at all — the live
/// minute field names below (`liveTime.minute`) are inferred from FotMob's own
/// community-documented shape, not confirmed against a real in-progress match;
/// missing fields fall back to a static label rather than fabricating a minute.
nonisolated enum FotMobClockMapper {
    static func clock(status: SoccerMatchStatus, raw: FotMobValue) -> SoccerMatchClock? {
        let liveTime = raw["liveTime"]
        if let minute = liveTime["minute"].int {
            let added = liveTime["added"].int ?? liveTime["overtime"].int
            let display = (added ?? 0) > 0 ? "\(minute)+\(added ?? 0)'" : "\(minute)'"
            return SoccerMatchClock(minute: minute, addedMinute: added, display: display)
        }
        return staticDisplay(for: status).map { SoccerMatchClock(minute: nil, addedMinute: nil, display: $0) }
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
