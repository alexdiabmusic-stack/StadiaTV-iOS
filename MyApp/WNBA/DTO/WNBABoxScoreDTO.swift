import Foundation

/// cdn.wnba.com/static/json/liveData/boxscore/boxscore_{GAME_ID}.json
nonisolated struct WNBABoxScoreResponse: Decodable, Sendable {
    let raw: WNBAValue
    init(raw: WNBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try WNBAValue(from: decoder) }
    var game: WNBAValue { raw["game"] }
    var gameID: String? { game["gameId"].string }
    var homeTeam: WNBAValue { game["homeTeam"] }
    var awayTeam: WNBAValue { game["awayTeam"] }
    var arena: WNBAValue { game["arena"] }
    var officials: [WNBAValue] { game["officials"].array }
}
