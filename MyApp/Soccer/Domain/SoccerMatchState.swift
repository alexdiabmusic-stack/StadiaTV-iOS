import Foundation

/// Canonical match status, independent of any provider's raw vocabulary. Unknown
/// future provider states must decode into `.unknown` rather than crash or be dropped.
/// The extra-time/penalties cases exist for competitions that can go beyond 90
/// minutes (MLS playoffs, cups) — league play (EPL) never emits them.
nonisolated enum SoccerMatchStatus: Codable, Sendable, Equatable {
    case scheduled, pregame, firstHalf, halftime, secondHalf, stoppageTime
    case extraFirstHalf, extraHalftime, extraSecondHalf, penalties
    case delayed, suspended, postponed, cancelled, fullTime, abandoned
    case unknown(String)

    /// Once true, a Game Centre should stop aggressive polling.
    var stopsPolling: Bool {
        switch self {
        case .fullTime, .postponed, .cancelled, .abandoned: return true
        default: return false
        }
    }

    var isLive: Bool {
        switch self {
        case .firstHalf, .halftime, .secondHalf, .stoppageTime,
             .extraFirstHalf, .extraHalftime, .extraSecondHalf, .penalties: return true
        default: return false
        }
    }
}

/// The match clock as displayed to users. `minute`/`addedMinute` are derived from the
/// provider's raw total-minute clock plus the match period — never a locally-run timer.
/// The official feed is authoritative; a Game Centre may interpolate between updates
/// only while `SoccerMatchStatus.isLive` and must resynchronize on every new state.
nonisolated struct SoccerMatchClock: Codable, Sendable, Equatable {
    let minute: Int?
    let addedMinute: Int?
    let display: String
}
