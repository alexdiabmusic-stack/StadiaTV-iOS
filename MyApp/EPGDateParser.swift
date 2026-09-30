import Foundation

/// Calendar/component arithmetic date parsing for guide data. Deliberately avoids
/// `DateFormatter`/`ISO8601DateFormatter` — those are dramatically slower per call at
/// the volume a full guide import parses (tens of thousands of programme timestamps).
nonisolated enum EPGDateParser {

    /// Parses XMLTV's `YYYYMMDDHHMMSS [+/-HHMM]` timestamp format.
    static func parseXMLTV(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let core: String
        var tzSeconds = 0

        if trimmed.count > 14 {
            core = String(trimmed.prefix(14))
            let rest = trimmed.dropFirst(14).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { tzSeconds = parseTZOffset(rest) }
        } else {
            core = trimmed
        }

        guard core.count == 14,
              let year   = Int(core.prefix(4)),
              let month  = Int(core.dropFirst(4).prefix(2)),
              let day    = Int(core.dropFirst(6).prefix(2)),
              let hour   = Int(core.dropFirst(8).prefix(2)),
              let minute = Int(core.dropFirst(10).prefix(2)),
              let second = Int(core.dropFirst(12).prefix(2))
        else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        guard var date = cal.date(from: comps) else { return nil }
        date = date.addingTimeInterval(TimeInterval(-tzSeconds))
        return date
    }

    /// Parses a `+HHMM`/`-HHMM` timezone offset suffix into signed seconds.
    static func parseTZOffset(_ s: String) -> Int {
        guard s.count >= 5 else { return 0 }
        let sign = s.hasPrefix("-") ? -1 : 1
        let digits = String(s.dropFirst())
        guard let h = Int(digits.prefix(2)), let m = Int(digits.dropFirst(2).prefix(2)) else { return 0 }
        return sign * (h * 3600 + m * 60)
    }
}
