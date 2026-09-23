import Foundation

/// cdn.nba.com/static/json/liveData/boxscore/boxscore_{gameId}.json
nonisolated struct NBABoxScoreResponse: Decodable, Sendable {
    let raw: NBAValue
    init(raw: NBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try NBAValue(from: decoder) }
    var game: NBAValue { raw["game"] }
    var gameID: String? { game["gameId"].string }
    var homeTeam: NBAValue { game["homeTeam"] }
    var awayTeam: NBAValue { game["awayTeam"] }
    var arena: NBAValue { game["arena"] }
    var officials: [NBAValue] { game["officials"].array }
}
