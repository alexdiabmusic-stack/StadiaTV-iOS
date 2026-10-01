import Foundation

/// Detects language tags embedded in a channel's own name (e.g. "EN:", "[ES]", "English").
///
/// This is unrelated to event matching — event-to-stream linking now lives entirely in
/// `MatchLinkService`/`StreamLinker` (see MatchLinker/PROMPTS.md). `languageTags` only feeds
/// `LiveTVFilters`' language filter chip, which has nothing to do with matches or guides, so it
/// survived the old `SourceMatcher` matcher's removal as its own small utility.
nonisolated enum SourceMatcher {

    /// Language tags detected on a channel name, from whole-word tokens such as
    /// "EN:", "[ES]" or "English". `normalize` would strip the leading country/
    /// language prefix, so this scans the name with the prefix kept.
    static func languageTags(in channelName: String) -> Set<String> {
        let cleaned = channelName
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
        let tokens = Set(String(cleaned).split(separator: " ").map(String.init))

        var tags: Set<String> = []
        for language in StreamLanguage.all {
            if tokens.contains(language.code) || language.aliases.contains(where: tokens.contains) {
                tags.insert(language.code)
            }
        }
        return tags
    }
}
