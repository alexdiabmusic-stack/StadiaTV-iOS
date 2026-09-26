import Foundation

/// `/api/stats/playerrecords` (verified live) nests both a per-fixture `fixtures[]`
/// array and a cumulative `seasons[]` array on the same player record — this mapper
/// only ever reads `fixtures[]` filtered to the active game's `fixture_id`, never
/// `seasons[]`, so a player's box-score line can't accidentally show season totals.
nonisolated struct CFLPlayerGameLine: Identifiable, Sendable {
    let id: String
    let name: String
    let teamID: String
    let position: String?
    let stats: [String: Double]
}
nonisolated enum CFLPlayerStatsMapper {
    static func players(_ records: [CFLValue], fixtureID: String) -> [CFLPlayerGameLine] {
        records.compactMap { record -> CFLPlayerGameLine? in
            guard let playerID = record["player_id"].string,
                  let entry = record["fixtures"].array.first(where: { $0["fixture_id"].string == fixtureID }) else { return nil }
            let name = [record["firstname"].string, record["lastname"].string].compactMap { $0 }.joined(separator: " ")
            let stats = entry["stats"].object.compactMapValues(\.double)
            return CFLPlayerGameLine(id: playerID, name: name.isEmpty ? "Unknown player" : name,
                teamID: entry["team_id"].string ?? "", position: record["position"].string, stats: stats)
        }
    }
}
