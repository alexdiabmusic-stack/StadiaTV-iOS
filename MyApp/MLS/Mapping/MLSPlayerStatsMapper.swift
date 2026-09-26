import Foundation

/// Maps `/statistics/players/matches/{id}`'s `player_statistics` entries into
/// `[SoccerPlayerMatchStats]`. Confirmed live 2026-09-23 against a real player
/// (Messi, MLS-OBJ-000396) — fields with no confirmed equivalent in this payload
/// (tackles, interceptions, duels, pass accuracy, saves) stay nil rather than guess;
/// `raw` preserves every supplied numeric field regardless.
nonisolated enum MLSPlayerStatsMapper {
    static func stats(_ raw: MLSValue, matchID: String) -> [SoccerPlayerMatchStats] {
        // `/statistics/players/matches/{id}` nests the array one level under
        // `match_statistics` (confirmed live) — not at the response's top level.
        raw["match_statistics"]["player_statistics"].array.compactMap { entry -> SoccerPlayerMatchStats? in
            guard let playerID = entry["player_id"].string, let teamID = entry["team_id"].string else { return nil }
            var rawStats: [String: Double] = [:]
            for (key, value) in entry.object { if let double = value.double { rawStats[key] = double } }
            return SoccerPlayerMatchStats(matchID: matchID, playerID: playerID, teamID: teamID,
                minutesPlayed: entry["normalized_player_minutes"].double,
                goals: entry["goals"].double,
                assists: entry["assists"].double,
                shots: entry["shots_at_goal_sum"].double,
                shotsOnTarget: nil,          // unconfirmed on this payload
                passesCompleted: entry["passes_successful_sum"].double,
                passAccuracy: nil,           // unconfirmed — no ratio field observed at player scope
                tackles: nil,                // unconfirmed
                interceptions: nil,          // unconfirmed
                duelsWon: nil,               // unconfirmed
                foulsCommitted: entry["fouls_sum"].double,
                yellowCards: entry["cards_yellow"].double,
                redCards: entry["cards_red"].double,
                saves: nil,                  // unconfirmed — not observed on a goalkeeper row
                raw: rawStats)
        }
    }
}
