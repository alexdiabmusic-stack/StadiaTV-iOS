import Foundation

/// cdn.wnba.com/static/json/liveData/scoreboard/todaysScoreboard_10.json
nonisolated struct WNBAScoreboardResponse: Decodable, Sendable {
    let raw: WNBAValue
    init(raw: WNBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try WNBAValue(from: decoder) }
    var scoreboard: WNBAValue { raw["scoreboard"] }
    var gameDate: String? { scoreboard["gameDate"].string }
    var games: [WNBAValue] { scoreboard["games"].array }
}
