import Foundation

/// Deterministic relevance ranking for a match's "Related News" section. News is
/// otherwise sourced league-wide (`SportsRepository.legacyNews`), which is how an
/// NHL game could surface an unrelated CBS article about a college football
/// matchup merely because the provider mis-tagged its category — this never
/// trusts `article.categories`/the request league alone; every tier is earned by
/// matching text (headline/description/categories) against the game's own teams,
/// a participating player, or the league's own keywords (`League.keywords`,
/// already used by the stream-matching engine for the same kind of alias lookup).
nonisolated enum MatchNewsRelevance {
    private enum Tier: Int, Comparable {
        case bothTeams = 1, oneTeam = 2, player = 3, league = 4
        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Ranks and filters `articles` for relevance to `match`, dropping anything that
    /// doesn't clear the league bar. Returns `[]` when nothing is relevant enough —
    /// callers should hide the Related News section in that case rather than show it empty.
    static func rank(articles: [ESPNArticle], match: Match, participantNames: [String] = []) -> [ESPNArticle] {
        let home = TeamTokens(side: match.home)
        let away = TeamTokens(side: match.away)
        let leagueTokens = (match.league.keywords + [match.league.name, match.league.shortName]).map(normalize)
        let playerTokens = Set(participantNames.map(normalize)).subtracting([""])

        var scored: [(article: ESPNArticle, tier: Tier)] = []
        for article in articles {
            // Deliberately headline + description only — a provider's `categories` tag
            // (the thing that mis-files articles under the wrong league in the first
            // place) is never treated as evidence on its own.
            let originalText = [article.headline, article.description].joined(separator: " ")
            let haystack = normalize(originalText)
            let hasLeague = containsAny(leagueTokens, in: haystack)

            let homeStrong = home.matchesStrong(haystack: haystack, original: originalText)
            let awayStrong = away.matchesStrong(haystack: haystack, original: originalText)
            let homeNickname = home.matchesNickname(haystack: haystack)
            let awayNickname = away.matchesNickname(haystack: haystack)
            // A nickname alone ("Kings", "Rangers") only counts as team evidence when the
            // league's own keywords are also present, or when the *other* side's nickname
            // co-occurs — two distinct team nicknames appearing together is itself strong
            // disambiguating evidence, even with no league keyword in a short headline like
            // "Kings vs. Sharks: what to watch". A single bare nickname (e.g. an NBA article
            // about the Sacramento Kings) never qualifies on its own.
            let hasHome = homeStrong || (homeNickname && (hasLeague || awayNickname))
            let hasAway = awayStrong || (awayNickname && (hasLeague || homeNickname))
            let hasPlayer = !playerTokens.isEmpty && containsAny(Array(playerTokens), in: haystack)

            if hasHome && hasAway {
                scored.append((article, .bothTeams))
            } else if hasHome || hasAway {
                scored.append((article, .oneTeam))
            } else if hasPlayer {
                scored.append((article, .player))
            } else if hasLeague {
                scored.append((article, .league))
            }
            // Anything else (no team/player/league textual evidence) is dropped,
            // regardless of what league the provider filed it under.
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return (lhs.article.published ?? .distantPast) > (rhs.article.published ?? .distantPast)
            }
            .map(\.article)
    }

    /// Token set for one side of the match, with the nickname-alone case (e.g. "Kings",
    /// "Rangers") gated behind `leaguePresent` so it can't match an unrelated team in
    /// another sport that happens to share a nickname (Sacramento Kings, Texas Rangers).
    private struct TeamTokens {
        let displayPhrase: String
        let abbreviation: String
        let nicknamePhrase: String?

        init(side: TeamSide) {
            displayPhrase = normalize(side.displayName)
            abbreviation = side.abbreviation
            let nickname = normalize(side.shortName)
            nicknamePhrase = nickname.isEmpty || nickname == displayPhrase ? nil : nickname
        }

        func matchesStrong(haystack: String, original: String) -> Bool {
            if !displayPhrase.isEmpty, containsPhrase(displayPhrase, in: haystack) { return true }
            if abbreviation.count >= 2, containsWholeWordCaseSensitive(abbreviation, in: original) { return true }
            return false
        }

        func matchesNickname(haystack: String) -> Bool {
            guard let nicknamePhrase else { return false }
            return containsPhrase(nicknamePhrase, in: haystack)
        }
    }

    // MARK: - Matching helpers

    private static func normalize(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US_POSIX")).lowercased()
    }

    private static func containsAny(_ phrases: [String], in haystack: String) -> Bool {
        phrases.contains { !$0.isEmpty && containsPhrase($0, in: haystack) }
    }

    private static func containsPhrase(_ phrase: String, in haystack: String) -> Bool {
        guard let regex = wordBoundaryRegex(for: phrase, caseSensitive: false) else { return false }
        return regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
    }

    private static func containsWholeWordCaseSensitive(_ token: String, in text: String) -> Bool {
        guard let regex = wordBoundaryRegex(for: token, caseSensitive: true) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func wordBoundaryRegex(for phrase: String, caseSensitive: Bool) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: #"\ "#, with: #"\s+"#)
        let pattern = #"\b"# + escaped + #"\b"#
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        return try? NSRegularExpression(pattern: pattern, options: options)
    }
}
