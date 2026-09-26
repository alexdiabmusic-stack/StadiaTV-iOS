import Foundation

/// Maps `/v3/matches/{id}/stats` (~180 raw Opta keys per side) into the canonical
/// `SoccerTeamMatchStats` shape. Views never reference an Opta key string directly —
/// they only see canonical fields, which are `nil` (never a fake `0`) when the
/// provider didn't supply that metric for this match. Keys marked "unconfirmed" were
/// not directly observed in the live probe (2026-09-23) and are best-effort guesses
/// at standard Opta naming; a wrong guess just leaves that field `nil`; alternate
/// spellings can be added here without touching any view.
nonisolated enum EPLStatKeyMapper {
    static func stats(_ raw: EPLValue, teamID: String) -> SoccerTeamMatchStats {
        var rawStats: [String: Double] = [:]
        for (key, value) in raw.object { if let double = value.double { rawStats[key] = double } }
        func v(_ keys: String...) -> Double? { keys.lazy.compactMap { rawStats[$0] }.first }

        return SoccerTeamMatchStats(teamID: teamID,
            possession: v("possessionPercentage"),
            expectedGoals: v("expectedGoals"),
            expectedGoalsOnTarget: v("expectedGoalsOnTarget"),
            shots: v("totalScoringAtt"),
            shotsOnTarget: v("ontargetScoringAtt"),
            shotsOffTarget: v("shotOffTarget", "shotsOffTarget"),                 // unconfirmed spelling
            blockedShots: v("blockedScoringAtt", "blockedShots"),                 // unconfirmed spelling
            bigChancesCreated: v("bigChanceCreated"),
            bigChancesMissed: v("bigChanceMissed"),
            corners: v("cornerTaken"),
            passes: v("totalPass"),
            passesCompleted: v("accuratePass"),
            crosses: v("totalCross"),
            tackles: v("totalTackle"),
            tacklesWon: v("wonTackle"),
            interceptions: v("interception"),
            clearances: v("totalClearance"),
            duelsWon: v("duelWon"),
            aerialDuelsWon: v("aerialWon"),
            touchesInOppositionBox: v("touchesInOppBox"),
            finalThirdEntries: v("finalThirdEntries"),
            fouls: v("fkFoulLost"),
            offsides: v("totalOffside"),
            saves: v("saves"),
            yellowCards: v("yellowCard"),
            redCards: v("redCard"),
            raw: rawStats)
    }
}
