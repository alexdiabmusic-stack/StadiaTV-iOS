import Foundation

/// Maps `header.status` into canonical `SoccerMatchStatus`. Verified live
/// 2026-09-24 only against a finished match (`finished: true`, `reason.shortKey:
/// "fulltime_short"`) — the live vocabulary below (half/halftime reason keys) is
/// inferred from FotMob's own naming convention, not confirmed against a real
/// in-progress match. Never compares reason display text (`reason.long`), only
/// the stable `shortKey`/`longKey` tokens (Step 39).
nonisolated enum FotMobStatusMapper {
    static func status(_ raw: FotMobValue) -> SoccerMatchStatus {
        if raw["cancelled"].bool == true { return .cancelled }
        if raw["awarded"].bool == true { return .fullTime }
        if raw["finished"].bool == true { return .fullTime }
        if raw["started"].bool != true { return .scheduled }
        let key = (raw["reason"]["shortKey"].string ?? raw["reason"]["longKey"].string ?? "").lowercased()
        switch key {
        case "halftime_short", "halftime": return .halftime
        case "1st_half", "firsthalf": return .firstHalf
        case "2nd_half", "secondhalf": return .secondHalf
        case "fulltime_short", "finished": return .fullTime
        default: break
        }
        if key.contains("postpon") { return .postponed }
        if key.contains("suspend") { return .suspended }
        if key.contains("abandon") { return .abandoned }
        if key.contains("delay") { return .delayed }
        if key.contains("cancel") { return .cancelled }
        if key.contains("half") { return key.contains("time") ? .halftime : .secondHalf }
        // Started but no recognized reason key — safest inferred default while live.
        return key.isEmpty ? .firstHalf : .unknown(key)
    }
}
