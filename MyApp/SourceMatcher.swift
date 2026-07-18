import Foundation

/// Ranks playlist channels by how likely they are to be carrying a given match.
///
/// The score combines several signals:
///  - an event-specific channel mentioning *both* teams is the strongest hit
///  - each team name / abbreviation match
///  - the ESPN broadcast network (e.g. "ESPN", "TNT") appearing in the channel name
///  - league / sport keywords
///  - a small bonus for channels sitting in a "sports" group
enum SourceMatcher {

    /// Words that carry no discriminating value when matching team/channel names.
    private static let stopWords: Set<String> = [
        "fc", "cf", "sc", "afc", "the", "of", "and", "city", "united", "club",
        "hd", "sd", "fhd", "uhd", "4k", "tv", "channel", "live", "sports", "sport"
    ]

    static func rank(match: Match, channels: [Channel]) -> [RankedSource] {
        let homeTokens = tokens(from: match.home.displayName)
        let awayTokens = tokens(from: match.away.displayName)
        let homeAbbr = match.home.abbreviation.lowercased()
        let awayAbbr = match.away.abbreviation.lowercased()
        let broadcasts = match.broadcasts.map { $0.lowercased() }
        let leagueKeywords = match.league.keywords
        let leagueShort = match.league.shortName.lowercased()

        var ranked: [RankedSource] = []

        for channel in channels {
            let haystack = normalize(channel.name + " " + (channel.group ?? ""))
            let haystackTokens = Set(haystack.split(separator: " ").map(String.init))
            var score = 0

            let homeHit = matches(homeTokens, in: haystack, tokens: haystackTokens)
            let awayHit = matches(awayTokens, in: haystack, tokens: haystackTokens)

            // Both teams named → almost certainly the event feed.
            if homeHit && awayHit { score += 100 }
            else if homeHit || awayHit { score += 40 }

            // Abbreviation matches (whole-token only to avoid noise).
            if !homeAbbr.isEmpty, haystackTokens.contains(homeAbbr) { score += 15 }
            if !awayAbbr.isEmpty, haystackTokens.contains(awayAbbr) { score += 15 }

            // Broadcast network on the channel name.
            for network in broadcasts where !network.isEmpty {
                if haystack.contains(network) { score += 35 }
            }

            // League keywords.
            for keyword in leagueKeywords where haystack.contains(keyword) {
                score += 12
            }
            if haystack.contains(leagueShort) { score += 12 }

            // Sports group / generic sports network bonus.
            if let group = channel.group?.lowercased(),
               group.contains("sport") || group.contains(match.league.group.rawValue.lowercased()) {
                score += 6
            }
            if isKnownSportsNetwork(haystack) { score += 5 }

            if score > 0 {
                ranked.append(RankedSource(channel: channel, score: score))
            }
        }

        return ranked.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.channel.name.localizedCaseInsensitiveCompare($1.channel.name) == .orderedAscending
        }
    }

    // MARK: - Helpers

    private static func matches(_ needleTokens: [String], in haystack: String, tokens haystackTokens: Set<String>) -> Bool {
        guard !needleTokens.isEmpty else { return false }
        // A team matches if any of its significant tokens appears as a whole word.
        for token in needleTokens where token.count >= 3 {
            if haystackTokens.contains(token) { return true }
            // City/nickname often appears joined, allow substring for longer tokens.
            if token.count >= 5 && haystack.contains(token) { return true }
        }
        return false
    }

    private static func tokens(from name: String) -> [String] {
        normalize(name)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    /// Lowercases, strips diacritics, removes country prefixes (e.g. "US:", "UK|")
    /// and punctuation, and collapses whitespace.
    private static func normalize(_ input: String) -> String {
        var s = input.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        // Drop a leading "xx:" or "xx|" country/quality prefix.
        if let separatorIndex = s.firstIndex(where: { $0 == ":" || $0 == "|" }),
           s.distance(from: s.startIndex, to: separatorIndex) <= 4 {
            s = String(s[s.index(after: separatorIndex)...])
        }
        let allowed = s.map { char -> Character in
            char.isLetter || char.isNumber ? char : " "
        }
        return String(allowed)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let knownNetworks: Set<String> = [
        "espn", "fox", "cbs", "nbc", "abc", "tnt", "tbs", "bein", "sky", "dazn",
        "bt", "nfl", "nba", "mlb", "nhl", "peacock", "paramount", "prime",
        "usa network", "fs1", "fs2", "btn", "sec", "acc", "willow", "tudn"
    ]

    private static func isKnownSportsNetwork(_ haystack: String) -> Bool {
        knownNetworks.contains { haystack.contains($0) }
    }
}
