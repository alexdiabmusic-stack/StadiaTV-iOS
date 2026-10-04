import Foundation

/// Pure presentation types for the redesigned Game Detail screen. No SwiftUI
/// dependency, so sport-specific mappers (NHLGamePresentation, etc.) are
/// unit-testable without a view hierarchy.

// MARK: - Hero

nonisolated struct GameHeroTeam: Identifiable, Equatable {
    let id: String
    let name: String
    let abbreviation: String
    let logo: URL?
    /// nil before the game has a score (pregame).
    let score: String?
    /// e.g. "36 SHOTS", "12-4" record. Shown under the abbreviation.
    let supportingMetric: String?
    let isLeading: Bool
    let teamID: String
}

nonisolated enum GameStatusKind: Equatable {
    case live
    case intermission
    case scheduled(Date)
    case final
    case other
}

nonisolated struct GameStatusPresentation: Equatable {
    let kind: GameStatusKind
    /// Compact display text, e.g. "OT · 1:42", "2nd · 04:32", "FINAL", "FINAL/OT".
    let text: String
    let accessibilityText: String
    var isLive: Bool { kind == .live || kind == .intermission }
}

// MARK: - Comparison stats

nonisolated enum ComparisonVisualization: Equatable {
    /// Two raw counts compared as a proportional share, e.g. shots, hits.
    case share(away: Double, home: Double)
    /// Two independent percentages on the 0-100 scale (not normalized against each other), e.g. FO%, FG%.
    case percentSplit(away: Double, home: Double)
    /// "made/attempted" fractions, e.g. power play 2/3 vs 1/2. Percent is derived for the bar.
    case fraction(awayMade: Double, awayAttempted: Double, homeMade: Double, homeAttempted: Double)
    /// No meaningful bar — show the number only.
    case none
}

nonisolated struct ComparisonStat: Identifiable, Equatable {
    let id: String
    let label: String
    let awayDisplay: String
    let homeDisplay: String
    var awaySecondary: String? = nil
    var homeSecondary: String? = nil
    let visualization: ComparisonVisualization
    /// True when a smaller value is the better outcome (giveaways, turnovers) — flips which
    /// side is visually emphasized as "leading".
    var lowerIsBetter: Bool = false
    let accessibilityLabel: String

    /// away leads, home leads, or no clear leader (equal / not comparable).
    enum Leader: Equatable { case away, home, none }

    var leader: Leader {
        func flip(_ l: Leader) -> Leader {
            switch l { case .away: return .home; case .home: return .away; case .none: return .none }
        }
        let raw: Leader
        switch visualization {
        case .share(let a, let h): raw = a == h ? .none : (a > h ? .away : .home)
        case .percentSplit(let a, let h): raw = a == h ? .none : (a > h ? .away : .home)
        case .fraction(let am, let aa, let hm, let ha):
            let ap = aa > 0 ? am / aa : 0, hp = ha > 0 ? hm / ha : 0
            raw = ap == hp ? .none : (ap > hp ? .away : .home)
        case .none: raw = .none
        }
        return lowerIsBetter ? flip(raw) : raw
    }
}

nonisolated extension ComparisonStat {
    /// Parses two existing display strings (as already produced by sport mappers, e.g. "36",
    /// "51.6%", "2/3") into a comparison stat. Returns nil when values can't be parsed as
    /// numbers — callers must not fabricate a 0 for missing data.
    static func parse(id: String, label: String, away: String, home: String,
                       awaySecondary: String? = nil, homeSecondary: String? = nil,
                       lowerIsBetter: Bool = false, teamAwayName: String, teamHomeName: String) -> ComparisonStat? {
        let trimmedAway = away.trimmingCharacters(in: .whitespaces)
        let trimmedHome = home.trimmingCharacters(in: .whitespaces)
        guard !trimmedAway.isEmpty, !trimmedHome.isEmpty else { return nil }

        let accessibility = "\(label). \(teamAwayName) \(trimmedAway). \(teamHomeName) \(trimmedHome)."

        if trimmedAway.contains("/"), trimmedHome.contains("/") {
            let awayParts = trimmedAway.split(separator: "/")
            let homeParts = trimmedHome.split(separator: "/")
            if awayParts.count == 2, homeParts.count == 2,
               let am = Double(awayParts[0]), let aa = Double(awayParts[1]),
               let hm = Double(homeParts[0]), let ha = Double(homeParts[1]) {
                return ComparisonStat(id: id, label: label, awayDisplay: trimmedAway, homeDisplay: trimmedHome,
                                       awaySecondary: awaySecondary, homeSecondary: homeSecondary,
                                       visualization: .fraction(awayMade: am, awayAttempted: aa, homeMade: hm, homeAttempted: ha),
                                       lowerIsBetter: lowerIsBetter, accessibilityLabel: accessibility)
            }
        }

        if trimmedAway.hasSuffix("%"), trimmedHome.hasSuffix("%"),
           let a = Double(trimmedAway.dropLast()), let h = Double(trimmedHome.dropLast()) {
            return ComparisonStat(id: id, label: label, awayDisplay: trimmedAway, homeDisplay: trimmedHome,
                                   awaySecondary: awaySecondary, homeSecondary: homeSecondary,
                                   visualization: .percentSplit(away: a, home: h),
                                   lowerIsBetter: lowerIsBetter, accessibilityLabel: accessibility)
        }

        if let a = Double(trimmedAway), let h = Double(trimmedHome) {
            return ComparisonStat(id: id, label: label, awayDisplay: trimmedAway, homeDisplay: trimmedHome,
                                   awaySecondary: awaySecondary, homeSecondary: homeSecondary,
                                   visualization: .share(away: a, home: h),
                                   lowerIsBetter: lowerIsBetter, accessibilityLabel: accessibility)
        }

        // Not numeric on either axis — still show the raw strings, no bar.
        return ComparisonStat(id: id, label: label, awayDisplay: trimmedAway, homeDisplay: trimmedHome,
                               awaySecondary: awaySecondary, homeSecondary: homeSecondary,
                               visualization: .none, lowerIsBetter: lowerIsBetter, accessibilityLabel: accessibility)
    }
}

// MARK: - Scoring timeline

nonisolated enum EventBadge: String, Equatable, Identifiable {
    case powerPlay = "PP"
    case shortHanded = "SH"
    case emptyNet = "EN"
    case penaltyShot = "PS"
    case shootout = "SO"
    case redCard = "RED"
    case yellowCard = "YC"
    case touchdown = "TD"
    case fieldGoal = "FG"
    var id: String { rawValue }
}

nonisolated struct TimelineEvent: Identifiable, Equatable {
    let id: String
    let teamAbbreviation: String
    let teamLogo: URL?
    /// Score immediately after this event, e.g. "1–0". nil for non-scoring events.
    let scoreAfter: String?
    let periodText: String
    let clockText: String?
    /// Scorer / primary actor, shown prominently.
    let headline: String
    /// e.g. "Slap shot".
    let detail: String?
    /// e.g. assist names.
    let secondary: String?
    let badges: [EventBadge]
    let headshot: URL?
    let replayURL: URL?
    /// Provider id of the primary player, for roster/player navigation. nil when unknown.
    let playerProviderID: Int?
}

// MARK: - Leaders

nonisolated struct LeaderCard: Identifiable, Equatable {
    let id: String
    let name: String
    let teamAbbreviation: String
    let headshot: URL?
    /// e.g. "2 G · 1 A", "24 PTS · 8 REB · 5 AST".
    let statLine: String
    let role: String?
    let playerProviderID: Int?
}

// MARK: - Game info

nonisolated struct GameInfoItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let primary: String
    let secondary: String?
}
