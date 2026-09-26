import Foundation

nonisolated enum NFLPlayMapper {
    static func drives(_ raw: NFLValue, gameID: String) -> [FootballGameDrive] {
        let values = raw.array.compactMap { value -> FootballGameDrive? in
            guard let sequence = value["sequence"].int else { return nil }
            return FootballGameDrive(id: "\(gameID):drive:\(sequence)", sequence: sequence, teamID: value["teamId"].string,
                startQuarter: value["startedQuarter"].int, endQuarter: value["endedQuarter"].int,
                startClock: value["startedClock"].string, endClock: value["endedClock"].string,
                startField: value["startedYardLine"].string, endField: value["endedYardLine"].string,
                playCount: value["plays"].int, yards: value["yardsGainedNet"].int, timeOfPossession: value["timeOfPossession"].string,
                result: value["endedDescription"].string, scoring: value["endedWithScore"].bool == true)
        }
        return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.sequence < $1.sequence }
    }
    static func plays(_ raw: NFLValue, gameID: String, drives: [FootballGameDrive], players: [String: String] = [:]) -> [FootballPlay] {
        // Rebuild from the authoritative snapshot, including deletions and corrected identities.
        var result: [String: FootballPlay] = [:]
        for value in raw.array {
            guard let sourceID = value["playId"].string else { continue }
            let id = "\(gameID):play:\(sourceID)"
            if value["playDeleted"].bool == true { result[id] = nil; continue }
            let text = value["playDescription"].string ?? "Play details unavailable"
            let rawType = value["playType"].string ?? "UNKNOWN"
            let scoring = value["playScored"].bool == true
            var seenStats = Set<String>()
            let participants = value["stats"].array.compactMap { stat -> FootballPlayParticipant? in
                if let statID = stat["playStatId"].string, !seenStats.insert(statID).inserted { return nil }
                return FootballPlayParticipant(id: stat["personId"].string, name: players[stat["personId"].string ?? ""] ?? stat["gsisPlayerName"].string ?? "Unknown player",
                    teamID: stat["teamId"].string, rawStatType: stat["statType"].int, yards: stat["yards"].int)
            }
            let drive = value["driveSequence"].int
            result[id] = FootballPlay(id: id, sequence: value["playSequenceNumber"].double ?? value["playId"].double ?? 0,
                driveSequence: drive, quarter: value["quarter"].int, clock: value["clockTime"].string,
                down: value["down"].int, distance: value["yardsRemaining"].int, goalToGo: value["playIsGoalToGo"].bool == true,
                field: value["yardLine"].string, type: resolvedType(rawType, scoring: value["scoringPlayType"].string, text: text, participants: participants),
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), yards: value["yardsGained"].int,
                scoring: scoring, turnover: participants.contains { [9, 19, 59, 60].contains($0.rawStatType ?? -1) },
                penalty: rawType == "PENALTY" || text.localizedCaseInsensitiveContains("PENALTY"),
                teamID: value["scoringTeamId"].string ?? drives.first { $0.sequence == drive }?.teamID, participants: participants, totalDowns: 4)
        }
        return result.values.sorted { $0.sequence == $1.sequence ? $0.id < $1.id : $0.sequence < $1.sequence }
    }
    static func resolvedType(_ raw: String, scoring: String?, text: String, participants: [FootballPlayParticipant]) -> FootballPlayType {
        if scoring == "TOUCHDOWN" || scoring == "SAFETY" { return type(raw, scoring: scoring, text: text) }
        let codes = Set(participants.compactMap(\.rawStatType))
        if raw == "FIELD_GOAL", !codes.isDisjoint(with: [69, 71]) { return .fieldGoalMissed }
        if raw == "XP_KICK", !codes.isDisjoint(with: [73, 74]) { return .extraPointMissed }
        if codes.contains(19) { return .interception }
        if !codes.isDisjoint(with: [52, 53]) { return .fumble }
        if raw == "PASS", codes.contains(14) { return .passIncomplete }
        return type(raw, scoring: scoring, text: text)
    }
    static func type(_ raw: String, scoring: String?, text: String) -> FootballPlayType {
        if scoring == "TOUCHDOWN" { return .touchdown }
        if scoring == "SAFETY" { return .safety }
        switch raw {
        case "RUSH": return text.localizedCaseInsensitiveContains("kneels") ? .kneel : .run
        case "PASS":
            if text.localizedCaseInsensitiveContains("INTERCEPTED") { return .interception }
            if text.localizedCaseInsensitiveContains("incomplete") { return .passIncomplete }
            if text.localizedCaseInsensitiveContains("spiked") { return .spike }
            return .pass
        case "SACK": return .sack
        case "PUNT": return .punt
        case "KICK_OFF": return .kickoff
        case "FIELD_GOAL": return .fieldGoal
        case "XP_KICK": return .extraPoint
        case "PAT2": return .twoPoint
        case "PENALTY": return .penalty
        case "TIMEOUT": return .timeout
        case "END_QUARTER": return .quarterEnd
        case "END_GAME": return .gameEnd
        case "COMMENT" where text.localizedCaseInsensitiveContains("review") || text.localizedCaseInsensitiveContains("challenge"): return .review
        default: return .unknown(raw)
        }
    }
}
