import Foundation

/// Maps `/matches/{id}/key_events?event=penalties` into `SoccerPenaltyShootout`.
///
/// **Unverified against real data.** No MLS playoff/shootout match was available
/// during this integration (2026-09-23) to capture a real response — the route and
/// its query contract were confirmed live (it returns `{"events":[],"match_info":
/// {...}}` for a match with no shootout), but the per-kick field names below are a
/// best-effort guess following the same shape as every other `key_events` bucket
/// (`event_id`, `event_time`, `minute_of_play`, `game_section`, `player_id`,
/// `player_first_name`, `player_last_name`, `team_id`), with several candidate field
/// names tried for the outcome since the real key is unknown. Ship this disclosed as
/// a gap, not a confirmed feature — see MLS-INTEGRATION.md.
nonisolated enum MLSShootoutMapper {
    static func shootout(_ raw: MLSValue, matchID: String, homeTeamID: String, awayTeamID: String) -> SoccerPenaltyShootout? {
        let events = raw["events"].array
        guard !events.isEmpty else { return nil }
        var kicks: [SoccerPenaltyKick] = []
        for (index, wrapper) in events.enumerated() {
            let event = wrapper["event"]
            guard let teamID = event["team_id"].string, let reference = MLSMatchMapper.playerReference(event) else { continue }
            let scored = event["scored"].bool ?? event["penalty_result"].string.map { ["scored", "goal", "success"].contains($0.lowercased()) }
                ?? event["outcome"].string.map { ["scored", "goal", "success"].contains($0.lowercased()) } ?? false
            kicks.append(SoccerPenaltyKick(id: "\(matchID)|\(event["event_id"].string ?? String(index))", teamID: teamID,
                playerReference: reference, scored: scored, sequence: index + 1))
        }
        guard !kicks.isEmpty else { return nil }
        let homeScore = kicks.filter { $0.teamID == homeTeamID && $0.scored }.count
        let awayScore = kicks.filter { $0.teamID == awayTeamID && $0.scored }.count
        return SoccerPenaltyShootout(homeTeamID: homeTeamID, awayTeamID: awayTeamID, kicks: kicks, homeScore: homeScore, awayScore: awayScore, isComplete: true)
    }
}
