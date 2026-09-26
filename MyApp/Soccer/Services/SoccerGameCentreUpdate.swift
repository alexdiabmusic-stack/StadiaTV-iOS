import Foundation

/// One poll's worth of raw fetch results, before the reducer merges them into a
/// `SoccerGameCentreSnapshot`. Optional fields distinguish "not requested this poll"
/// from "requested but empty" so the reducer never clobbers state a lighter poll
/// didn't touch. Shared across every soccer provider (EPL, MLS, ...) so each
/// provider's Game Centre service only has to produce this one shape and the
/// polling/merge/cache machinery in this file's siblings is never duplicated.
nonisolated struct SoccerGameCentreUpdate: Sendable {
    let matchID: String
    let requestedAt: Date
    var match: SoccerMatch?
    var events: [SoccerMatchEvent]?
    var homeLineup: SoccerLineup??      // outer: fetched this poll; inner: nil == not announced yet
    var awayLineup: SoccerLineup??
    var homeStats: SoccerTeamMatchStats?
    var awayStats: SoccerTeamMatchStats?
    var officials: [SoccerOfficial]?
    var commentary: [SoccerCommentaryEntry]?
    var commentaryNextCursor: String??  // outer: fetched; inner: nil == no further pages
    var playerDirectory: [String: SoccerPlayerReference] = [:]
    var liveStandings: SoccerStandingsTable?
    /// Conference/group tables (e.g. MLS Eastern/Western) — independent of `liveStandings`,
    /// which stays a single flat table for providers with no conference split.
    var conferenceStandings: [SoccerStandingsTable]?
    var playerMatchStats: [SoccerPlayerMatchStats]?
    var penaltyShootout: SoccerPenaltyShootout?
    /// Optional (Step 24) — nil when this poll didn't request/support shots.
    var shots: [SoccerShot]?
    /// Optional (Step 25) — nil when this poll didn't request/support momentum.
    var momentum: [SoccerMomentumSample]?
    /// Set once a two-source provider (La Liga) resolves or re-confirms its
    /// cross-provider match mapping; nil for single-source providers and for polls
    /// that didn't touch reconciliation.
    var providerMatchIDs: SoccerProviderMatchIDs?
    var errors: [String: String] = [:]
    var retryAfter: Date?
}

/// Coordinates every Match Centre resource behind one call per poll tick, so
/// Overview/Timeline/Lineups/Stats/Commentary don't each independently trigger the
/// same network requests. Every soccer provider implements exactly this — the
/// polling loop, reducer, and cache below never need to know which one they're
/// talking to.
nonisolated protocol SoccerGameCentreServing: Sendable {
    func fetch(matchID: String, tab: SoccerGameTab, full: Bool, lineupsLoaded: Bool, knownPlayers: [String: SoccerPlayerReference], commentaryCursor: String?) async throws -> SoccerGameCentreUpdate
}
