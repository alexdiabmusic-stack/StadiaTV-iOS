import Foundation

/// Maps `content.matchFacts.events.events` into `[SoccerMatchEvent]`. Verified
/// live 2026-09-24 against a full finished match — every observed `type` (`Card`,
/// `Goal`, `Substitution`, `Half`, `AddedTime`, `Comment`) is handled explicitly;
/// `AddedTime`/`Comment` carry no real incident (verified: blank player name, no
/// score change) and are dropped rather than surfaced as a timeline row, mirroring
/// MLS's precedent of skipping pure period markers — never silently dropping a
/// genuine incident type, only these two confirmed-empty ones. Team identity
/// always comes from the event's own `isHome` flag mapped onto the already-known
/// official team IDs — never FotMob's own numeric team id, a different ID space.
nonisolated enum FotMobEventMapper {
    static func events(_ raw: FotMobValue, matchID: String, homeTeamID: String, awayTeamID: String) -> [SoccerMatchEvent] {
        raw["content"]["matchFacts"]["events"]["events"].array.enumerated().compactMap { ordinal, entry in
            event(entry, ordinal: ordinal, matchID: matchID, homeTeamID: homeTeamID, awayTeamID: awayTeamID)
        }
    }

    private static func event(_ raw: FotMobValue, ordinal: Int, matchID: String, homeTeamID: String, awayTeamID: String) -> SoccerMatchEvent? {
        let rawType = raw["type"].string ?? ""
        let teamID = (raw["isHome"].bool ?? true) ? homeTeamID : awayTeamID
        let minute = raw["time"].int

        // VAR takes priority over the base type when the payload actually reports a
        // review — never observed live (every sample so far has `VAR: null`), so
        // this is inferred from the field's mere presence, not a confirmed shape.
        if raw["VAR"] != .null {
            return SoccerMatchEvent(id: eventID(raw, ordinal: ordinal), matchID: matchID, teamID: teamID, type: .varEvent,
                period: nil, minute: minute, timestamp: nil, playerID: playerID(raw), secondaryPlayerID: nil, ordinal: ordinal, detail: nil)
        }

        switch rawType {
        case "Card":
            let card = (raw["card"].string ?? "").lowercased()
            let type: SoccerEventType = card.contains("red") && card.contains("yellow") ? .secondYellow : card.contains("red") ? .redCard : .yellowCard
            return SoccerMatchEvent(id: eventID(raw, ordinal: ordinal), matchID: matchID, teamID: teamID, type: type,
                period: nil, minute: minute, timestamp: nil, playerID: playerID(raw), secondaryPlayerID: nil, ordinal: ordinal,
                detail: raw["cardReason"]["defaultText"].string)

        case "Goal":
            if raw["isPenaltyShootoutEvent"].bool == true { return nil } // shootout goals, not in-game timeline (Step 37/40)
            let isOwnGoal = raw["ownGoal"].bool == true
            let isPenalty = raw["goalDescriptionKey"].string == "penalty" || raw["penalty"].bool == true
            let type: SoccerEventType = isOwnGoal ? .ownGoal : isPenalty ? .penaltyGoal : .goal
            return SoccerMatchEvent(id: eventID(raw, ordinal: ordinal), matchID: matchID, teamID: teamID, type: type,
                period: nil, minute: minute, timestamp: nil, playerID: playerID(raw), secondaryPlayerID: nil, ordinal: ordinal,
                detail: raw["goalDescription"].string)

        case "Substitution":
            // `swap[0]` = player coming on, `swap[1]` = player going off (verified
            // live 2026-09-24 against every substitution in a full match).
            let swap = raw["swap"].array
            let onID = swap.first?["id"].string
            let offID = swap.count > 1 ? swap[1]["id"].string : nil
            return SoccerMatchEvent(id: eventID(raw, ordinal: ordinal), matchID: matchID, teamID: teamID, type: .substitution,
                period: nil, minute: minute, timestamp: nil, playerID: onID, secondaryPlayerID: offID, ordinal: ordinal, detail: nil)

        case "Half":
            let key = (raw["halfStrKey"].string ?? "").lowercased()
            let type: SoccerEventType = key.contains("halftime") ? .halftime : key.contains("full") ? .periodEnd : .unknown(key)
            return SoccerMatchEvent(id: eventID(raw, ordinal: ordinal), matchID: matchID, teamID: teamID, type: type,
                period: nil, minute: minute, timestamp: nil, playerID: nil, secondaryPlayerID: nil, ordinal: ordinal, detail: raw["halfStrShort"].string)

        case "AddedTime", "Comment":
            return nil

        default:
            return SoccerMatchEvent(id: eventID(raw, ordinal: ordinal), matchID: matchID, teamID: teamID, type: .unknown(rawType),
                period: nil, minute: minute, timestamp: nil, playerID: playerID(raw), secondaryPlayerID: nil, ordinal: ordinal, detail: nil)
        }
    }

    private static func playerID(_ raw: FotMobValue) -> String? { raw["player"]["id"].string }

    /// FotMob supplies a real `eventId` on `Card`/`Goal` rows but not on
    /// `Half`/`AddedTime`/`Substitution` — those synthesize an id from stable
    /// structured fields (time + type + player), mirroring `SoccerMatchEvent`'s own
    /// doc comment ("never from minute+description alone, since multiple incidents
    /// can share a minute").
    private static func eventID(_ raw: FotMobValue, ordinal: Int) -> String {
        if let id = raw["eventId"].string { return id }
        let time = raw["time"].string ?? "?"
        let type = raw["type"].string ?? "?"
        let player = playerID(raw) ?? raw["swap"].array.first?["id"].string ?? "?"
        return "\(time)-\(type)-\(player)-\(ordinal)"
    }
}
