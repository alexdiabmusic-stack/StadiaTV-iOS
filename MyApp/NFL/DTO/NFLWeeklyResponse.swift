import Foundation

nonisolated struct NFLWeeklyResponse: Decodable, Sendable {
    let games: [NFLValue]
    init(from decoder: Decoder) throws {
        let raw = try NFLValue(from: decoder)
        if case .array(let games) = raw { self.games = games }
        else if case .array(let games) = raw["games"] { self.games = games }
        else if case .array(let games) = raw["data"] { self.games = games }
        else { throw NFLAPIError.invalidResponse }
    }
}
