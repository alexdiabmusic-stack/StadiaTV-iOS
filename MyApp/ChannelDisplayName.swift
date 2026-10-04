import Foundation

/// Display-only cleanup of raw IPTV channel titles, e.g. "US ★ NBC SPORTS HD
/// [CALIFORNIA]" -> "NBC Sports California" with country "US" and quality "HD".
///
/// This is deliberately separate from `ChannelNormalizer` (matching-oriented,
/// collapses to alphanumerics for scoring) — it never touches `Channel.name`,
/// which stays untouched for matching/playback/diagnostics. When confidence is
/// low (the raw name looks like an event-slot title, not a channel brand), the
/// raw name is returned unchanged rather than guessing.
nonisolated enum ChannelDisplayName {
    struct Result: Equatable {
        let title: String
        let countryCode: String?
        let quality: String?

        var flag: String? { countryCode.flatMap(ChannelDisplayName.flagEmoji) }
    }

    static func make(from raw: String) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let countryCode = extractCountryCode(trimmed)
        let quality = extractQuality(trimmed)

        guard isConfident(trimmed) else {
            return Result(title: trimmed, countryCode: countryCode, quality: quality)
        }

        var working = trimmed
        working = strip(countryPrefixRe, from: working)
        working = strip(qualityTokenRe, from: working)
        working = strip(decorativeCharRe, from: working)
        working = expandRegionBracket(in: working)
        working = strip(technicalBracketRe, from: working)
        working = collapseWhitespace(working)
        let title = titleCase(working)

        guard title.count >= 2 else {
            return Result(title: trimmed, countryCode: countryCode, quality: quality)
        }
        return Result(title: title, countryCode: countryCode, quality: quality)
    }

    // MARK: - Confidence gate

    /// Raw names that look like a scheduled event slot (a slot number, an embedded
    /// date, a kickoff time, or a "Team vs Team" title) aren't channel brands —
    /// cleaning them up would either do nothing useful or mangle them.
    private static func isConfident(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        if slotRe.firstMatch(in: name, range: range) != nil { return false }
        if isoDateRe.firstMatch(in: name, range: range) != nil { return false }
        if kickoffTimeRe.firstMatch(in: name, range: range) != nil { return false }
        if versusRe.firstMatch(in: name, range: range) != nil { return false }
        return true
    }

    // MARK: - Country

    private static func extractCountryCode(_ name: String) -> String? {
        let map = ["CAF": "CA", "CANADA": "CA", "USA": "US", "UNITED STATES": "US", "UK": "GB", "GB": "GB"]
        let nsName = name as NSString
        guard let match = countryPrefixRe.firstMatch(in: name, range: NSRange(location: 0, length: nsName.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        let token = nsName.substring(with: match.range(at: 1)).uppercased()
        return map[token] ?? (token.count == 2 ? token : nil)
    }

    static func flagEmoji(for countryCode: String) -> String? {
        let code = countryCode.uppercased()
        guard code.count == 2 else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard let flagScalar = Unicode.Scalar(127397 + scalar.value) else { return nil }
            scalars.append(flagScalar)
        }
        return String(scalars)
    }

    // MARK: - Quality

    private static func extractQuality(_ name: String) -> String? {
        let nsName = name as NSString
        guard let match = qualityTokenRe.firstMatch(in: name, range: NSRange(location: 0, length: nsName.length)) else { return nil }
        return nsName.substring(with: match.range).uppercased()
    }

    // MARK: - Region bracket -> trailing word

    /// "[CALIFORNIA]" -> " California" appended after the brackets are removed;
    /// only short, letters-only brackets qualify (event descriptions are long
    /// and/or contain digits/punctuation and are left to the technical-bracket strip).
    private static func expandRegionBracket(in name: String) -> String {
        let nsName = name as NSString
        let range = NSRange(location: 0, length: nsName.length)
        guard let match = regionBracketRe.firstMatch(in: name, range: range),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return name }
        let content = nsName.substring(with: match.range(at: 1))
        guard !technicalTagTokens.contains(content.uppercased()) else {
            return (name as NSString).replacingCharacters(in: match.range, with: "")
        }
        let replaced = (name as NSString).replacingCharacters(in: match.range, with: " \(content)")
        return replaced
    }

    // MARK: - Title casing

    private static let forcedUppercase: Set<String> = [
        "NBC", "ESPN", "CBS", "BBC", "TSN", "FS1", "FS2", "NFL", "NBA", "NHL", "MLB", "MLS",
        "TNT", "TBS", "UFC", "PGA", "USA", "UK", "DAZN", "CNN", "FOX", "SNY", "YES", "ACC",
        "SEC", "NESN", "MSG", "CBC", "TVA", "RDS", "ATP", "WTA", "F1", "TV"
    ]

    private static func titleCase(_ name: String) -> String {
        name.split(separator: " ").map { word -> String in
            let upper = word.uppercased()
            if forcedUppercase.contains(upper) { return upper }
            // A trailing feed/channel number on a known acronym ("ESPN2", "FOX5") stays
            // fully uppercase rather than title-casing into "Espn2".
            let base = String(upper.reversed().drop(while: \.isNumber).reversed())
            if base.count != upper.count, forcedUppercase.contains(base) { return upper }
            guard let first = word.first else { return String(word) }
            return String(first).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static func collapseWhitespace(_ name: String) -> String {
        name.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func strip(_ regex: NSRegularExpression, from string: String) -> String {
        regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: "")
    }

    // MARK: - Patterns

    private static let technicalTagTokens: Set<String> = [
        "HD", "SD", "FHD", "UHD", "4K", "BACKUP", "BK", "ENG", "ESP", "FRA", "GER", "ITA",
        "POR", "ARA", "TUR", "POL", "NLD", "ZHO", "JPN", "KOR", "HIN", "RUS", "EAST", "WEST"
    ]

    private static let countryPrefixRe = try! NSRegularExpression(
        pattern: #"^\s*(?:\[)?(CAF|CANADA|UNITED STATES|USA|CA|US|UK|GB|AU|FR|DE|BE|NL|ES|IT|PT|TR|PL|IN|AR|BR|MX|ZA|NZ|IE|CH|AT|SE|NO|DK|FI|GR|RU|JP|KR|CN|INTL)(?:\])?\s*(?:[★\*⭐:|\-]\s*|(?<=\])\s*)"#,
        options: .caseInsensitive)
    private static let qualityTokenRe = try! NSRegularExpression(
        pattern: #"\b(?:FHD|UHD|HD|SD|4K)\b[⁰¹²³⁴⁵⁶⁷⁸⁹]*"#, options: .caseInsensitive)
    private static let decorativeCharRe = try! NSRegularExpression(
        pattern: "[★◉⭐●◆▶►◀◄◈◇⊕⊗⊘☆✦✧]", options: [])
    private static let technicalBracketRe = try! NSRegularExpression(
        pattern: #"\[(?:BK|BACKUP|BCKP|HD|SD|FHD|UHD|4K|HEVC|H[.]?26[45]|ENG|ESP|FRA|GER|ITA|POR|ARA|TUR|POL|NLD|ZHO|JPN|KOR|HIN|RUS|EAST|WEST)\]"#,
        options: .caseInsensitive)
    private static let regionBracketRe = try! NSRegularExpression(
        pattern: #"\[([A-Za-z]{3,20})\]\s*$"#, options: [])
    private static let slotRe = try! NSRegularExpression(
        pattern: #"\b\d{1,4}\s*:(?:\s|$)|(?:SERIE[S]?|EVENT)\s+\d{1,4}\b"#, options: .caseInsensitive)
    private static let isoDateRe = try! NSRegularExpression(pattern: #"\b20\d{2}-\d{2}-\d{2}\b"#)
    private static let kickoffTimeRe = try! NSRegularExpression(
        pattern: #"\b\d{1,2}:\d{2}\s*(?:AM|PM)\b"#, options: .caseInsensitive)
    private static let versusRe = try! NSRegularExpression(
        pattern: #"\s(?:vs\.?|@)\s"#, options: .caseInsensitive)
}
