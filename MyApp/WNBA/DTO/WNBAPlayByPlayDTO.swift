import Foundation

/// cdn.wnba.com/static/json/liveData/playbyplay/playbyplay_{GAME_ID}.json
nonisolated struct WNBAPlayByPlayResponse: Decodable, Sendable {
    let raw: WNBAValue
    init(raw: WNBAValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try WNBAValue(from: decoder) }
    var gameID: String? { raw["game"]["gameId"].string }
    var actions: [WNBAValue] { raw["game"]["actions"].array }
}
