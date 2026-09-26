import Foundation

/// Maps SDP's raw `period` string to canonical `SoccerMatchStatus`. Only `"PreMatch"`
/// and `"FullTime"` have been directly observed live (probed 2026-09-23, no match was
/// in progress) — the live vocabulary below (`FirstHalf`/`HalfTime`/`SecondHalf`/etc.)
/// is inferred from the symmetric event-period field (`/v1/matches/{id}/events` uses
/// `"FirstHalf"`/`"SecondHalf"`) and from PulseLive's own site terminology. Substring
/// matching keeps this resilient if the exact casing/wording differs from the guess;
/// anything unrecognized becomes `.unknown(raw)` rather than crashing or guessing wrong.
nonisolated enum EPLStatusMapper {
    static func status(period: String?) -> SoccerMatchStatus {
        let raw = period ?? ""
        let lower = raw.lowercased()
        switch lower {
        case "prematch": return .scheduled
        case "firsthalf": return .firstHalf
        case "halftime", "half time": return .halftime
        case "secondhalf": return .secondHalf
        case "fulltime", "postmatch": return .fullTime
        default: break
        }
        if lower.contains("postpon") { return .postponed }
        if lower.contains("suspend") { return .suspended }
        if lower.contains("abandon") { return .abandoned }
        if lower.contains("delay") { return .delayed }
        if lower.contains("cancel") { return .cancelled }
        if lower.contains("extra") || lower.contains("penalt") { return .unknown(raw) } // Step 83: shootout/extra time surfaced separately, not as a match status
        return raw.isEmpty ? .scheduled : .unknown(raw)
    }
}
