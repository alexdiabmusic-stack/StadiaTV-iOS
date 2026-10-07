import Foundation

/// Pure builders turning NHL domain models (`HockeyGame`, `HockeyPlayEvent`, ...)
/// into the shared Game Detail presentation types. No SwiftUI dependency, so this
/// is unit-testable directly (see `NHLGamePresentationTests`).
nonisolated enum NHLGamePresentation {

    // MARK: - Hero

    static func heroStatus(game: HockeyGame) -> GameStatusPresentation {
        switch game.status {
        case .final:
            let isExtra = game.period.kind == .overtime || game.period.kind == .shootout
            let text = isExtra ? "FINAL/\(shortPeriod(game.period))" : "FINAL"
            return GameStatusPresentation(kind: .final, text: text,
                                           accessibilityText: isExtra ? "Final, \(game.period.label)" : "Final")
        case .live:
            if game.intermission {
                let text = "INT · \(shortPeriod(game.period))"
                return GameStatusPresentation(kind: .intermission, text: text, accessibilityText: "Intermission, \(game.period.label)")
            }
            let text = [shortPeriod(game.period), game.clock].compactMap { $0 }.joined(separator: " · ")
            let accessibility = "Live, \(game.period.label)" + (game.clock.map { ", \($0) remaining" } ?? "")
            return GameStatusPresentation(kind: .live, text: text, accessibilityText: accessibility)
        case .scheduled, .pregame:
            return GameStatusPresentation(kind: .scheduled(game.start), text: game.start.formatted(date: .omitted, time: .shortened),
                                           accessibilityText: "Scheduled, \(game.start.formatted(date: .abbreviated, time: .shortened))")
        default:
            return GameStatusPresentation(kind: .other, text: game.statusLabel, accessibilityText: game.statusLabel)
        }
    }

    static func heroTeams(game: HockeyGame) -> (away: GameHeroTeam, home: GameHeroTeam) {
        let awayScore = game.away.score, homeScore = game.home.score
        let awayLeading = awayScore != nil && homeScore != nil && awayScore! > homeScore!
        let homeLeading = awayScore != nil && homeScore != nil && homeScore! > awayScore!
        let away = GameHeroTeam(id: "away-\(game.away.id)", name: game.away.name, abbreviation: game.away.abbreviation,
                                 logo: game.away.logo, score: awayScore.map(String.init),
                                 supportingMetric: game.away.shots.map { "\($0) SHOTS" }, isLeading: awayLeading, teamID: String(game.away.id))
        let home = GameHeroTeam(id: "home-\(game.home.id)", name: game.home.name, abbreviation: game.home.abbreviation,
                                 logo: game.home.logo, score: homeScore.map(String.init),
                                 supportingMetric: game.home.shots.map { "\($0) SHOTS" }, isLeading: homeLeading, teamID: String(game.home.id))
        return (away, home)
    }

    private static func shortPeriod(_ period: HockeyPeriod) -> String {
        switch period.kind {
        case .overtime:
            let count = max(1, period.number - period.regulationPeriods)
            return count == 1 ? "OT" : "\(count)OT"
        case .shootout: return "SO"
        case .regulation:
            let labels = ["1ST", "2ND", "3RD"]
            return labels.indices.contains(period.number - 1) ? labels[period.number - 1] : "P\(period.number)"
        case .unknown: return period.number > 0 ? "P\(period.number)" : ""
        }
    }

    // MARK: - Scoring timeline

    /// Chronological order (oldest first) — `events`/`scoringSummary` already arrive oldest-first
    /// from the mapper; callers that need newest-first (e.g. a "most recent at top" feed) reverse it.
    static func timeline(events: [HockeyPlayEvent], game: HockeyGame?) -> [TimelineEvent] {
        events.filter { $0.eventType == .goal }.map { event in
            let team = [game?.away, game?.home].compactMap { $0 }.first { $0.id == event.teamID }
            let secondary = event.assists.isEmpty ? nil : event.assists.map(\.name).joined(separator: ", ")
            let scoreAfter: String? = {
                guard let a = event.awayScore, let h = event.homeScore else { return nil }
                return "\(a)–\(h)"
            }()
            return TimelineEvent(
                id: event.id,
                teamAbbreviation: team?.abbreviation ?? "",
                teamLogo: team?.logo,
                scoreAfter: scoreAfter,
                periodText: shortPeriod(event.period),
                clockText: event.timeInPeriod,
                headline: (event.primaryPlayer?.name).map { $0 == "Unknown player" ? "Goal" : $0 } ?? "Goal",
                detail: event.shotType.map(HockeyPlayDescriptionBuilder.humanize),
                secondary: secondary,
                badges: badges(for: event),
                headshot: event.primaryPlayer?.headshot,
                replayURL: event.videoURL,
                playerProviderID: event.primaryPlayer?.id
            )
        }
    }

    private static func badges(for event: HockeyPlayEvent) -> [EventBadge] {
        var result: [EventBadge] = []
        switch event.strength {
        case "Power-play goal": result.append(.powerPlay)
        case "Short-handed goal": result.append(.shortHanded)
        case "Empty-net goal": result.append(.emptyNet)
        default: break
        }
        if event.period.kind == .shootout { result.append(.shootout) }
        return result
    }

    // MARK: - Leaders

    /// NHL has no dedicated leaders endpoint — leaders are derived from the box score
    /// that's already fetched. Skaters with no points are dropped (no leader to show),
    /// so this can legitimately return fewer than 4 cards, or none at all.
    static func leaders(players: [HockeyPlayerGameStats], game: HockeyGame?) -> [LeaderCard] {
        guard let game else { return [] }
        func stat(_ row: HockeyPlayerGameStats, _ id: String) -> Int { Int(row.stats.first { $0.id == id }?.value ?? "") ?? 0 }
        func statText(_ row: HockeyPlayerGameStats, _ id: String) -> String? { row.stats.first { $0.id == id }?.value }
        func abbreviation(for teamID: Int) -> String { teamID == game.away.id ? game.away.abbreviation : game.home.abbreviation }

        func topSkater(teamID: Int) -> LeaderCard? {
            let skaters = players.filter { $0.teamID == teamID && $0.group != "Goalies" }
            let best = skaters.sorted { a, b in
                let ap = stat(a, "points"), bp = stat(b, "points")
                if ap != bp { return ap > bp }
                let ag = stat(a, "goals"), bg = stat(b, "goals")
                if ag != bg { return ag > bg }
                return stat(a, "sog") > stat(b, "sog")
            }.first
            guard let best, stat(best, "points") > 0 else { return nil }
            return LeaderCard(id: "skater-\(best.id)", name: best.player.name, teamAbbreviation: abbreviation(for: teamID),
                               headshot: best.player.headshot, statLine: "\(stat(best, "goals")) G · \(stat(best, "assists")) A",
                               role: nil, playerProviderID: best.player.id)
        }
        func topGoalie(teamID: Int) -> LeaderCard? {
            let goalies = players.filter { $0.teamID == teamID && $0.group == "Goalies" }
            guard let best = goalies.max(by: { stat($0, "shotsAgainst") < stat($1, "shotsAgainst") }), stat(best, "shotsAgainst") > 0 else { return nil }
            let line = ["\(stat(best, "saves")) SV", statText(best, "savePctg")].compactMap { $0 }.joined(separator: " · ")
            return LeaderCard(id: "goalie-\(best.id)", name: best.player.name, teamAbbreviation: abbreviation(for: teamID),
                               headshot: best.player.headshot, statLine: line, role: "GOALIE", playerProviderID: best.player.id)
        }
        return [topSkater(teamID: game.away.id), topSkater(teamID: game.home.id),
                topGoalie(teamID: game.away.id), topGoalie(teamID: game.home.id)].compactMap { $0 }
    }

    // MARK: - Key stats

    static func keyStats(teamStats: [HockeyTeamComparison], game: HockeyGame?) -> [ComparisonStat] {
        guard let game else { return [] }
        let order: [(id: String, lowerIsBetter: Bool)] = [
            ("sog", false), ("faceoffWinningPctg", false), ("powerPlay", false),
            ("hits", false), ("blockedShots", false), ("giveaways", true), ("takeaways", false)
        ]
        let byID = Dictionary(uniqueKeysWithValues: teamStats.map { ($0.id, $0) })
        return order.compactMap { entry -> ComparisonStat? in
            guard let raw = byID[entry.id] else { return nil }
            var awaySecondary: String?, homeSecondary: String?
            if entry.id == "powerPlay", let pct = byID["powerPlayPctg"] {
                awaySecondary = pct.away; homeSecondary = pct.home
            }
            return ComparisonStat.parse(id: raw.id, label: raw.label, away: raw.away, home: raw.home,
                                         awaySecondary: awaySecondary, homeSecondary: homeSecondary,
                                         lowerIsBetter: entry.lowerIsBetter, teamAwayName: game.away.name, teamHomeName: game.home.name)
        }
    }

    // MARK: - Game info

    static func gameInfo(game: HockeyGame?) -> [GameInfoItem] {
        guard let game else { return [] }
        var items: [GameInfoItem] = []
        if let venue = game.venue {
            items.append(GameInfoItem(id: "venue", icon: "mappin.and.ellipse", primary: venue, secondary: nil))
        }
        items.append(GameInfoItem(id: "date", icon: "calendar", primary: game.start.formatted(date: .abbreviated, time: .shortened), secondary: nil))
        if !game.broadcasts.isEmpty {
            items.append(GameInfoItem(id: "broadcast", icon: "tv", primary: game.broadcasts.joined(separator: " · "), secondary: nil))
        }
        return items
    }
}
