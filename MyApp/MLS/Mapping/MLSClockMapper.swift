import Foundation

/// MLS's `minute_of_play` (schedule and match overview) is already stoppage-formatted
/// by the provider (`"90+7"`, `"45+2"`, `"12"`) — unlike PulseLive's bare total
/// minute, this is parsed for its structured `minute`/`addedMinute` fields only,
/// never recomputed or reformatted from wall-clock time. (Commentary entries use a
/// differently-punctuated `"90'+6"` form for their own free-text minute label —
/// that field is preserved verbatim on `SoccerCommentaryEntry.minuteDisplay` and
/// never parsed here.)
nonisolated enum MLSClockMapper {
    static func clock(status: SoccerMatchStatus, minuteOfPlay raw: String?) -> SoccerMatchClock? {
        let staticText = staticDisplay(for: status)
        guard let raw, !raw.isEmpty, let base = MLSDate.baseMinute(raw) else {
            return staticText.map { SoccerMatchClock(minute: nil, addedMinute: nil, display: $0) }
        }
        let parts = raw.split(separator: "+", maxSplits: 1)
        let added = parts.count > 1 ? Int(parts[1]) : nil
        if let staticText { return SoccerMatchClock(minute: base, addedMinute: added, display: staticText) }
        return SoccerMatchClock(minute: base, addedMinute: added, display: added.map { "\(base)+\($0)'" } ?? "\(base)'")
    }

    private static func staticDisplay(for status: SoccerMatchStatus) -> String? {
        switch status {
        case .halftime: return "HT"
        case .extraHalftime: return "HT (ET)"
        case .fullTime: return "FT"
        case .postponed: return "PPD"
        case .suspended: return "Suspended"
        case .abandoned: return "Abandoned"
        case .delayed: return "Delayed"
        case .cancelled: return "Cancelled"
        case .penalties: return "PEN"
        default: return nil
        }
    }
}
