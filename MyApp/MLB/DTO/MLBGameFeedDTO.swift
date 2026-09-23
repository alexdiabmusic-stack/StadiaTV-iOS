import Foundation

nonisolated struct MLBGameFeedResponse: Decodable, Sendable {
    let raw: MLBValue
    init(raw: MLBValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try MLBValue(from: decoder) }
    var gamePk: Int? { raw["gamePk"].int }
    var data: MLBValue { raw["gameData"] }
    var live: MLBValue { raw["liveData"] }
}
