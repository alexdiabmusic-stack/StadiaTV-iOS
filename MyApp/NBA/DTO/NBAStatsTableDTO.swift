import Foundation

extension Dictionary where Key == String, Value == NBAValue {
    /// A row produced by `NBAStatsTable.rows` is a plain `[String: NBAValue]`, whose
    /// native subscript returns `NBAValue?` — this non-optional accessor matches
    /// `NBAValue`'s own subscript convention (missing key reads as `.null`, never throws).
    nonisolated func field(_ key: String) -> NBAValue { self[key] ?? .null }
}

/// stats.nba.com's classic `resultSets: [{ name, headers, rowSet }]` shape.
/// Zips headers onto each row so mappers can read columns by name instead of index.
nonisolated enum NBAStatsTable {
    static func rows(_ raw: NBAValue, resultSet name: String) -> [[String: NBAValue]] {
        let sets = raw["resultSets"].array
        guard let set = sets.first(where: { $0["name"].string == name }) else { return [] }
        let headers = set["headers"].array.compactMap { $0.string }
        guard !headers.isEmpty else { return [] }
        return set["rowSet"].array.map { row in
            let cells = row.array
            var dict: [String: NBAValue] = [:]
            for (index, header) in headers.enumerated() where index < cells.count { dict[header] = cells[index] }
            return dict
        }
    }
}

/// stats.nba.com/stats/leaguestandingsv3
nonisolated struct NBAStandingsResponse: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var rows: [[String: NBAValue]] { NBAStatsTable.rows(raw, resultSet: "Standings") }
}
