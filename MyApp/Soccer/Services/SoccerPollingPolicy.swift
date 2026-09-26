import Foundation

/// Adaptive poll cadence for one soccer provider's Game Centre, kept as data rather
/// than inline logic so EPL and MLS can each tune their own numbers without forking
/// `SoccerGameCentreViewModel`'s loop.
nonisolated struct SoccerPollingPolicy: Sendable {
    var live: TimeInterval
    var halftime: TimeInterval
    var pregameWithin15Min: TimeInterval
    var pregameWithin1Hour: TimeInterval
    var pregameBeyond1Hour: TimeInterval
    var delayedOrSuspended: TimeInterval
    var fallback: TimeInterval
    /// How often a "light" (tab-scoped) poll gets upgraded to a full refresh.
    var fullRefreshInterval: TimeInterval = 120

    func interval(for status: SoccerMatchStatus?, kickoff: Date?, failures: Int) -> TimeInterval {
        let base: TimeInterval
        switch status {
        case .firstHalf, .secondHalf, .stoppageTime, .extraFirstHalf, .extraSecondHalf, .penalties:
            base = live
        case .halftime, .extraHalftime:
            base = halftime
        case .scheduled, .pregame, .none:
            let untilKickoff = kickoff?.timeIntervalSinceNow ?? .infinity
            base = untilKickoff <= 900 ? pregameWithin15Min : untilKickoff <= 3600 ? pregameWithin1Hour : pregameBeyond1Hour
        case .delayed, .suspended:
            base = delayedOrSuspended
        default:
            base = fallback
        }
        return max(base, failures > 0 ? min(300, pow(2, Double(failures)) * 10) : 0)
    }
}

extension SoccerPollingPolicy {
    /// EPL Premier League cadence — unchanged from the pre-refactor `EPLGameCentreViewModel`.
    static let epl = SoccerPollingPolicy(live: 10, halftime: 25, pregameWithin15Min: 25, pregameWithin1Hour: 60, pregameBeyond1Hour: 300, delayedOrSuspended: 30, fallback: 60)
    /// MLS cadence per the integration brief: live overview/events every 8-12s, backing
    /// off the same way as EPL pregame/halftime/failure handling.
    static let mls = SoccerPollingPolicy(live: 10, halftime: 25, pregameWithin15Min: 25, pregameWithin1Hour: 60, pregameBeyond1Hour: 300, delayedOrSuspended: 30, fallback: 60)
    /// La Liga cadence: same shape as EPL/MLS. FotMob's own community-observed cache
    /// is ~10s live/15min upcoming/1hr finished (Step 31) — a 10s live poll lines up
    /// with that rather than hammering a host that won't return fresher data anyway.
    static let laliga = SoccerPollingPolicy(live: 10, halftime: 25, pregameWithin15Min: 25, pregameWithin1Hour: 60, pregameBeyond1Hour: 300, delayedOrSuspended: 30, fallback: 60)
}
