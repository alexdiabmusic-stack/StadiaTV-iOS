import Foundation

/// Pure cadence policy (STEP 76-80/107) — no state of its own, so it's easy
/// to reason about and to unit test. `.infinity` means "stop polling this
/// entirely"; callers must check `.isFinite` before sleeping on the result.
nonisolated enum PGALiveRefreshCoordinator {
    static func leaderboardInterval(for status: GolfTournamentStatus) -> TimeInterval {
        switch status {
        case .roundInProgress: return 15
        case .roundSuspended: return 45
        case .roundNotStarted, .scheduled: return 180
        case .roundComplete: return 300
        case .tournamentComplete, .cancelled: return .infinity
        case .unknown: return 60
        }
    }

    static func currentLeadersInterval(for status: GolfTournamentStatus) -> TimeInterval {
        status.isLive ? 20 : 120
    }

    static func selectedPlayerInterval(for status: GolfTournamentStatus) -> TimeInterval {
        status.isLive ? 15 : 60
    }

    static let teeTimesInterval: TimeInterval = 300
    static let courseInterval: TimeInterval = 600
    static let weatherInterval: TimeInterval = 900
    static let fedExInterval: TimeInterval = 600
}
