import Foundation

/// One side's state within a match — score, half-time score, and disciplinary count.
/// `team` carries only stable identity; display name/crest resolution happens at the
/// legacy-mapper boundary so this stays provider-independent.
nonisolated struct SoccerTeamMatchState: Codable, Sendable, Equatable {
    var team: SoccerTeam
    var score: Int?
    var halfTimeScore: Int?
    var redCards: Int
}

/// A single soccer match, independent of which league/provider produced it. Carries
/// optional cup-competition fields (aggregate score, penalties, leg, round, extra time,
/// shootout) so the same Soccer Game Centre can later host knockout competitions
/// (UCL, World Cup) without a model change, even though league play never sets them.
nonisolated struct SoccerMatch: Codable, Sendable, Equatable, Identifiable {
    let id: String                 // provider-native match identifier, preserved verbatim
    let competitionID: String
    let season: String             // starting year as a string, e.g. "2026"
    var matchWeek: Int?
    /// Raw provider phase/round marker (e.g. SDP's numeric "phase"), preserved for diagnostics.
    var phase: String?
    let kickoff: Date
    var status: SoccerMatchStatus
    var clock: SoccerMatchClock?
    var home: SoccerTeamMatchState
    var away: SoccerTeamMatchState
    var ground: String?
    var attendance: Int?
    /// Raw provider result-type marker (e.g. "NormalResult"), preserved for diagnostics.
    var resultType: String?
    /// Conference/group label (e.g. MLS "WESTERN CONFERENCE"), when the provider's
    /// competition structure has one. Nil for single-table leagues like EPL.
    var conference: String? = nil
    /// Provider's own competition display name (e.g. "Major League Soccer - Regular
    /// Season"), kept alongside `competitionID` since one competition ID can span
    /// multiple named phases (regular season vs. cup playoffs).
    var competitionName: String? = nil
    /// Raw provider data-freshness marker (e.g. MLS's "postmatch"/"live"), preserved
    /// for diagnostics — never used to derive `status`.
    var dataStatus: String? = nil

    // Generic knockout-competition fields — unused by EPL league play, present for reuse.
    var aggregateHome: Int?
    var aggregateAway: Int?
    var penaltyHome: Int?
    var penaltyAway: Int?
    var legNumber: Int?
    var roundName: String?
    var extraTime: Bool = false
    var shootout: Bool = false

    /// The side (home/away) matching a given team ID, or nil if it belongs to neither.
    func side(for teamID: String) -> SoccerTeamMatchState? {
        if home.team.id == teamID { return home }
        if away.team.id == teamID { return away }
        return nil
    }
}
