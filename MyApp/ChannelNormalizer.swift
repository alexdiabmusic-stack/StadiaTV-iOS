import Foundation

/// Normalizes messy IPTV channel names using rules from curated_tv_guide_filter.json
/// plus hardcoded patterns for common provider decoration (★, ◉, CAF prefix, etc.).
nonisolated final class ChannelNormalizer {

    private var compiledPrefixPatterns: [NSRegularExpression] = []
    private var compiledQualityPatterns: [NSRegularExpression] = []
    private var compiledSourcePatterns: [NSRegularExpression] = []
    private var compiledHidePatterns: [NSRegularExpression] = []
    private var compiledVodPatterns: [NSRegularExpression] = []

    // Hardcoded provider decoration patterns applied before JSON-defined rules
    // These handle real-world provider naming conventions (★, ◉, CAF prefix, etc.)
    private static let providerCountryPrefixRe = try! NSRegularExpression(
        // "CAF ★ ", "CA ★ ", "US ★ ", "DE ★ ", "UK ★ " etc.
        pattern: #"^[A-Z]{2,4}\s*[★\*⭐]\s*"#, options: [])

    private static let decorativeCharRe = try! NSRegularExpression(
        // ★ ◉ ⭐ ● ◆ ▶ etc.
        pattern: "[★◉⭐●◆▶►◀◄◈◇⊕⊗⊘☆✦✧]", options: [])

    private static let bracketTagRe = try! NSRegularExpression(
        // [BK], [HD], [BACKUP], [FHD] etc.
        pattern: #"\[[A-Z0-9\s]{1,12}\]"#, options: .caseInsensitive)

    private static let numberedSuffixRe = try! NSRegularExpression(
        // Strip trailing 3+ digit stream indices ("ESPN+ 449", "Flo 682").
        // 1-2 digit numbers like "RDS 2" are intentional channel names — keep them.
        pattern: #"\s+\d{3,}\s*:?\s*$"#, options: [])

    private static let longBracketSuffixRe = try! NSRegularExpression(
        // [Hockey:2025 Battlefords North Stars...] event descriptions
        pattern: #"\[.{15,}\]\s*$"#, options: [])

    private static let trailingColonRe = try! NSRegularExpression(
        pattern: #"\s*:\s*$"#, options: [])

    init(config: CuratedGuideConfig) {
        let opts: NSRegularExpression.Options = [.caseInsensitive]
        compiledPrefixPatterns  = compile(config.normalization.stripPrefixRegex, options: opts)
        compiledQualityPatterns = compile(config.normalization.stripQualityTokensRegex, options: opts)
        compiledSourcePatterns  = compile(config.normalization.stripSourceTokensRegex, options: opts)
        compiledHidePatterns    = compile(config.filterRules.alwaysHideNamePatterns, options: opts)
        compiledVodPatterns     = compile(config.filterRules.vodLikeNamePatterns, options: opts)
    }

    private func compile(_ patterns: [String], options: NSRegularExpression.Options) -> [NSRegularExpression] {
        patterns.compactMap {
            let pattern = $0.replacingOccurrences(of: "\\\\", with: "\\")
            return try? NSRegularExpression(pattern: pattern, options: options)
        }
    }

    // MARK: - Normalization

    /// Returns a clean, normalized channel name suitable for matching.
    nonisolated func normalize(_ name: String) -> String {
        var result = name

        // Phase 1: Strip provider decoration (order matters)
        result = strip(Self.longBracketSuffixRe, from: result)      // [Hockey:2025...] event suffixes
        result = strip(Self.bracketTagRe, from: result)              // [BK], [FHD] etc.
        result = strip(Self.providerCountryPrefixRe, from: result)   // "CAF ★ ", "US ★ "
        result = strip(Self.decorativeCharRe, from: result)          // remaining ★ ◉ etc.
        result = strip(Self.numberedSuffixRe, from: result)          // trailing " 449", " 01 :"
        result = strip(Self.trailingColonRe, from: result)           // trailing " :"

        // Phase 2: JSON-defined rules
        for pattern in compiledPrefixPatterns {
            result = apply(pattern, to: result, replacement: "")
        }
        for pattern in compiledQualityPatterns {
            result = apply(pattern, to: result, replacement: " ")
        }
        for pattern in compiledSourcePatterns {
            result = apply(pattern, to: result, replacement: " ")
        }

        // Phase 3: Clean up whitespace and punctuation
        result = result
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.union(.init(charactersIn: " ")))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    // MARK: - Country hint extraction

    /// Detects country/region hint from provider prefix patterns like "CAF ★", "CA ★", "US ★".
    nonisolated func extractCountryHint(from name: String) -> String? {
        // Map provider prefixes to ISO country codes
        let prefixMap: [(prefix: String, country: String)] = [
            ("CAF", "CA"), ("CA", "CA"),
            ("US", "US"), ("UK", "GB"), ("GB", "GB"),
            ("AU", "AU"), ("FR", "FR"), ("DE", "DE"),
            ("BE", "BE"), ("NL", "NL"), ("ES", "ES"),
            ("IT", "IT"), ("PT", "PT"), ("TR", "TR"),
            ("PL", "PL"), ("IN", "IN"), ("AR", "AR"),
        ]
        let nsName = name as NSString
        let range = NSRange(location: 0, length: nsName.length)
        if let match = Self.providerCountryPrefixRe.firstMatch(in: name, range: range) {
            let matchStr = nsName.substring(with: match.range).trimmingCharacters(in: .whitespaces)
            for (prefix, country) in prefixMap {
                if matchStr.hasPrefix(prefix) { return country }
            }
        }
        return nil
    }

    // MARK: - Hide check

    /// Returns true if the channel NAME should be hidden. Never applied to programme content.
    nonisolated func shouldHide(channelName: String) -> Bool {
        let range = NSRange(channelName.startIndex..., in: channelName)
        for pattern in compiledHidePatterns {
            if pattern.firstMatch(in: channelName, range: range) != nil { return true }
        }
        for pattern in compiledVodPatterns {
            if pattern.firstMatch(in: channelName, range: range) != nil { return true }
        }
        return false
    }

    // MARK: - Helpers

    private func strip(_ regex: NSRegularExpression, from string: String) -> String {
        apply(regex, to: string, replacement: "")
    }

    private func apply(_ regex: NSRegularExpression, to string: String, replacement: String) -> String {
        regex.stringByReplacingMatches(
            in: string,
            range: NSRange(string.startIndex..., in: string),
            withTemplate: replacement
        )
    }
}
