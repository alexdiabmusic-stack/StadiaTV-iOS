import Foundation

nonisolated enum BasketballGameTab: String, Codable, CaseIterable, Identifiable {
    case overview = "Overview", plays = "Play-by-Play", boxscore = "Box Score", shots = "Shot Chart"
    var id: String { rawValue }
}

nonisolated struct BasketballGameCenterUpdate: Sendable {
    let gameID: BasketballGameID
    let requestedAt: Date
    /// Lightweight game state pulled out of the shared scoreboard — used on ticks
    /// that don't need fresh box stats, so the per-game box score endpoint isn't
    /// re-fetched every poll.
    var scoreboardGame: BasketballGame?
    /// From the combined CDN box score response, which carries both game state and
    /// player/team stats together — there's no separate lightweight box endpoint.
    var boxGame: BasketballGame?
    var homeBox: [NBAPlayerGameLine]?
    var awayBox: [NBAPlayerGameLine]?
    var homeTeamStats: NBATeamStatLine?
    var awayTeamStats: NBATeamStatLine?
    var homeLeaders: NBATeamGameLeaders?
    var awayLeaders: NBATeamGameLeaders?
    var onCourtHome: [Int]?
    var onCourtAway: [Int]?
    var plays: [NBAPlayEvent]?
    var playsSource: String?
    var errors: [String: String] = [:]
    var retryAfter: Date?
}

/// Coordinates every Game Center resource behind one call per poll tick, for any
/// native basketball league. `NBAGameCenterService`/`WNBAGameCenterService` are
/// the two conformers — the polling loop, reducer, and cache below never need to
/// know which one they're talking to.
nonisolated protocol BasketballGameCenterServing: Sendable {
    func fetch(gameID: BasketballGameID, tab: BasketballGameTab, full: Bool) async throws -> BasketballGameCenterUpdate
}
