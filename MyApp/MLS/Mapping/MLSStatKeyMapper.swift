import Foundation

/// Maps `/statistics/clubs/matches/{id}`'s `team_statistics` entry (~150 raw Sportec
/// keys per side, confirmed live 2026-09-23) into the canonical `SoccerTeamMatchStats`
/// shape. Views never reference a Sportec key directly — only canonical fields,
/// `nil` (never a fake `0`) when a metric wasn't supplied. `tackling_games_air_*` is
/// genuinely aerial-duel data despite the "tackling" name (Sportec's own naming),
/// mapped to `aerialDuelsWon` rather than `tackles` — there is no confirmed
/// ground-tackle count in this payload, so `tackles`/`tacklesWon`/`duelsWon` stay
/// nil rather than guess.
nonisolated enum MLSStatKeyMapper {
    static func stats(_ raw: MLSValue, teamID: String) -> SoccerTeamMatchStats {
        var rawStats: [String: Double] = [:]
        for (key, value) in raw.object { if let double = value.double { rawStats[key] = double } }

        let zones = raw["attacking_zones"].array.compactMap { zone -> SoccerAttackingZone? in
            guard let id = zone["zone_id"].string, let entries = zone["entries"].int else { return nil }
            return SoccerAttackingZone(zoneID: id, entries: entries, ratio: zone["ratio"].double ?? 0)
        }

        return SoccerTeamMatchStats(teamID: teamID,
            possession: raw["possession_ratio"].double,
            expectedGoals: raw["xG"].double,
            expectedGoalsOnTarget: nil,   // unconfirmed — not present in the captured payload
            shots: raw["shots_at_goal_sum"].double,
            shotsOnTarget: raw["shots_on_target"].double,
            shotsOffTarget: raw["shots_at_goal_wide"].double,
            blockedShots: raw["shots_at_goal_blocked"].double,
            bigChancesCreated: nil,      // unconfirmed
            bigChancesMissed: nil,       // unconfirmed
            corners: raw["corner_kicks_sum"].double,
            passes: raw["passes_sum"].double,
            passesCompleted: raw["passes_successful_sum"].double,
            crosses: raw["crosses_sum"].double,
            tackles: nil,                // unconfirmed — see doc comment
            tacklesWon: nil,             // unconfirmed
            interceptions: raw["interceptions_sum"].double,
            clearances: raw["defensive_clearances"].double,
            duelsWon: nil,               // unconfirmed
            aerialDuelsWon: raw["tackling_games_air_won"].double,
            touchesInOppositionBox: nil, // unconfirmed
            finalThirdEntries: raw["total_attacking_zone_entries"].double,
            fouls: raw["fouls_sum"].double,
            offsides: raw["offsides"].double,
            saves: raw["goalkeeper_saves"].double,
            yellowCards: raw["cards_yellow"].double,
            redCards: raw["cards_red"].double,
            attackingZones: zones,
            distanceCovered: raw["distance_covered"].double,
            ballRecoveryTime: raw["advanced_stats"]["ball_recovery_time"].double,
            raw: rawStats)
    }
}
