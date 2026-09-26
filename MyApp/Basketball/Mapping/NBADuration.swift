import Foundation

/// The one place that parses NBA/WNBA's shared ISO-8601-duration-like clock/minutes
/// strings (e.g. "PT11M32.00S", "PT00M00.00S", "PT25M"). Nothing else in the app
/// should see a raw "PT…S" string — this is also used to generate the basketball
/// period label ("Q1"…"Q4", "OT", "2OT", …) with no hardcoded overtime cap. Kept
/// under its original NBA-derived name (per Step 5 of the WNBA integration: "reuse
/// the same duration parser as NBA") even though it's genuinely shared, sport-
/// generic math with nothing NBA-specific inside it.
nonisolated enum NBADuration {
    static func seconds(_ iso: String?) -> TimeInterval? {
        guard let iso, iso.hasPrefix("PT"), iso.count > 2 else { return nil }
        var remainder = iso[iso.index(iso.startIndex, offsetBy: 2)...]
        var total: TimeInterval = 0
        var parsedAny = false
        if let hIndex = remainder.firstIndex(of: "H") {
            if let h = Double(remainder[remainder.startIndex..<hIndex]) { total += h * 3600; parsedAny = true }
            remainder = remainder[remainder.index(after: hIndex)...]
        }
        if let mIndex = remainder.firstIndex(of: "M") {
            if let m = Double(remainder[remainder.startIndex..<mIndex]) { total += m * 60; parsedAny = true }
            remainder = remainder[remainder.index(after: mIndex)...]
        }
        if let sIndex = remainder.firstIndex(of: "S") {
            if let s = Double(remainder[remainder.startIndex..<sIndex]) { total += s; parsedAny = true }
        }
        guard parsedAny, total.isFinite, total >= 0 else { return nil }
        return total
    }

    /// "PT11M32.00S" -> "11:32". Used for both the game clock and player minutes-played.
    static func clockText(_ iso: String?) -> String? {
        guard let value = seconds(iso) else { return nil }
        return clockText(seconds: value)
    }

    /// Single source of truth for rendering a parsed clock value, so the score
    /// header and legacy-mapper clock strings can never drift from each other.
    /// Shows tenths below a minute remaining ("0:29.8"), matching how live
    /// broadcasts display the clock once it gets that low — whole seconds
    /// otherwise ("3:27"). Never shows raw ISO duration text.
    static func clockText(seconds value: TimeInterval) -> String {
        guard value < 60 else {
            let whole = Int(value.rounded(.down))
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        return String(format: "0:%04.1f", value)
    }

    /// 1→"Q1" 4→"Q4" 5→"OT" 6→"2OT" 7→"3OT" — no hardcoded overtime ceiling.
    static func periodLabel(_ period: Int, regulation: Int = 4) -> String {
        guard period > 0 else { return "—" }
        if period <= regulation { return "Q\(period)" }
        let ot = period - regulation
        return ot == 1 ? "OT" : "\(ot)OT"
    }

    /// "END OF 3RD", "HALFTIME", "END OF 1ST OT" style boundary labels.
    static func ordinalPeriodLabel(_ period: Int, regulation: Int = 4) -> String {
        guard period > 0 else { return "—" }
        if period <= regulation {
            switch period {
            case 1: return "1ST"
            case 2: return "2ND"
            case 3: return "3RD"
            default: return "\(period)TH"
            }
        }
        let ot = period - regulation
        return ot == 1 ? "OT" : "\(ot)OT"
    }
}
