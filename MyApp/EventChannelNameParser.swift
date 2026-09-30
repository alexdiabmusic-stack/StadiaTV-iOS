import Foundation

/// Parses "event channel" names — channel entries whose name IS the fixture, e.g.
/// "Muskingum at Ohio State 7:00 PM" — extracting the two team names and a kickoff
/// time, and verifying that time against a match's known start time.
///
/// Some IPTV provider panels auto-tag channel names with a country/quality badge by
/// naively substring-replacing "us" (case-insensitive) with "US ★", with no word-boundary
/// check — corrupting any word that merely contains "us", e.g. "Muskingum" becomes
/// "MUS ★kingum". `repairBadgeCorruption` reverses that specific pattern before anything
/// else touches the name; every consumer in `SourceMatcher` runs names through it first.
nonisolated enum EventChannelNameParser {

    /// Matches the corruption signature: an uppercase "US" glued directly (no space) to
    /// a preceding word character, followed by " ★" glued directly to trailing letters.
    /// A legitimate standalone "US ★" badge always has a space or delimiter before it,
    /// so it never matches this pattern.
    private static let corruptionPattern = try! NSRegularExpression(pattern: #"(\w+)US ★(\w*)"#)
    private static let separatorPattern = try! NSRegularExpression(
        pattern: #"(?i)\s(?:vs[.]?|versus|v[.]|at|@|-|c)\s"#)
    private static let timePattern = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}):(\d{2})\s*([AaPp]\.?[Mm]\.?)?\b"#)

    /// Reverses a mid-word "US ★" badge injection, e.g. "MUS ★kingum" -> "Muskingum".
    static func repairBadgeCorruption(_ text: String) -> String {
        let ns = text as NSString
        let matches = corruptionPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            let prefix = ns.substring(with: match.range(at: 1))
            let suffix = ns.substring(with: match.range(at: 2))
            result = (result as NSString).replacingCharacters(in: match.range, with: "\(prefix)us\(suffix)")
        }
        return result
    }

    /// Extracts a kickoff time (24h hour/minute) from an event-channel name, if present.
    static func extractKickoffTime(_ text: String) -> (hour: Int, minute: Int)? {
        let ns = text as NSString
        guard let match = timePattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              var hour = Int(ns.substring(with: match.range(at: 1))),
              let minute = Int(ns.substring(with: match.range(at: 2))),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if match.range(at: 3).location != NSNotFound {
            let meridiem = ns.substring(with: match.range(at: 3)).lowercased()
            if meridiem.hasPrefix("p"), hour < 12 { hour += 12 }
            if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
        }
        return (hour, minute)
    }

    /// Splits an event-channel name (with any kickoff time already removed) into its
    /// two team names, on the same separator set fixture judging accepts: vs/at/@/-/c.
    static func extractTeams(_ text: String) -> (first: String, second: String)? {
        let ns = text as NSString
        guard let match = separatorPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let first = ns.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
        let second = ns.substring(from: match.range.location + match.range.length).trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty, !second.isEmpty else { return nil }
        return (first, second)
    }

    /// Full parse: repairs badge corruption, pulls out the kickoff time, then splits
    /// the remaining (time-stripped) text into the two team names.
    static func parse(_ rawName: String) -> (first: String, second: String, kickoff: (hour: Int, minute: Int)?)? {
        let repaired = repairBadgeCorruption(rawName)
        let kickoff = extractKickoffTime(repaired)
        var textForTeams = repaired
        let ns = repaired as NSString
        if let match = timePattern.firstMatch(in: repaired, range: NSRange(location: 0, length: ns.length)) {
            textForTeams = ns.replacingCharacters(in: match.range, with: "")
        }
        guard let teams = extractTeams(textForTeams) else { return nil }
        return (teams.first, teams.second, kickoff)
    }

    /// True if a parsed kickoff time falls within `toleranceMinutes` of the match's
    /// actual start time on the same calendar day. Event-channel names never carry a
    /// timezone, so this compares wall-clock hour/minute against the match date.
    static func verifiesKickoff(
        hour: Int, minute: Int, against matchDate: Date,
        calendar: Calendar = .current, toleranceMinutes: Int = 30
    ) -> Bool {
        var comps = calendar.dateComponents([.year, .month, .day], from: matchDate)
        comps.hour = hour
        comps.minute = minute
        guard let candidate = calendar.date(from: comps) else { return false }
        return abs(candidate.timeIntervalSince(matchDate)) <= TimeInterval(toleranceMinutes * 60)
    }
}
