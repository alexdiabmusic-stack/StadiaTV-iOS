import Foundation

nonisolated struct MLBPlayByPlayResponse: Decodable, Sendable {
    let raw: MLBValue
    init(raw: MLBValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try MLBValue(from: decoder) }
    var plays: [MLBValue] { raw["allPlays"].array }
    var currentPlay: MLBValue { raw["currentPlay"] }
}
