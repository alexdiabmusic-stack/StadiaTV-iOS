import Foundation

/// stats.nba.com/stats/commonteamroster — columnar, like standings/player info.
nonisolated struct NBARosterResponse: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var players: [[String: NBAValue]] { NBAStatsTable.rows(raw, resultSet: "CommonTeamRoster") }
}
