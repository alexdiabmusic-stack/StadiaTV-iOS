import Foundation

/// Maps `content.stats.Periods.All.stats` (a list of titled sections, each holding
/// its own `{title, key, stats:[home,away]}` rows) into canonical
/// `SoccerTeamMatchStats`, flattened across every section. Every key below was
/// directly observed live 2026-09-24 against one match — see LALIGA-INTEGRATION.md
/// for the full captured key list, including which canonical fields have no
/// matching FotMob key (`tacklesWon`, `finalThirdEntries` — left `nil`, never
/// guessed). Views never reference a FotMob key string directly (Step 22) — only
/// these canonical fields.
nonisolated enum FotMobStatsMapper {
    static func stats(_ raw: FotMobValue, homeTeamID: String, awayTeamID: String) -> (home: SoccerTeamMatchStats, away: SoccerTeamMatchStats) {
        var byKey: [String: (Double?, Double?)] = [:]
        var rawHome: [String: Double] = [:]
        var rawAway: [String: Double] = [:]
        for section in raw["content"]["stats"]["Periods"]["All"]["stats"].array {
            for row in section["stats"].array {
                guard let key = row["key"].string else { continue }
                let values = row["stats"].array
                guard values.count == 2 else { continue }
                let home = values[0].leadingNumber, away = values[1].leadingNumber
                if home == nil && away == nil { continue } // section-header duplicate rows carry [null, null]
                byKey[key] = (home, away)
                if let home { rawHome[key] = home }
                if let away { rawAway[key] = away }
            }
        }
        func side(_ isHome: Bool, teamID: String) -> SoccerTeamMatchStats {
            func pick(_ key: String) -> Double? { let pair = byKey[key] ?? (nil, nil); return isHome ? pair.0 : pair.1 }
            return SoccerTeamMatchStats(teamID: teamID,
                possession: pick("BallPossesion"),
                expectedGoals: pick("expected_goals"),
                expectedGoalsOnTarget: pick("expected_goals_on_target"),
                shots: pick("total_shots"),
                shotsOnTarget: pick("ShotsOnTarget"),
                shotsOffTarget: pick("ShotsOffTarget"),
                blockedShots: pick("blocked_shots"),
                bigChancesCreated: pick("big_chance"),
                bigChancesMissed: pick("big_chance_missed_title"),
                corners: pick("corners"),
                passes: pick("passes"),
                passesCompleted: pick("accurate_passes"),
                crosses: pick("accurate_crosses"), // accurate count only — FotMob has no separate "attempted crosses" key
                tackles: pick("matchstats.headers.tackles"),
                tacklesWon: nil,
                interceptions: pick("interceptions"),
                clearances: pick("clearances"),
                duelsWon: pick("duel_won"),
                aerialDuelsWon: pick("aerials_won"),
                touchesInOppositionBox: pick("touches_opp_box"),
                finalThirdEntries: nil,
                fouls: pick("fouls"),
                offsides: pick("Offsides"),
                saves: pick("keeper_saves"),
                yellowCards: pick("yellow_cards"),
                redCards: pick("red_cards"),
                raw: isHome ? rawHome : rawAway)
        }
        return (side(true, teamID: homeTeamID), side(false, teamID: awayTeamID))
    }
}
