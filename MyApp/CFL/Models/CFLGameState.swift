import Foundation

/// `game_type_id` values observed live against season 75 (2026): 0 = preseason (paired
/// with a negative `week`), 1 = regular season, 2/3 = the two conference semi-finals,
/// 4/5 = the two conference finals, 6 = Grey Cup. Which of 2/3 (or 4/5) is East vs West
/// isn't encoded in the id itself — `CFLGameTypeMapper` resolves that from the actual
/// participating teams' `team_zone` once qualifiers are known, never guessed from the id.
nonisolated enum CFLGameType: Equatable, Sendable {
    case preseason, regularSeason, divisionSemiFinal, divisionFinal, greyCup, unknown(Int)
}
/// `echo.pims.cfl.ca`'s per-fixture detail endpoint (verified live) exposes score, overall
/// `game_status`/`game_clock`/`total_periods`, but no down/distance/field-position/play
/// data — that gap is real, not an oversight, and is why `drives`/`plays` stay empty until
/// a `CFLLivePlayProvider` is wired in (Step 27); Overview/Box Score/Stats never depend on it.
nonisolated struct CFLGameState: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let seasonID: Int
    let year: Int
    let week: Int
    let gameType: CFLGameType
    let start: Date
    var home: FootballTeamState
    var away: FootballTeamState
    var status: FootballGameStatus
    var statusText: String
    var totalPeriods: Int?
    var clock: String?
    var venue: String?
    var broadcasts: [String]
    var drives: [FootballGameDrive]
    var plays: [FootballPlay]
    var summaryUpdated: Date
    var detailsUpdated: Date
    var possession: FootballTeamState? { home.possession ? home : away.possession ? away : nil }
    var isOvertime: Bool { (totalPeriods ?? 4) > 4 }
}
extension CFLGameType: Codable {
    private enum Key: String, CodingKey { case preseason, regularSeason, divisionSemiFinal, divisionFinal, greyCup, unknown }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if c.allKeys.contains(.unknown) { self = .unknown(try c.decode(Int.self, forKey: .unknown)); return }
        guard let key = c.allKeys.first else { self = .unknown(-1); return }
        switch key {
        case .preseason: self = .preseason
        case .regularSeason: self = .regularSeason
        case .divisionSemiFinal: self = .divisionSemiFinal
        case .divisionFinal: self = .divisionFinal
        case .greyCup: self = .greyCup
        case .unknown: self = .unknown(try c.decode(Int.self, forKey: .unknown))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .preseason: try c.encode(true, forKey: .preseason)
        case .regularSeason: try c.encode(true, forKey: .regularSeason)
        case .divisionSemiFinal: try c.encode(true, forKey: .divisionSemiFinal)
        case .divisionFinal: try c.encode(true, forKey: .divisionFinal)
        case .greyCup: try c.encode(true, forKey: .greyCup)
        case .unknown(let raw): try c.encode(raw, forKey: .unknown)
        }
    }
}
