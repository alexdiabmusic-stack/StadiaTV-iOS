import Foundation

nonisolated struct MLBScheduleResponse: Decodable, Sendable {
    let raw: MLBValue
    init(raw: MLBValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try MLBValue(from: decoder) }
    var games: [MLBValue] { raw["dates"].array.flatMap { $0["games"].array } }
}
