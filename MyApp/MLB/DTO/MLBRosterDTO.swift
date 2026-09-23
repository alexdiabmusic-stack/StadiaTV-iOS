import Foundation

nonisolated struct MLBRosterResponse: Decodable, Sendable {
    let raw: MLBValue
    init(raw: MLBValue) { self.raw = raw }
    init(from decoder: Decoder) throws { raw = try MLBValue(from: decoder) }
    
}
