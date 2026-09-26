import Foundation

/// Maps `/matches/{id}/key_events` into `SoccerMatchEvent`. Confirmed live
/// (2026-09-23) top-level `type` buckets: `kick_off`, `shot_at_goals`, `cards`,
/// `substitutions`, `corner_kicks`, `offsides`, `fouls`, `final_whistle` — no
/// shootout/own-goal match was available to observe, so those branches are
/// best-effort pattern matches on the same fields, clearly commented as such, and
/// still fall through to `.unknown(type)` rather than crashing on a genuinely new
/// bucket. `kick_off`/`final_whistle` are period markers with no team of their own
/// and are intentionally not emitted as timeline events (the Timeline groups by
/// half using each event's own `period` field instead).
nonisolated enum MLSEventMapper {
    static func events(_ raw: MLSValue, matchID: String, playerTeamMap: [String: String]) -> [SoccerMatchEvent] {
        var result: [SoccerMatchEvent] = []
        for (ordinal, wrapper) in raw["events"].array.enumerated() {
            guard let type = wrapper["type"].string else { continue }
            let event = wrapper["event"]
            guard let eventID = event["event_id"].string ?? event["event_id"].int.map(String.init) else { continue }
            let period = event["game_section"].string
            let minute = MLSDate.baseMinute(event["minute_of_play"].string)
            let timestamp = MLSDate.parseISO8601(event["event_time"].string)
            let id = "\(matchID)|\(eventID)"

            switch type {
            case "shot_at_goals":
                guard let playerID = event["player_id"].string else { continue }
                let teamID = playerTeamMap[playerID] ?? ""
                let assistID = event["assist_player_id"].string
                let shotResult = event["shot_result"].string ?? ""
                let isPenalty = (event["origin"].string ?? "").localizedCaseInsensitiveContains("penalt")
                let eventType: SoccerEventType
                switch shotResult {
                case "SuccessfulShot": eventType = isPenalty ? .penaltyGoal : .goal
                case "SavedShot": eventType = .shotSaved
                case "BlockedShot": eventType = .shotBlocked
                case "ShotWide": eventType = .shotOffTarget
                default: eventType = .unknown("shot_at_goals:\(shotResult)")  // unconfirmed: post/crossbar/own-goal shot_result spellings
                }
                result.append(SoccerMatchEvent(id: id, matchID: matchID, teamID: teamID, type: eventType, period: period, minute: minute,
                    timestamp: timestamp, playerID: playerID, secondaryPlayerID: assistID, ordinal: ordinal))

            case "cards":
                guard let playerID = event["player_id"].string, let teamID = event["team_id"].string else { continue }
                let color = (event["card_color"].string ?? "").lowercased()
                let eventType: SoccerEventType
                if color.contains("second") || color.contains("double") { eventType = .secondYellow }  // unconfirmed spelling — no second yellow observed live
                else if color.contains("red") { eventType = .redCard }
                else if color.contains("yellow") { eventType = .yellowCard }
                else { eventType = .unknown("cards:\(color)") }
                result.append(SoccerMatchEvent(id: id, matchID: matchID, teamID: teamID, type: eventType, period: period, minute: minute,
                    timestamp: timestamp, playerID: playerID, secondaryPlayerID: nil, ordinal: ordinal))

            case "substitutions":
                guard let teamID = event["team_id"].string else { continue }
                let playerIn = MLSMatchMapper.playerReference(event, idKey: "player_in_id", firstKey: "player_in_first_name", lastKey: "player_in_last_name")
                let playerOut = MLSMatchMapper.playerReference(event, idKey: "player_out_id", firstKey: "player_out_first_name", lastKey: "player_out_last_name")
                result.append(SoccerMatchEvent(id: id, matchID: matchID, teamID: teamID, type: .substitution, period: period, minute: minute,
                    timestamp: timestamp, playerID: playerIn?.id, secondaryPlayerID: playerOut?.id, ordinal: ordinal))

            case "corner_kicks":
                guard let teamID = event["team_id"].string else { continue }
                result.append(SoccerMatchEvent(id: id, matchID: matchID, teamID: teamID, type: .corner, period: period, minute: minute,
                    timestamp: timestamp, playerID: event["player_id"].string, secondaryPlayerID: nil, ordinal: ordinal))

            case "offsides":
                guard let teamID = event["team_id"].string else { continue }
                result.append(SoccerMatchEvent(id: id, matchID: matchID, teamID: teamID, type: .offside, period: period, minute: minute,
                    timestamp: timestamp, playerID: event["player_id"].string, secondaryPlayerID: nil, ordinal: ordinal))

            case "fouls":
                // Attributed to the fouling side's team, since a timeline entry
                // reads as "this team committed a foul", mirroring how cards/corners
                // are attributed to the acting team rather than the affected one.
                guard let teamID = event["team_fouler_id"].string else { continue }
                result.append(SoccerMatchEvent(id: id, matchID: matchID, teamID: teamID, type: .foul, period: period, minute: minute,
                    timestamp: timestamp, playerID: event["fouler_id"].string, secondaryPlayerID: event["fouled_id"].string, ordinal: ordinal))

            case "kick_off", "final_whistle":
                continue  // period markers, not timeline-worthy events (see doc comment)

            default:
                // Never observed live (no own goal, VAR review, or penalty-won/lost
                // event occurred in the captured match) — preserved rather than dropped.
                if let teamID = event["team_id"].string {
                    result.append(SoccerMatchEvent(id: id, matchID: matchID, teamID: teamID, type: .unknown(type), period: period, minute: minute,
                        timestamp: timestamp, playerID: event["player_id"].string, secondaryPlayerID: nil, ordinal: ordinal))
                }
            }
        }
        return result
    }

    /// Every `key_events` entry inlines the name of every player it references
    /// (scorer, assister, carded/fouling/fouled/subbed player) — unlike EPL, which
    /// needs a separate batch player-lookup call, this hydrates the player
    /// directory straight from the same response already fetched for the timeline.
    static func playerDirectory(fromKeyEvents raw: MLSValue) -> [String: SoccerPlayerReference] {
        var directory: [String: SoccerPlayerReference] = [:]
        let idFirstLastTriples: [(String, String, String)] = [
            ("player_id", "player_first_name", "player_last_name"),
            ("assist_player_id", "assist_player_first_name", "assist_player_last_name"),
            ("second_assist_player_id", "second_assist_player_first_name", "second_assist_player_last_name"),
            ("player_in_id", "player_in_first_name", "player_in_last_name"),
            ("player_out_id", "player_out_first_name", "player_out_last_name"),
            ("fouler_id", "fouler_first_name", "fouler_last_name"),
            ("fouled_id", "fouled_first_name", "fouled_last_name"),
        ]
        for wrapper in raw["events"].array {
            let event = wrapper["event"]
            for (idKey, firstKey, lastKey) in idFirstLastTriples {
                if let reference = MLSMatchMapper.playerReference(event, idKey: idKey, firstKey: firstKey, lastKey: lastKey) {
                    directory[reference.id] = reference
                }
            }
        }
        return directory
    }
}
