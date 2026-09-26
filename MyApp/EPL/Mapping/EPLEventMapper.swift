import Foundation

/// Maps `/v1/matches/{id}/events`, which groups incidents per team into `goals`,
/// `cards`, and `subs` buckets with no event ID (verified live 2026-09-23) — not a
/// flat event list. Only `goalType: "Goal"` and card `type: "Yellow"` have been
/// directly observed; own-goal/penalty/second-yellow vocabulary below is a
/// best-effort substring match so an unrecognized value degrades to `.unknown(raw)`
/// instead of being silently dropped or guessed wrong.
nonisolated enum EPLEventMapper {
    static func events(_ raw: EPLValue, matchID: String, homeTeamID: String, awayTeamID: String) -> [SoccerMatchEvent] {
        let home = bucket(raw["homeTeam"], teamID: homeTeamID, matchID: matchID)
        let away = bucket(raw["awayTeam"], teamID: awayTeamID, matchID: matchID)
        return sorted(home + away)
    }

    private static func bucket(_ raw: EPLValue, teamID: String, matchID: String) -> [SoccerMatchEvent] {
        var out: [SoccerMatchEvent] = []
        for (index, entry) in raw["goals"].array.enumerated() { out.append(goal(entry, teamID: teamID, matchID: matchID, ordinal: index)) }
        for (index, entry) in raw["cards"].array.enumerated() { out.append(card(entry, teamID: teamID, matchID: matchID, ordinal: index)) }
        for (index, entry) in raw["subs"].array.enumerated() { out.append(substitution(entry, teamID: teamID, matchID: matchID, ordinal: index)) }
        return out
    }

    private static func goal(_ raw: EPLValue, teamID: String, matchID: String, ordinal: Int) -> SoccerMatchEvent {
        let typeRaw = raw["goalType"].string ?? "Goal"
        let lower = typeRaw.lowercased()
        let type: SoccerEventType = lower.contains("own") ? .ownGoal : lower.contains("penalt") ? .penaltyGoal : lower == "goal" ? .goal : .unknown(typeRaw)
        let timestampRaw = raw["timestamp"].string
        return SoccerMatchEvent(id: identity(matchID: matchID, teamID: teamID, kind: "goal", playerID: raw["playerId"].string, timestamp: timestampRaw, ordinal: ordinal),
            matchID: matchID, teamID: teamID, type: type, period: raw["period"].string, minute: raw["time"].string.flatMap(Int.init),
            timestamp: EPLDate.parseEventTimestamp(timestampRaw), playerID: raw["playerId"].string, secondaryPlayerID: raw["assistPlayerId"].string, ordinal: ordinal)
    }

    private static func card(_ raw: EPLValue, teamID: String, matchID: String, ordinal: Int) -> SoccerMatchEvent {
        let typeRaw = raw["type"].string ?? ""
        let lower = typeRaw.lowercased()
        let type: SoccerEventType = lower.contains("second") ? .secondYellow : lower.contains("red") ? .redCard : lower.contains("yellow") ? .yellowCard : .unknown(typeRaw)
        let timestampRaw = raw["timestamp"].string
        return SoccerMatchEvent(id: identity(matchID: matchID, teamID: teamID, kind: "card", playerID: raw["playerId"].string, timestamp: timestampRaw, ordinal: ordinal),
            matchID: matchID, teamID: teamID, type: type, period: raw["period"].string, minute: raw["time"].string.flatMap(Int.init),
            timestamp: EPLDate.parseEventTimestamp(timestampRaw), playerID: raw["playerId"].string, secondaryPlayerID: nil, ordinal: ordinal)
    }

    private static func substitution(_ raw: EPLValue, teamID: String, matchID: String, ordinal: Int) -> SoccerMatchEvent {
        let timestampRaw = raw["timestamp"].string
        let onID = raw["playerOnId"].string
        return SoccerMatchEvent(id: identity(matchID: matchID, teamID: teamID, kind: "sub", playerID: onID, timestamp: timestampRaw, ordinal: ordinal),
            matchID: matchID, teamID: teamID, type: .substitution, period: raw["period"].string, minute: raw["time"].string.flatMap(Int.init),
            timestamp: EPLDate.parseEventTimestamp(timestampRaw), playerID: onID, secondaryPlayerID: raw["playerOffId"].string, ordinal: ordinal)
    }

    /// No provider event ID exists — identity is synthesized from stable structured
    /// fields plus a per-bucket ordinal, never from minute+description (Step 16).
    private static func identity(matchID: String, teamID: String, kind: String, playerID: String?, timestamp: String?, ordinal: Int) -> String {
        "\(matchID)|\(teamID)|\(kind)|\(playerID ?? "-")|\(timestamp ?? "-")|\(ordinal)"
    }

    /// Deterministic ordering: timestamp first (the provider's own sequencing),
    /// falling back to minute then per-bucket ordinal when timestamps tie or are
    /// missing — never minute alone (Step 78).
    private static func sorted(_ events: [SoccerMatchEvent]) -> [SoccerMatchEvent] {
        events.sorted { a, b in
            if let ta = a.timestamp, let tb = b.timestamp, ta != tb { return ta < tb }
            if a.timestamp == nil || b.timestamp == nil, (a.minute ?? -1) != (b.minute ?? -1) { return (a.minute ?? -1) < (b.minute ?? -1) }
            return a.ordinal < b.ordinal
        }
    }
}
