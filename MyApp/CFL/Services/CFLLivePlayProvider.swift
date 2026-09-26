import Foundation

/// Step 27: play-by-play must go through this abstraction, never a silently-invented
/// endpoint and never HTML scraping. No concrete conformer ships this pass — neither a
/// verified current keyless PBP route nor a legacy `api.cfl.ca` v1 key is available (and
/// Steps 28/29 forbid committing one to source control). `CFLGameCenterService` accepts
/// an optional conformer; when nil, `drives`/`plays` on `CFLGameState` simply stay empty
/// and the Plays tab shows "Detailed play-by-play is currently unavailable" — Overview,
/// Box Score, and Stats never depend on this and work fully without it.
nonisolated protocol CFLLivePlayProvider: Sendable {
    func drives(fixtureID: String) async throws -> [FootballGameDrive]
    // A future conformer MUST set `totalDowns: 3` on every constructed `FootballPlay` —
    // the shared type defaults to nothing and will happily carry NFL's 4 if a conformer
    // copies NFL's mapper without changing it, silently reintroducing the bug this whole
    // generalization pass exists to prevent.
    func plays(fixtureID: String) async throws -> [FootballPlay]
}
