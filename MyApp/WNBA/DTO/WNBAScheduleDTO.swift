import Foundation

/// cdn.wnba.com/static/json/staticData/scheduleLeagueV2.json — current season only
/// (Step 8). Historical-season support is explicitly a separate concern per the
/// integration brief, not something this single file can ever provide.
nonisolated struct WNBAScheduleResponse: Decodable, Sendable {
    let raw: WNBAValue
    init(raw: WNBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try WNBAValue(from: decoder) }
    var leagueSchedule: WNBAValue { raw["leagueSchedule"] }
    var seasonYear: String? { leagueSchedule["seasonYear"].string }
    var games: [WNBAValue] { leagueSchedule["gameDates"].array.flatMap { $0["games"].array } }
}
