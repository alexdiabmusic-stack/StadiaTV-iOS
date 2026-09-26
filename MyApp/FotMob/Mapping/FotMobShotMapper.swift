import Foundation

/// Maps `content.shotmap.shots` into `[SoccerShot]`. Verified live 2026-09-24
/// against a full match (24 shots). Team identity is resolved by comparing
/// FotMob's own `teamId` against the already-known FotMob home-team id, then
/// translated to the canonical (official LaLiga) team id the caller supplies —
/// FotMob's numeric team id is never stored on the canonical `SoccerShot`.
nonisolated enum FotMobShotMapper {
    static func shots(_ raw: FotMobValue, matchID: String, fotmobHomeTeamID: String?, homeTeamID: String, awayTeamID: String) -> [SoccerShot] {
        raw["content"]["shotmap"]["shots"].array.compactMap { shot -> SoccerShot? in
            guard let id = shot["id"].string else { return nil }
            let teamID = shot["teamId"].string == fotmobHomeTeamID ? homeTeamID : awayTeamID
            let reference = SoccerPlayerReference(id: shot["playerId"].string ?? "", firstName: shot["firstName"].string, lastName: shot["lastName"].string)
            return SoccerShot(id: id, matchID: matchID, teamID: teamID, playerReference: reference, minute: shot["min"].int,
                x: shot["x"].double, y: shot["y"].double, expectedGoals: shot["expectedGoals"].double,
                outcome: outcome(shot["eventType"].string), bodyPart: shot["shotType"].string, situation: shot["situation"].string)
        }
    }

    private static func outcome(_ raw: String?) -> SoccerShotOutcome {
        switch raw {
        case "Goal": return .goal
        case "AttemptSaved": return .saved
        case "Miss": return .missed
        case "BlockedShot", "Block": return .blocked
        default: return .unknown(raw ?? "")
        }
    }
}
