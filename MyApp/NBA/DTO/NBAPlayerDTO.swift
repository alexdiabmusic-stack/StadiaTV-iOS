import Foundation

/// stats.nba.com/stats/commonplayerinfo and /stats/playercareerstats — both columnar.
nonisolated struct NBAPlayerInfoResponse: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var info: [String: NBAValue]? { NBAStatsTable.rows(raw, resultSet: "CommonPlayerInfo").first }
}
nonisolated struct NBAPlayerCareerStatsResponse: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var seasonTotalsRegularSeason: [[String: NBAValue]] { NBAStatsTable.rows(raw, resultSet: "SeasonTotalsRegularSeason") }
    var careerTotalsRegularSeason: [String: NBAValue]? { NBAStatsTable.rows(raw, resultSet: "CareerTotalsRegularSeason").first }
}
