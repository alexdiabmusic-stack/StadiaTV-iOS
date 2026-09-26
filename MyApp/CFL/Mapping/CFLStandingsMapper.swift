import Foundation

/// `/api/standings/{year}` (verified live) nests rows under `data.divisions.{east,west}.standings`
/// — grouped as EAST/WEST here, never AFC/NFC-style conference names.
nonisolated enum CFLStandingsMapper {
    static func groups(_ raw: CFLValue, teams: [String: CFLValue]) -> [StandingsGroup] {
        let divisions = raw["data"]["divisions"].object
        return divisions.keys.sorted().compactMap { key -> StandingsGroup? in
            let rows = divisions[key]?["standings"].array ?? []
            guard !rows.isEmpty else { return nil }
            let name = key.uppercased()
            return StandingsGroup(id: name, name: name, rows: rows.compactMap { row -> StandingRow? in
                guard let teamID = row["team_id"].string else { return nil }
                let team = teams[teamID]
                return StandingRow(teamID: teamID, displayName: team?["clubname"].string ?? row["abbreviation"].string ?? "CFL",
                    abbreviation: row["abbreviation"].string ?? team?["abbreviation"].string ?? "CFL", logoURL: nil,
                    record: [row["wins"].string, row["losses"].string, row["ties"].string].compactMap { $0 }.joined(separator: "-"),
                    wins: row["wins"].string, losses: row["losses"].string, ties: row["ties"].string, winPercent: row["winning_percentage"].string,
                    gamesBack: nil, streak: nil, pointsFor: row["points_for"].string, pointsAgainst: row["points_against"].string,
                    leaguePoints: row["points"].string, gamesPlayed: row["games_played"].string,
                    goalDiff: nil, divisionRank: row["place"].string, leagueRank: nil)
            })
        }
    }
}
