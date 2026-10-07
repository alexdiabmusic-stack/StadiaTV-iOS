import Foundation

/// Pure builders turning Soccer domain models into the shared Game Detail
/// presentation types. No SwiftUI dependency; shared by every soccer provider via
/// `SoccerGameHeaderView`/`SoccerOverviewView`.
nonisolated enum SoccerGamePresentation {

    // MARK: - Hero

    static func heroStatus(match: SoccerMatch) -> GameStatusPresentation {
        switch match.status {
        case .scheduled, .pregame:
            return GameStatusPresentation(kind: .scheduled(match.kickoff), text: match.kickoff.formatted(date: .omitted, time: .shortened),
                                           accessibilityText: "Scheduled, \(match.kickoff.formatted(date: .abbreviated, time: .shortened))")
        case .halftime:
            return GameStatusPresentation(kind: .intermission, text: "HALF TIME", accessibilityText: "Half time")
        case .extraHalftime:
            return GameStatusPresentation(kind: .intermission, text: "HALF TIME (ET)", accessibilityText: "Half time, extra time")
        case .fullTime:
            return GameStatusPresentation(kind: .final, text: "FULL TIME", accessibilityText: "Full time")
        case .firstHalf, .secondHalf, .stoppageTime, .extraFirstHalf, .extraSecondHalf:
            let clock = match.clock?.display
            return GameStatusPresentation(kind: .live, text: clock.map { "LIVE · \($0)" } ?? "LIVE",
                                           accessibilityText: "Live" + (clock.map { ", \($0)" } ?? ""))
        case .penalties:
            return GameStatusPresentation(kind: .live, text: "PENALTIES", accessibilityText: "Penalty shootout")
        case .postponed: return GameStatusPresentation(kind: .other, text: "POSTPONED", accessibilityText: "Postponed")
        case .suspended: return GameStatusPresentation(kind: .other, text: "SUSPENDED", accessibilityText: "Suspended")
        case .cancelled: return GameStatusPresentation(kind: .other, text: "CANCELLED", accessibilityText: "Cancelled")
        case .delayed: return GameStatusPresentation(kind: .other, text: "DELAYED", accessibilityText: "Delayed")
        case .abandoned: return GameStatusPresentation(kind: .other, text: "ABANDONED", accessibilityText: "Abandoned")
        case .unknown(let raw): return GameStatusPresentation(kind: .other, text: raw.isEmpty ? "—" : raw.uppercased(), accessibilityText: raw)
        }
    }

    static func heroTeams(match: SoccerMatch, homeLogo: URL?, awayLogo: URL?) -> (away: GameHeroTeam, home: GameHeroTeam) {
        let awayScore = match.away.score, homeScore = match.home.score
        let awayLeading = awayScore != nil && homeScore != nil && awayScore! > homeScore!
        let homeLeading = awayScore != nil && homeScore != nil && homeScore! > awayScore!
        func metric(_ side: SoccerTeamMatchState) -> String? {
            side.redCards > 0 ? "\(side.redCards) RED CARD\(side.redCards == 1 ? "" : "S")" : nil
        }
        let away = GameHeroTeam(id: "away-\(match.away.team.id)", name: match.away.team.name, abbreviation: match.away.team.abbreviation,
                                 logo: awayLogo, score: awayScore.map(String.init), supportingMetric: metric(match.away), isLeading: awayLeading, teamID: match.away.team.id)
        let home = GameHeroTeam(id: "home-\(match.home.team.id)", name: match.home.team.name, abbreviation: match.home.team.abbreviation,
                                 logo: homeLogo, score: homeScore.map(String.init), supportingMetric: metric(match.home), isLeading: homeLeading, teamID: match.home.team.id)
        return (away, home)
    }

    // MARK: - Match events (goals & cards)

    /// Chronological goals and cards — the same incidents the Overview summary always
    /// showed, now rendered through the shared `EventTimeline`. Score is tallied
    /// locally since `SoccerMatchEvent` carries no score snapshot; `teamID` on a goal
    /// event is always the side credited in the scoreline (own goals included),
    /// matching how `EPLEventMapper` buckets its raw feed.
    static func timeline(events: [SoccerMatchEvent], match: SoccerMatch, directory: [String: SoccerPlayerReference]) -> [TimelineEvent] {
        let relevant = events
            .filter { [.goal, .ownGoal, .penaltyGoal, .yellowCard, .secondYellow, .redCard].contains($0.type) }
            .sorted { ($0.minute ?? 0, $0.ordinal) < ($1.minute ?? 0, $1.ordinal) }
        var awayTally = 0, homeTally = 0
        return relevant.map { event in
            let isHome = event.teamID == match.home.team.id
            let abbreviation = isHome ? match.home.team.abbreviation : match.away.team.abbreviation
            let name = event.playerID.flatMap { directory[$0]?.fullName } ?? "Unknown player"
            let minuteText = event.minute.map { "\($0)'" } ?? ""
            switch event.type {
            case .goal, .ownGoal, .penaltyGoal:
                if isHome { homeTally += 1 } else { awayTally += 1 }
                let detail: String? = event.type == .ownGoal ? "Own goal" : event.type == .penaltyGoal ? "Penalty" : nil
                let secondary = event.secondaryPlayerID.flatMap { directory[$0]?.fullName }.map { "Assist: \($0)" }
                return TimelineEvent(id: event.id, teamAbbreviation: abbreviation, teamLogo: nil,
                    scoreAfter: "\(awayTally)–\(homeTally)", periodText: minuteText, clockText: nil,
                    headline: name, detail: detail, secondary: secondary,
                    badges: [], headshot: nil, replayURL: nil, playerProviderID: nil)
            default:
                let badge: EventBadge = event.type == .yellowCard ? .yellowCard : .redCard
                let detail = event.type == .secondYellow ? "Second yellow card" : nil
                return TimelineEvent(id: event.id, teamAbbreviation: abbreviation, teamLogo: nil,
                    scoreAfter: nil, periodText: minuteText, clockText: nil,
                    headline: name, detail: detail, secondary: nil,
                    badges: [badge], headshot: nil, replayURL: nil, playerProviderID: nil)
            }
        }
    }

    // MARK: - Key stats

    static func keyStats(home: SoccerTeamMatchStats?, away: SoccerTeamMatchStats?, awayName: String, homeName: String) -> [ComparisonStat] {
        guard let home, let away else { return [] }
        var result: [ComparisonStat] = []
        func addCount(id: String, label: String, _ h: Double?, _ a: Double?, decimals: Int = 0) {
            guard let h, let a else { return }
            let awayText = decimals == 0 ? String(Int(a)) : String(format: "%.2f", a)
            let homeText = decimals == 0 ? String(Int(h)) : String(format: "%.2f", h)
            if let stat = ComparisonStat.parse(id: id, label: label, away: awayText, home: homeText, teamAwayName: awayName, teamHomeName: homeName) {
                result.append(stat)
            }
        }
        addCount(id: "xg", label: "xG", home.expectedGoals, away.expectedGoals, decimals: 2)
        if let h = home.possession, let a = away.possession,
           let stat = ComparisonStat.parse(id: "possession", label: "Possession", away: "\(Int(a.rounded()))%", home: "\(Int(h.rounded()))%", teamAwayName: awayName, teamHomeName: homeName) {
            result.append(stat)
        }
        addCount(id: "shots", label: "Shots", home.shots, away.shots)
        addCount(id: "shotsOnTarget", label: "Shots on Target", home.shotsOnTarget, away.shotsOnTarget)
        addCount(id: "bigChances", label: "Big Chances", home.bigChancesCreated, away.bigChancesCreated)
        addCount(id: "corners", label: "Corners", home.corners, away.corners)
        return result
    }
}
