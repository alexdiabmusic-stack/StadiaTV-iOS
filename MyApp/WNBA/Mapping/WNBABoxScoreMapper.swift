import Foundation

nonisolated enum WNBABoxScoreMapper {
    static func players(_ teamRaw: WNBAValue) -> [NBAPlayerGameLine] {
        guard let teamID = teamRaw["teamId"].int else { return [] }
        return teamRaw["players"].array.compactMap { row in
            guard let personID = row["personId"].int else { return nil }
            let name = row["name"].string ?? [row["firstName"].string, row["familyName"].string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            var stats: [String: Double] = [:]
            for (key, value) in row["statistics"].object where !key.hasPrefix("minutes") {
                if let number = value.double { stats[key] = number }
            }
            let minutesSeconds = NBADuration.seconds(row["statistics"]["minutes"].string)
            let played = row["played"].bool ?? ((minutesSeconds ?? 0) > 0)
            return NBAPlayerGameLine(personID: personID, teamID: teamID, name: name.isEmpty ? "Unknown player" : name,
                nameInitial: row["nameI"].string, jerseyNum: row["jerseyNum"].string, position: row["position"].string,
                order: row["order"].int, starter: row["starter"].bool ?? false, onCourt: row["oncourt"].bool ?? false,
                played: played, status: row["status"].string, notPlayingReason: row["notPlayingReason"].string,
                notPlayingDescription: row["notPlayingDescription"].string, minutesSeconds: minutesSeconds, stats: stats)
        }
    }
    static func teamStats(_ teamRaw: WNBAValue) -> NBATeamStatLine? {
        guard let teamID = teamRaw["teamId"].int else { return nil }
        var stats: [String: Double] = [:]
        for (key, value) in teamRaw["statistics"].object where !key.hasPrefix("minutes") {
            if let number = value.double { stats[key] = number }
        }
        return NBATeamStatLine(teamID: teamID, stats: stats)
    }
    /// Current on-court lineup straight from `oncourt` (Step 11) — never
    /// reconstructed by replaying substitutions.
    static func onCourt(_ teamRaw: WNBAValue) -> [Int] {
        teamRaw["players"].array.filter { $0["oncourt"].bool == true }.compactMap { $0["personId"].int }
    }
    static func leaders(_ lines: [NBAPlayerGameLine], teamID: Int) -> NBATeamGameLeaders {
        let players = lines.filter { $0.teamID == teamID && $0.played }
        func top(_ value: (NBAPlayerGameLine) -> Int) -> NBAStatLeader? {
            guard let best = players.max(by: { value($0) < value($1) }), value(best) > 0 else { return nil }
            return NBAStatLeader(personID: best.personID, name: best.name, value: value(best))
        }
        return NBATeamGameLeaders(points: top(\.points), rebounds: top(\.rebounds), assists: top(\.assists))
    }
}
