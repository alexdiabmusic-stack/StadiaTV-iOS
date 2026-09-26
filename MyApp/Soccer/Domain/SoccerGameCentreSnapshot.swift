import Foundation

nonisolated enum SoccerGameTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case overview = "Overview", timeline = "Timeline", lineups = "Lineups", stats = "Stats", commentary = "Commentary"
    /// Optional (Step 24) — only providers that populate `SoccerGameCentreSnapshot.shots`
    /// should offer this tab; `SoccerGameCentreView`'s `availableTabs:` gates it so EPL/MLS
    /// (which never populate shots) don't grow an empty tab.
    case shots = "Shots"
    var id: String { rawValue }
}

/// The aggregated Game Centre state for one match, provider-independent — any future
/// soccer provider's reducer produces this same shape so the Soccer Game Centre UI
/// never needs to know which league/provider is behind it.
nonisolated struct SoccerGameCentreSnapshot: Codable, Sendable, Equatable {
    let matchID: String
    var match: SoccerMatch?
    var events: [SoccerMatchEvent] = []
    var homeLineup: SoccerLineup?
    var awayLineup: SoccerLineup?
    var homeStats: SoccerTeamMatchStats?
    var awayStats: SoccerTeamMatchStats?
    var officials: [SoccerOfficial] = []
    var commentary: [SoccerCommentaryEntry] = []
    var commentaryNextCursor: String?
    /// A `live=true` standings projection, kept distinct from the official table —
    /// never persisted or displayed as though it were the confirmed table (Step 80).
    var liveStandings: SoccerStandingsTable?
    /// Conference/group tables (e.g. MLS Eastern/Western), when the provider's
    /// competition has a conference split. Empty for single-table leagues like EPL.
    var conferenceStandings: [SoccerStandingsTable] = []
    var playerMatchStats: [SoccerPlayerMatchStats] = []
    var penaltyShootout: SoccerPenaltyShootout?
    var playerDirectory: [String: SoccerPlayerReference] = [:]
    /// Optional (Step 24) — empty for every provider that has no shot-by-shot feed.
    var shots: [SoccerShot] = []
    /// Optional (Step 25) — empty unless the provider supplies a momentum series.
    var momentum: [SoccerMomentumSample] = []
    /// Only ever set by a two-source provider (La Liga's official ID + FotMob ID);
    /// single-source providers (EPL, MLS) leave this nil.
    var providerMatchIDs: SoccerProviderMatchIDs?
    var fetchedAt: Date = .distantPast
    var lastEventsUpdate: Date?
    var lastLineupsUpdate: Date?
    var lastStatsUpdate: Date?
    var lastCommentaryUpdate: Date?
    var eventsLoaded = false
    var lineupsLoaded = false
    var statsLoaded = false
    var officialsLoaded = false
}
