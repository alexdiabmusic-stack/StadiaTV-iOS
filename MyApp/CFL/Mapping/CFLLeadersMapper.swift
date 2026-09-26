import Foundation

/// `api.stats.cfl.ca/stats/leaders/{year}` (verified live) already groups by
/// offence/defence/special_teams — preserved as-is, never re-flattened.
nonisolated struct CFLLeaderRow: Identifiable, Sendable {
    let id: String
    let name: String
    let teamID: String?
    let position: String?
    let value: Double
}
nonisolated struct CFLLeaderCategory: Identifiable, Sendable {
    let id: String
    let title: String
    let rows: [CFLLeaderRow]
}
nonisolated enum CFLLeadersMapper {
    static func groups(_ raw: CFLValue) -> [String: [CFLLeaderCategory]] {
        func parse(_ key: String) -> [CFLLeaderCategory] {
            raw[key].array.compactMap { entry -> CFLLeaderCategory? in
                guard let category = entry["category"].string else { return nil }
                let rows = entry["leaders"].array.compactMap { row -> CFLLeaderRow? in
                    guard let id = row["player_id"].string, let value = row["statValue"].double else { return nil }
                    let name = [row["firstname"].string, row["lastname"].string].compactMap { $0 }.joined(separator: " ")
                    return CFLLeaderRow(id: id, name: name, teamID: row["team_id"].string, position: row["position"].string, value: value)
                }
                return CFLLeaderCategory(id: category, title: category, rows: rows)
            }
        }
        return ["offence": parse("offence"), "defence": parse("defence"), "special_teams": parse("special_teams")]
    }
}
