import Foundation

/// cdn.nba.com/static/json/liveData/playbyplay/playbyplay_{gameId}.json
nonisolated struct NBAPlayByPlayResponse: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var gameID: String? { raw["game"]["gameId"].string }
    var actions: [NBAValue] { raw["game"]["actions"].array }
}

/// stats.nba.com/stats/playbyplayv3 — columnar `resultSets`, used as a secondary/rich fallback.
nonisolated struct NBAPlayByPlayV3Response: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var actions: [[String: NBAValue]] { NBAStatsTable.rows(raw, resultSet: "PlayByPlay") }
}
