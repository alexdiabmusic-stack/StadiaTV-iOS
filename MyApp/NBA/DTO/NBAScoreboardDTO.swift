import Foundation

/// cdn.nba.com/static/json/liveData/scoreboard/todaysScoreboard_00.json
nonisolated struct NBAScoreboardResponse: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var scoreboard: NBAValue { raw["scoreboard"] }
    var gameDate: String? { scoreboard["gameDate"].string }
    var games: [NBAValue] { scoreboard["games"].array }
}

/// stats.nba.com/stats/scoreboardv3 — shares the "scoreboard" envelope with the CDN response.
nonisolated struct NBAScoreboardV3Response: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var games: [NBAValue] { raw["scoreboard"]["games"].array }
}
