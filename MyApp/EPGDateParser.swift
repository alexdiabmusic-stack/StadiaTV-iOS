import Foundation

/// Date parsing for guide data. Deliberately avoids `DateFormatter`/`ISO8601DateFormatter` —
/// those are dramatically slower per call at the volume a full guide import parses (tens of
/// thousands of programme timestamps), and so is building a `Calendar`/`DateComponents` per call.
nonisolated enum EPGDateParser {

    /// Parses XMLTV's `YYYYMMDDHHMMSS [+/-HHMM]` timestamp format.
    ///
    /// Well-formed timestamps (ASCII digits naming a real date after 1582) are converted with
    /// integer arithmetic. Anything else — signs, spaces or letters inside the digits, an
    /// impossible date such as Feb 31 or hour 24 — takes `parseXMLTVWithCalendar`, the original
    /// `Calendar`-based path, so odd input keeps whatever result it always had.
    static func parseXMLTV(_ s: String) -> Date? {
        var text = s
        if let fast = text.withUTF8({ parseXMLTVFast($0) }) { return fast }
        return parseXMLTVWithCalendar(s)
    }

    /// Parses the same timestamps from raw UTF-8, or returns nil for anything the integer fast
    /// path declines (it never falls back to `Calendar`). For callers that must not allocate a
    /// `String` per timestamp and can treat "unsure" as "leave it to the full parser".
    static func parseXMLTV(utf8 bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        parseXMLTVFast(bytes)
    }

    // MARK: Fast path

    private static func parseXMLTVFast(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        var start = 0
        var end = bytes.count
        while start < end, isSpaceOrTab(bytes[start]) { start += 1 }
        while end > start, isSpaceOrTab(bytes[end - 1]) { end -= 1 }
        // Non-ASCII anywhere (e.g. a no-break space) is rare and left to the Calendar path.
        for i in start..<end where bytes[i] >= 0x80 { return nil }

        let length = end - start
        guard length >= 14 else { return nil }

        func digits(_ offset: Int, _ count: Int) -> Int? {
            var value = 0
            for i in 0..<count {
                let b = bytes[start + offset + i]
                guard b >= 0x30, b <= 0x39 else { return nil }
                value = value * 10 + Int(b - 0x30)
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(4, 2), let day = digits(6, 2),
              let hour = digits(8, 2), let minute = digits(10, 2), let second = digits(12, 2),
              year >= 1583, (1...12).contains(month), (1...daysInMonth(year: year, month: month)).contains(day),
              hour < 24, minute < 60, second < 60
        else { return nil }

        var tzSeconds = 0
        if length > 14 {
            // Everything after the 14 digits, trimmed of spaces/tabs, is the zone suffix.
            var restStart = start + 14
            while restStart < end, isSpaceOrTab(bytes[restStart]) { restStart += 1 }
            if restStart < end {
                guard let offset = parseTZOffsetBytes(bytes, from: restStart, to: end) else { return nil }
                tzSeconds = offset
            }
        }

        let epochSeconds = daysSinceEpoch(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + second - tzSeconds
        return Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    /// Same result as `parseTZOffset` for the plain cases: fewer than 5 characters is UTC; otherwise
    /// a leading `-` means negative (anything else is positive and the first character is skipped),
    /// followed by two hour digits and two minute digits. Returns nil for a suffix that isn't
    /// plain digits there, leaving the original parser to decide.
    private static func parseTZOffsetBytes(_ bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Int? {
        guard to - from >= 5 else { return 0 }
        let sign = bytes[from] == UInt8(ascii: "-") ? -1 : 1
        func twoDigits(_ at: Int) -> Int? {
            let a = bytes[at], b = bytes[at + 1]
            guard a >= 0x30, a <= 0x39, b >= 0x30, b <= 0x39 else { return nil }
            return Int(a - 0x30) * 10 + Int(b - 0x30)
        }
        guard let h = twoDigits(from + 1), let m = twoDigits(from + 3) else { return nil }
        return sign * (h * 3600 + m * 60)
    }

    private static func isSpaceOrTab(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days from 1970-01-01 to the given proleptic-Gregorian date (Howard Hinnant's algorithm).
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = y / 400   // y is positive here
        let yearOfEra = y - era * 400
        let monthFromMarch = (month + 9) % 12
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // MARK: Original path

    /// The original `Calendar`-based implementation, kept for input the fast path declines.
    static func parseXMLTVWithCalendar(_ s: String) -> Date? {
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
