import Foundation

extension Dictionary where Key == String, Value == WNBAValue {
    nonisolated func field(_ key: String) -> WNBAValue { self[key] ?? .null }
}

/// stats.wnba.com's assumed `resultSets: [{ name, headers, rowSet }]` shape,
/// mirroring stats.nba.com's documented convention — UNVERIFIED against a real
/// WNBA Stats response this session (Step 20/21: standings/rosters/leaders only,
/// never on the live poll path, so a wrong guess here degrades gracefully rather
/// than breaking the Game Center).
nonisolated enum WNBAStatsTable {
    static func rows(_ raw: WNBAValue, resultSet name: String) -> [[String: WNBAValue]] {
        let sets = raw["resultSets"].array
        guard let set = sets.first(where: { $0["name"].string == name }) else { return [] }
        let headers = set["headers"].array.compactMap { $0.string }
        guard !headers.isEmpty else { return [] }
        return set["rowSet"].array.map { row in
            let cells = row.array
            var dict: [String: WNBAValue] = [:]
            for (index, header) in headers.enumerated() where index < cells.count { dict[header] = cells[index] }
            return dict
        }
    }
}

/// stats.wnba.com/stats/leaguestandingsv3 (assumed path, Step 20)
nonisolated struct WNBAStandingsResponse: Decodable, Sendable {
    let raw: WNBAValue
    init(raw: WNBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try WNBAValue(from: decoder) }
    var rows: [[String: WNBAValue]] { WNBAStatsTable.rows(raw, resultSet: "Standings") }
}
