import Foundation

/// stats.wnba.com/stats/commonteamroster (assumed columnar shape)
nonisolated struct WNBARosterResponse: Decodable, Sendable {
    let raw: WNBAValue
    init(raw: WNBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try WNBAValue(from: decoder) }
    var players: [[String: WNBAValue]] { WNBAStatsTable.rows(raw, resultSet: "CommonTeamRoster") }
}
