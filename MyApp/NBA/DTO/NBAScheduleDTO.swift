import Foundation

/// stats.nba.com/stats/scheduleleaguev2 — nested JSON (not the columnar resultSets shape).
nonisolated struct NBAScheduleResponse: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var leagueSchedule: NBAValue { raw["leagueSchedule"] }
    var games: [NBAValue] { leagueSchedule["gameDates"].array.flatMap { $0["games"].array } }
}
