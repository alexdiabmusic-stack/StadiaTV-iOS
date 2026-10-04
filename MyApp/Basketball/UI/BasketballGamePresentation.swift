import Foundation

/// Pure builders turning Basketball domain models into the shared Game Detail
/// presentation types. Provider-agnostic (NBA and WNBA both route through
/// `BasketballGameCenterView`), no SwiftUI dependency.
nonisolated enum BasketballGamePresentation {

    // MARK: - Hero

    static func heroStatus(game: BasketballGame) -> GameStatusPresentation {
        switch game.status {
        case .final:
            return GameStatusPresentation(kind: .final, text: game.finalLabel,
                                           accessibilityText: game.isOvertime ? "Final, \(game.periodLabel)" : "Final")
        case .halftime:
            return GameStatusPresentation(kind: .intermission, text: "HALFTIME", accessibilityText: "Halftime")
        case .live:
            let clock = game.gameClock.map { NBADuration.clockText(seconds: $0) }
            let text = [game.periodLabel, clock].compactMap { $0 }.joined(separator: " · ")
            let accessibility = "Live, \(game.periodLabel)" + (clock.map { ", \($0) remaining" } ?? "")
            return GameStatusPresentation(kind: .live, text: text, accessibilityText: accessibility)
        case .scheduled, .pregame, .delayed:
            return GameStatusPresentation(kind: .scheduled(game.start), text: game.start.formatted(date: .omitted, time: .shortened),
                                           accessibilityText: "Scheduled, \(game.start.formatted(date: .abbreviated, time: .shortened))")
        default:
            return GameStatusPresentation(kind: .other, text: game.statusText, accessibilityText: game.statusText)
        }
    }

    static func heroTeams(game: BasketballGame) -> (away: GameHeroTeam, home: GameHeroTeam) {
        let awayScore = game.away.score, homeScore = game.home.score
        let awayLeading = awayScore != nil && homeScore != nil && awayScore! > homeScore!
        let homeLeading = awayScore != nil && homeScore != nil && homeScore! > awayScore!
        let awayMetric = game.status == .scheduled || game.status == .pregame ? game.away.record : nil
        let homeMetric = game.status == .scheduled || game.status == .pregame ? game.home.record : nil
        let away = GameHeroTeam(id: "away-\(game.away.id)", name: game.away.displayName, abbreviation: game.away.tricode,
                                 logo: game.away.logo, score: awayScore.map(String.init), supportingMetric: awayMetric,
                                 isLeading: awayLeading, teamID: String(game.away.id))
        let home = GameHeroTeam(id: "home-\(game.home.id)", name: game.home.displayName, abbreviation: game.home.tricode,
                                 logo: game.home.logo, score: homeScore.map(String.init), supportingMetric: homeMetric,
                                 isLeading: homeLeading, teamID: String(game.home.id))
        return (away, home)
    }

    // MARK: - Scoring timeline (lead changes & ties)

    /// Basketball has far too many baskets to list individually — this surfaces the moments
    /// that actually changed the game (a new leader, or a tie), capped at the most recent 6.
    static func leadChangeTimeline(plays: [NBAPlayEvent], game: BasketballGame?) -> [TimelineEvent] {
        guard let game else { return [] }
        enum Leader: Equatable { case away, home, tied }
        var previous: Leader?
        var events: [TimelineEvent] = []
        for play in NBAPlayEvent.sorted(plays) {
            guard let scoreAway = play.scoreAway, let scoreHome = play.scoreHome else { continue }
            let current: Leader = scoreAway == scoreHome ? .tied : (scoreAway > scoreHome ? .away : .home)
            if let previous, previous != current {
                let headline: String
                let teamAbbreviation: String
                let teamLogo: URL?
                switch current {
                case .tied:
                    headline = "Game tied"
                    teamAbbreviation = ""
                    teamLogo = nil
                case .away:
                    headline = "\(game.away.tricode) takes the lead"
                    teamAbbreviation = game.away.tricode
                    teamLogo = game.away.logo
                case .home:
                    headline = "\(game.home.tricode) takes the lead"
                    teamAbbreviation = game.home.tricode
                    teamLogo = game.home.logo
                }
                events.append(TimelineEvent(
                    id: play.id, teamAbbreviation: teamAbbreviation, teamLogo: teamLogo,
                    scoreAfter: "\(scoreAway)–\(scoreHome)", periodText: NBADuration.periodLabel(play.period, regulation: game.regulationPeriods),
                    clockText: play.clockText, headline: headline, detail: play.title, secondary: play.subtitle,
                    badges: [], headshot: nil, replayURL: nil, playerProviderID: play.personID
                ))
            }
            previous = current
        }
        return Array(events.suffix(6))
    }

    // MARK: - Leaders

    /// Prefers each team's combined `homeLeader`/`awayLeader` (one player, several stats —
    /// the classic "game leader" line) over the per-category `homeLeaders`/`awayLeaders`
    /// breakdown, since a single multi-stat player is what the leader card is designed to show.
    static func leaders(snapshot: BasketballGameSnapshot) -> [LeaderCard] {
        guard let game = snapshot.game else { return [] }
        func card(side: BasketballTeam, teamLeaders: NBATeamGameLeaders?, fallback: NBAGameLeaderLine?) -> LeaderCard? {
            if let fallback, let personID = fallback.personID, let name = fallback.name {
                let line = [fallback.points.map { "\($0) PTS" }, fallback.rebounds.map { "\($0) REB" }, fallback.assists.map { "\($0) AST" }]
                    .compactMap { $0 }.joined(separator: " · ")
                guard !line.isEmpty else { return nil }
                return LeaderCard(id: "leader-\(personID)", name: name, teamAbbreviation: side.tricode, headshot: nil, statLine: line, role: nil, playerProviderID: personID)
            }
            if let points = teamLeaders?.points {
                return LeaderCard(id: "leader-\(points.personID)", name: points.name, teamAbbreviation: side.tricode, headshot: nil,
                                   statLine: "\(points.value) PTS", role: nil, playerProviderID: points.personID)
            }
            return nil
        }
        return [card(side: game.away, teamLeaders: snapshot.awayLeaders, fallback: game.awayLeader),
                card(side: game.home, teamLeaders: snapshot.homeLeaders, fallback: game.homeLeader)].compactMap { $0 }
    }

    // MARK: - Key stats

    static func keyStats(awayStats: NBATeamStatLine?, homeStats: NBATeamStatLine?, awayName: String, homeName: String) -> [ComparisonStat] {
        guard let awayStats, let homeStats else { return [] }
        var result: [ComparisonStat] = []
        func addPercent(id: String, label: String) {
            guard let a = awayStats.stat(id), let h = homeStats.stat(id) else { return }
            let away = String(format: "%.1f%%", a * 100), home = String(format: "%.1f%%", h * 100)
            if let stat = ComparisonStat.parse(id: id, label: label, away: away, home: home, teamAwayName: awayName, teamHomeName: homeName) {
                result.append(stat)
            }
        }
        func addCount(id: String, label: String, lowerIsBetter: Bool = false) {
            guard let a = awayStats.stat(id), let h = homeStats.stat(id) else { return }
            if let stat = ComparisonStat.parse(id: id, label: label, away: String(Int(a)), home: String(Int(h)),
                                                lowerIsBetter: lowerIsBetter, teamAwayName: awayName, teamHomeName: homeName) {
                result.append(stat)
            }
        }
        addPercent(id: "fieldGoalsPercentage", label: "FG%")
        addPercent(id: "threePointersPercentage", label: "3PT%")
        addCount(id: "reboundsTotal", label: "Rebounds")
        addCount(id: "assists", label: "Assists")
        addCount(id: "turnovers", label: "Turnovers", lowerIsBetter: true)
        addCount(id: "pointsInThePaint", label: "Points in Paint")
        return result
    }

    // MARK: - Game info

    static func gameInfo(game: BasketballGame?) -> [GameInfoItem] {
        guard let game else { return [] }
        var items: [GameInfoItem] = []
        if let arena = game.arena, !arena.isEmpty {
            let cityState = [arena.city, arena.state].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            items.append(GameInfoItem(id: "venue", icon: "mappin.and.ellipse", primary: arena.name ?? "Venue", secondary: cityState.isEmpty ? nil : cityState))
        }
        items.append(GameInfoItem(id: "date", icon: "calendar", primary: game.start.formatted(date: .abbreviated, time: .shortened), secondary: nil))
        if let series = game.seriesText {
            items.append(GameInfoItem(id: "series", icon: "repeat", primary: series, secondary: nil))
        }
        if !game.broadcasts.isEmpty {
            items.append(GameInfoItem(id: "broadcast", icon: "tv", primary: game.broadcasts.joined(separator: " · "), secondary: nil))
        }
        return items
    }
}
