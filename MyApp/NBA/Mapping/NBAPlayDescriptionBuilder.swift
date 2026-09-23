import Foundation

/// NBA's live play-by-play `description` field already reads as a complete
/// sentence ("Curry 26' 3PT Jump Shot (12 PTS) (Green 3 AST)"), so it is always
/// preferred verbatim over anything this type could compose. Structured
/// composition below is only a fallback for the rare payload that omits it,
/// and never claims more than the supplied fields actually say.
nonisolated enum NBAPlayDescriptionBuilder {
    static func humanize(_ value: String) -> String {
        let text = value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard !text.isEmpty else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func describe(type: NBAPlayType, description: String?, playerName: String?, assistPlayerName: String?,
                         blockPlayerName: String?, stealPlayerName: String?, teamTricode: String?, shotDistance: Double?,
                         period: Int, scoreHome: Int?, scoreAway: Int?) -> (String, String?) {
        func join(_ values: [String?]) -> String? {
            let text = values.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
            return text.isEmpty ? nil : text
        }
        let who = playerName ?? teamTricode

        let title: String
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = description
        } else {
            switch type {
            case .madeShot:
                title = shotDistance.map { "\(who.map { "\($0) " } ?? "")makes a \(Int($0.rounded()))-foot shot" }
                    ?? "\(who.map { "\($0) " } ?? "")makes a shot"
            case .missedShot:
                title = shotDistance.map { "\(who.map { "\($0) " } ?? "")misses a \(Int($0.rounded()))-foot shot" }
                    ?? "\(who.map { "\($0) " } ?? "")misses a shot"
            case .freeThrow: title = who.map { "\($0) free throw" } ?? "Free throw"
            case .rebound: title = who.map { "\($0) rebound" } ?? "Rebound"
            case .assist: title = who.map { "\($0) assist" } ?? "Assist"
            case .turnover: title = who.map { "\($0) turnover" } ?? "Turnover"
            case .steal: title = who.map { "\($0) steal" } ?? "Steal"
            case .block: title = who.map { "\($0) blocks the shot" } ?? "Blocked shot"
            case .personalFoul: title = who.map { "\($0) — Personal foul" } ?? "Personal foul"
            case .shootingFoul: title = who.map { "\($0) — Shooting foul" } ?? "Shooting foul"
            case .offensiveFoul: title = who.map { "\($0) — Offensive foul" } ?? "Offensive foul"
            case .technicalFoul: title = who.map { "\($0) — Technical foul" } ?? "Technical foul"
            case .flagrantFoul: title = who.map { "\($0) — Flagrant foul" } ?? "Flagrant foul"
            case .substitution: title = who.map { "Substitution: \($0)" } ?? "Substitution"
            case .timeout: title = who.map { "\($0) timeout" } ?? "Timeout"
            case .jumpBall: title = who.map { "Jump ball: \($0)" } ?? "Jump ball"
            case .violation: title = who.map { "\($0) — Violation" } ?? "Violation"
            case .periodStart: title = "Start of \(NBADuration.ordinalPeriodLabel(period))"
            case .periodEnd: title = period == 2 ? "Halftime" : "End of \(NBADuration.ordinalPeriodLabel(period))"
            case .gameEnd: title = "Final"
            case .instantReplay: title = "Replay review"
            case .unknown(let raw): title = raw.isEmpty ? "Game event" : humanize(raw)
            }
        }

        let showScore = type.isScoring && scoreHome != nil && scoreAway != nil
        let subtitle = join([
            assistPlayerName.map { "Assist: \($0)" },
            blockPlayerName.map { "Blocked by \($0)" },
            stealPlayerName.map { "Steal: \($0)" },
            playerName != nil ? teamTricode : nil,
            showScore ? "\(scoreAway!)-\(scoreHome!)" : nil
        ])
        return (title, subtitle)
    }

    static func priority(for type: NBAPlayType, subType: String?) -> NBAPlayPriority {
        switch type {
        case .madeShot, .flagrantFoul, .technicalFoul, .gameEnd:
            return .high
        case .missedShot, .freeThrow, .block, .steal, .shootingFoul, .offensiveFoul, .timeout, .periodStart, .periodEnd, .instantReplay:
            return .medium
        case .turnover:
            let sub = (subType ?? "").lowercased()
            return sub.contains("shot clock") || sub.contains("offensive foul") ? .medium : .compact
        case .rebound, .assist, .personalFoul, .substitution, .jumpBall, .violation, .unknown:
            return .compact
        }
    }
}
