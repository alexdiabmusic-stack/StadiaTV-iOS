import Foundation

/// Maps the official API's raw `status` string. Only `"PreMatch"` and `"FullTime"`
/// have been directly observed live (probed 2026-09-24 — no La Liga match was in
/// progress at probe time; see LALIGA-INTEGRATION.md) — the live vocabulary below is
/// inferred from PulseLive's own equivalent PascalCase convention (EPL's API shares
/// the same "PreMatch"/"FullTime" tokens), not confirmed against a real in-progress
/// La Liga match. Never compares against Spanish display strings (Step 39) — only
/// this raw API token. Unrecognized values become `.unknown(raw)`, never dropped.
nonisolated enum LaLigaStatusMapper {
    static func status(_ raw: String?) -> SoccerMatchStatus {
        let value = raw ?? ""
        switch value {
        case "PreMatch": return .scheduled
        case "FirstHalf": return .firstHalf
        case "HalfTime": return .halftime
        case "SecondHalf": return .secondHalf
        case "FullTime": return .fullTime
        case "Postponed": return .postponed
        case "Suspended": return .suspended
        case "Cancelled", "Canceled": return .cancelled
        case "Abandoned": return .abandoned
        case "Delayed": return .delayed
        default: break
        }
        let lower = value.lowercased()
        if lower.contains("postpon") { return .postponed }
        if lower.contains("suspend") { return .suspended }
        if lower.contains("abandon") { return .abandoned }
        if lower.contains("delay") { return .delayed }
        if lower.contains("cancel") { return .cancelled }
        return value.isEmpty ? .scheduled : .unknown(value)
    }
}
