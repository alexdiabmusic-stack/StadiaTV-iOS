import Foundation

nonisolated enum MLBBoxscoreMapper {
    static func players(_ raw: MLBValue) -> [BaseballBoxPlayer] {
        ["away", "home"].flatMap { side -> [BaseballBoxPlayer] in
            let team = raw["teams"][side]
            guard let id = team["team"]["id"].int else { return [] }
            return team["players"].object.values.compactMap { row in
                guard var player = MLBGameMapper.player(row["person"]) else { return nil }
                player.position = row["position"]["abbreviation"].string; player.jersey = row["jerseyNumber"].string
                return BaseballBoxPlayer(teamID: id, player: player, battingOrder: row["battingOrder"].int,
                    batting: row["stats"]["batting"].object.compactMapValues(\.string), pitching: row["stats"]["pitching"].object.compactMapValues(\.string), fielding: row["stats"]["fielding"].object.compactMapValues(\.string))
            }.sorted { ($0.battingOrder ?? 9999, $0.player.id) < ($1.battingOrder ?? 9999, $1.player.id) }
        }
    }
}
