import Foundation

/// Pure builders turning CFL domain models into the shared Game Detail presentation
/// types. No SwiftUI dependency. There's no "Scoring" timeline here — `echo.pims.cfl.ca`
/// never supplies down-by-down data (see `CFLLivePlayProvider`), so `game.plays` stays
/// empty and a scoring feed would just be fabricated; Overview instead leans on the
/// quarter score, this game's player lines, and season-to-date team stats, which are
/// all genuinely available.
nonisolated enum CFLGamePresentation {

    // MARK: - Hero

    static func heroStatus(game: CFLGameState) -> GameStatusPresentation {
        switch game.status {
        case .final:
            let text = game.isOvertime ? "FINAL/OT" : "FINAL"
            return GameStatusPresentation(kind: .final, text: text, accessibilityText: text)
        case .halftime:
            return GameStatusPresentation(kind: .intermission, text: "HALFTIME", accessibilityText: "Halftime")
        case .live:
            var text = [game.statusText, game.clock].compactMap { $0 }.joined(separator: " · ")
            if game.isOvertime { text = text.isEmpty ? "OT" : "\(text) · OT" }
            return GameStatusPresentation(kind: .live, text: text.isEmpty ? "LIVE" : text,
                                           accessibilityText: text.isEmpty ? "Live" : "Live, \(text)")
        case .scheduled, .pregame:
            return GameStatusPresentation(kind: .scheduled(game.start), text: game.start.formatted(date: .omitted, time: .shortened),
                                           accessibilityText: "Scheduled, \(game.start.formatted(date: .abbreviated, time: .shortened))")
        default:
            return GameStatusPresentation(kind: .other, text: game.statusText.uppercased(), accessibilityText: game.statusText)
        }
    }

    static func heroTeams(game: CFLGameState) -> (away: GameHeroTeam, home: GameHeroTeam) {
        let awayScore = game.away.score, homeScore = game.home.score
        let awayLeading = awayScore != nil && homeScore != nil && awayScore! > homeScore!
        let homeLeading = awayScore != nil && homeScore != nil && homeScore! > awayScore!
        let away = GameHeroTeam(id: "away-\(game.away.id)", name: game.away.name, abbreviation: game.away.abbreviation,
                                 logo: game.away.logo, score: awayScore.map(String.init), supportingMetric: nil, isLeading: awayLeading, teamID: game.away.id)
        let home = GameHeroTeam(id: "home-\(game.home.id)", name: game.home.name, abbreviation: game.home.abbreviation,
                                 logo: game.home.logo, score: homeScore.map(String.init), supportingMetric: nil, isLeading: homeLeading, teamID: game.home.id)
        return (away, home)
    }

    // MARK: - Leaders

    /// Best passer and best rusher per team, from this game's player lines (already
    /// fetched for Box Score). Dropped when a team has no yardage in that category,
    /// never shown as a fabricated zero.
    static func leaders(players: [CFLPlayerGameLine], game: CFLGameState) -> [LeaderCard] {
        func abbreviation(for teamID: String) -> String { teamID == game.away.id ? game.away.abbreviation : game.home.abbreviation }
        func topPasser(teamID: String) -> LeaderCard? {
            let candidates = players.filter { $0.teamID == teamID && ($0.stats["passesSucceededYards"] ?? 0) > 0 }
            guard let best = candidates.max(by: { ($0.stats["passesSucceededYards"] ?? 0) < ($1.stats["passesSucceededYards"] ?? 0) }) else { return nil }
            let line = "\(Int(best.stats["passesSucceeded"] ?? 0))/\(Int(best.stats["passesAttempted"] ?? 0)) · \(Int(best.stats["passesSucceededYards"] ?? 0)) YDS"
            return LeaderCard(id: "pass-\(best.id)", name: best.name, teamAbbreviation: abbreviation(for: teamID), headshot: nil, statLine: line, role: "PASSING", playerProviderID: nil)
        }
        func topRusher(teamID: String) -> LeaderCard? {
            let candidates = players.filter { $0.teamID == teamID && ($0.stats["rushingYards"] ?? 0) > 0 }
            guard let best = candidates.max(by: { ($0.stats["rushingYards"] ?? 0) < ($1.stats["rushingYards"] ?? 0) }) else { return nil }
            let line = "\(Int(best.stats["rushes"] ?? 0)) CAR · \(Int(best.stats["rushingYards"] ?? 0)) YDS"
            return LeaderCard(id: "rush-\(best.id)", name: best.name, teamAbbreviation: abbreviation(for: teamID), headshot: nil, statLine: line, role: "RUSHING", playerProviderID: nil)
        }
        return [topPasser(teamID: game.away.id), topPasser(teamID: game.home.id),
                topRusher(teamID: game.away.id), topRusher(teamID: game.home.id)].compactMap { $0 }
    }

    // MARK: - Key stats

    /// `home`/`away` are season-to-date totals — the same source already shown under
    /// the Stats tab (`/api/stats/teamrecords` has no per-game breakdown) — so this is
    /// a season-form comparison, not a this-game box score.
    static func keyStats(home: CFLValue, away: CFLValue, awayName: String, homeName: String) -> [ComparisonStat] {
        CFLTeamStatsMapper.rows(home: home, away: away).primary.compactMap { row in
            let id = row.title.lowercased().replacingOccurrences(of: " ", with: "-")
            return ComparisonStat.parse(id: id, label: row.title, away: row.away, home: row.home, teamAwayName: awayName, teamHomeName: homeName)
        }
    }

    // MARK: - Game info

    static func gameInfo(game: CFLGameState) -> [GameInfoItem] {
        var items: [GameInfoItem] = []
        if let venue = game.venue { items.append(GameInfoItem(id: "venue", icon: "mappin.and.ellipse", primary: venue, secondary: nil)) }
        items.append(GameInfoItem(id: "date", icon: "calendar", primary: game.start.formatted(date: .abbreviated, time: .shortened), secondary: nil))
        if !game.broadcasts.isEmpty { items.append(GameInfoItem(id: "broadcast", icon: "tv", primary: game.broadcasts.joined(separator: " · "), secondary: nil)) }
        return items
    }
}
