import Foundation

nonisolated enum HockeyPlayDescriptionBuilder {
    static func humanize(_ value: String) -> String {
        let names = ["delaying-game":"Delay of game", "delaying-game-puck-over-glass":"Delay of game — puck over glass",
                     "high-sticking":"High-sticking", "high-sticking-double-minor":"High-sticking (double minor)",
                     "cross-checking":"Cross-checking", "too-many-men-on-the-ice":"Too many players on the ice",
                     "wrist":"Wrist shot", "snap":"Snap shot", "slap":"Slap shot", "tip-in":"Tip-in",
                     "backhand":"Backhand", "wrap-around":"Wrap-around", "O":"Offensive zone", "D":"Defensive zone", "N":"Neutral zone",
                     "wide-right":"Wide right", "wide-left":"Wide left", "above-crossbar":"Above the crossbar"]
        if let name = names[value] { return name }
        let text = value.replacingOccurrences(of: "-", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    static func describe(type: HockeyEventType, primary: String, secondary: String?, tertiary: String?,
                         assists: [String], details: NHLValue, period: HockeyPeriod, strength: String?) -> (String, String?) {
        let shot = details["shotType"].string.map(humanize)
        let zone = details["zoneCode"].string.map(humanize)
        func join(_ values: [String?]) -> String? {
            let text = values.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
            return text.isEmpty ? nil : text
        }
        if period.kind == .shootout, type == .goal || type.isShot {
            return (primary, type == .goal ? "Goal" : type == .shot ? "Saved" : "Missed")
        }
        switch type {
        case .goal:
            return ("\(primary) scores", join([shot, assists.isEmpty ? "Unassisted" : "Assisted by " + assists.formatted(.list(type: .and)), strength]))
        case .shot: return ("\(primary) shot saved" + (secondary.map { " by " + $0 } ?? ""), join([shot, zone]))
        case .missedShot: return ("\(primary) misses the net", join([shot, details["reason"].string.map(humanize), zone]))
        case .blockedShot: return ("\(secondary ?? "Unknown player") blocks \(primary)'s shot", shot)
        case .hit: return ("\(primary) hits \(secondary ?? "Unknown player")", zone)
        case .faceoff: return ("\(primary) wins faceoff vs. \(secondary ?? "Unknown player")", zone)
        case .penalty:
            let name = details["committedByPlayerId"].int == nil ? "Bench" : primary
            return ("\(name) — \(humanize(details["descKey"].string ?? "penalty"))",
                    join([details["duration"].int.map { "\($0) min" }, secondary.map { "Drawn by " + $0 }, tertiary.map { "Served by " + $0 }]))
        case .giveaway: return ("\(primary) giveaway", zone)
        case .takeaway: return ("\(primary) takeaway", zone)
        case .stoppage: return ("Stoppage", details["reason"].string.map(humanize))
        case .periodStart: return ("Start of \(period.label)", nil)
        case .periodEnd: return ("End of \(period.label)", nil)
        case .gameEnd: return ("Final", nil)
        case .shootoutComplete: return ("Shootout complete", nil)
        case .delayedPenalty: return ("Delayed penalty", nil)
        case .failedShot: return ("\(primary) shot attempt unsuccessful", join([shot, zone]))
        case .unknown: return ("Game event", nil)
        }
    }
}
