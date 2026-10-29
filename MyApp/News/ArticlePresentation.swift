import Foundation

nonisolated extension ESPNArticle {
    var sourceName: String {
        if let publisher, !publisher.isEmpty { return publisher }
        if let host = url?.host { return host.replacingOccurrences(of: "www.", with: "") }
        return byline ?? ""
    }

    var isHighlight: Bool {
        ["video", "highlight", "highlights", "media"].contains(type?.lowercased() ?? "")
    }

    var badgeText: String? {
        switch type?.lowercased() {
        case "breaking": return String(localized: "Breaking")
        case "analysis": return String(localized: "Analysis")
        case "rumor", "rumour": return String(localized: "Rumour")
        default: return nil
        }
    }


    var relativePublishedText: String {
        guard let published, published <= Date() else { return "" }
        return published.formatted(.relative(presentation: .named))
    }

    func metadataLine(includeSource: Bool) -> String {
        ([includeSource ? sourceName : "", categoryLabel, relativePublishedText])
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    func matchesFavoriteTeam(_ team: FavoriteTeam) -> Bool {
        guard league.path == team.leaguePath || league.bannerKey == team.leagueBannerKey,
              categoryLabel == league.shortName else { return false }
        if relevantTeamIDs.contains(team.canonicalTeamID) { return true }

        let taggedText = categories.joined(separator: " ").normalizedForTeamMatching
        let articleText = "\(headline) \(description)".normalizedForTeamMatching
        let abbreviation = team.abbreviation.normalizedForTeamMatching

        if team.discoverMatchPhrases.contains(where: { phrase in
            taggedText.containsBoundedPhrase(phrase) || articleText.containsBoundedPhrase(phrase)
        }) {
            return true
        }

        if abbreviation.count >= 3 {
            let articleTokens = Set(articleText.split(separator: " ").map(String.init))
            let tagTokens = Set(taggedText.split(separator: " ").map(String.init))
            return articleTokens.contains(abbreviation) || tagTokens.contains(abbreviation)
        }

        return false
    }
}

nonisolated private extension FavoriteTeam {
    var discoverMatchPhrases: [String] {
        let normalizedWords = displayName.normalizedForTeamMatching.split(separator: " ").map(String.init)
        var phrases = [displayName.normalizedForTeamMatching]

        if normalizedWords.count >= 3 {
            phrases.append(normalizedWords.suffix(2).joined(separator: " "))
        }

        if let nickname = normalizedWords.last,
           nickname.count >= 4,
           !Self.genericTeamNameWords.contains(nickname) {
            phrases.append(nickname)
        }

        var seen = Set<String>()
        return phrases.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static let genericTeamNameWords: Set<String> = [
        "city", "club", "fc", "sc", "united", "state", "college"
    ]
}

nonisolated private extension String {
    var normalizedForTeamMatching: String {
        let folded = folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    func containsBoundedPhrase(_ phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        return " \(self) ".contains(" \(phrase) ")
    }
}
