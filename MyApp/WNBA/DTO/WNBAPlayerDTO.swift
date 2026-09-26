import Foundation

/// stats.wnba.com/stats/commonplayerinfo and /stats/playercareerstats (assumed columnar shape)
nonisolated struct WNBAPlayerInfoResponse: Decodable, Sendable {
    let raw: WNBAValue
    init(raw: WNBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try WNBAValue(from: decoder) }
    var info: [String: WNBAValue]? { WNBAStatsTable.rows(raw, resultSet: "CommonPlayerInfo").first }
}
nonisolated struct WNBAPlayerCareerStatsResponse: Decodable, Sendable {
    let raw: WNBAValue
    init(raw: WNBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try WNBAValue(from: decoder) }
    var seasonTotalsRegularSeason: [[String: WNBAValue]] { WNBAStatsTable.rows(raw, resultSet: "SeasonTotalsRegularSeason") }
    var careerTotalsRegularSeason: [String: WNBAValue]? { WNBAStatsTable.rows(raw, resultSet: "CareerTotalsRegularSeason").first }
}
