import Foundation

/// A competition round/matchweek, independent of provider. `SoccerMatch.matchWeek`
/// tags each match with its round number for display; this type carries the round's
/// own metadata (id/name/date window) for schedule/rounds screens. Generic on
/// purpose — a knockout round ("Quarter-final") and a league matchweek ("Matchweek
/// 12") are both just a `SoccerRound`, so the domain never assumes a fixed count
/// (e.g. La Liga's 38) or a single competition shape.
nonisolated struct SoccerRound: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let week: Int
    let name: String?
    let startDate: Date?
    let endDate: Date?
}
