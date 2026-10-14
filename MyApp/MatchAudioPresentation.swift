import Foundation

/// A compact sports status shared by audio lists and Now Playing.
/// Sport-specific provider strings remain authoritative when structured fields are missing.
nonisolated enum MatchAudioPresentation {
    static func status(_ match: Match) -> String {
        let detail = match.statusDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = detail.lowercased()
        if ["postpon", "cancel", "suspend", "delay", "unavailable"].contains(where: lower.contains) {
            return detail
        }
        if match.state == .final { return String(localized: "FINAL") }
        if match.state == .pre {
            return match.date.formatted(date: .abbreviated, time: .shortened)
        }
        if lower.contains("intermission") || lower.contains("halftime") {
            // Do not combine an active-looking clock with a break.
            if lower.contains("halftime") { return String(localized: "Halftime") }
            if let period = match.liveContext.period?.displayName {
                return String(localized: "INT · After \(period)")
            }
            return String(localized: "Intermission")
        }
        if match.league.path == "baseball/mlb", let baseball = match.liveContext.baseball,
           let inning = baseball.inning {
            return [String(localized: "LIVE"), baseball.inningHalf, inning].compactMap { $0 }.joined(separator: " · ")
        }
        if match.league.path.hasPrefix("soccer/"), let minute = match.liveContext.soccer?.minute {
            return String(localized: "LIVE") + " · " + minute + (minute.contains("′") || minute.contains("'") ? "" : "′")
        }
        if detail.isEmpty { return String(localized: "Status unavailable") }
        return lower.contains("live") ? detail : String(localized: "LIVE") + " · " + detail
    }
}
