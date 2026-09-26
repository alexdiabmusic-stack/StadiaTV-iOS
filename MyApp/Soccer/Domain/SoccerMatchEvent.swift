import Foundation

/// Canonical event vocabulary. Only mapped when a provider's structured fields
/// actually support the interpretation (never inferred from commentary text) — see
/// EPLEventMapper/MLSEventMapper. `.unknown` preserves the raw provider string so a
/// future event type never crashes or silently vanishes. The shot/set-piece cases
/// exist for providers with a richer structured timeline (MLS) — EPL's mapper never
/// emits them.
nonisolated enum SoccerEventType: Codable, Sendable, Equatable {
    case goal, ownGoal, penaltyGoal, missedPenalty
    case yellowCard, secondYellow, redCard
    case substitution
    case varEvent
    case periodStart, halftime, periodEnd
    case shotSaved, shotBlocked, shotOffTarget, woodwork
    case corner, offside, foul
    case penaltyWon, penaltySaved
    case unknown(String)

    /// Visual weight for a Game Centre timeline: goals/reds/penalties/VAR deserve a
    /// large card, cards/subs/shots-on-target a medium row, and low-signal incidents
    /// (corners, offsides, fouls) a compact line so the timeline doesn't turn every
    /// routine touch into a big card.
    var priority: SoccerEventPriority {
        switch self {
        case .goal, .ownGoal, .penaltyGoal, .redCard, .secondYellow, .varEvent, .missedPenalty, .penaltySaved: return .high
        case .yellowCard, .substitution, .shotSaved, .shotBlocked, .woodwork, .penaltyWon: return .medium
        case .shotOffTarget, .corner, .offside, .foul, .periodStart, .halftime, .periodEnd: return .compact
        case .unknown: return .compact
        }
    }
}

nonisolated enum SoccerEventPriority: Sendable, Equatable { case high, medium, compact }

/// A single match incident. The provider observed so far (PulseLive) supplies no
/// event ID, so `id` is synthesized from stable structured fields — never from
/// minute+description alone, since multiple incidents can share a minute (Step 16).
nonisolated struct SoccerMatchEvent: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let matchID: String
    let teamID: String
    let type: SoccerEventType
    /// Raw provider period marker (e.g. "FirstHalf"), preserved for clock-relative display.
    let period: String?
    /// Raw elapsed minute at the time of the event (not stoppage-adjusted display text).
    let minute: Int?
    let timestamp: Date?
    /// Primary actor: scorer, carded player, or player coming on for a substitution.
    let playerID: String?
    /// Assist provider (goal) or player going off (substitution) — never the same slot as `playerID`.
    let secondaryPlayerID: String?
    /// Tiebreaker for events sharing an identical timestamp within the same provider bucket.
    let ordinal: Int
    /// Optional provider-supplied free text for events that benefit from it (e.g. a
    /// shot's distance/result) — never required, never parsed back out for logic.
    var detail: String? = nil
}
