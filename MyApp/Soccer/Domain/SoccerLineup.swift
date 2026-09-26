import Foundation

/// A player's lineup slot. `isCaptain`/`position` are only set when the provider
/// actually supplies them — never inferred.
nonisolated struct SoccerLineupPlayer: Codable, Sendable, Equatable, Identifiable {
    var id: String { reference.id }
    let reference: SoccerPlayerReference
    var shirtNumber: String?
    var position: String?
    var isCaptain: Bool
    var isStarter: Bool
    /// A provider's own match rating (e.g. FotMob's 0–10 scale), when supplied.
    /// Must always be labelled with its source in UI ("FotMob Rating") — never
    /// presented as an official league metric (Step 23). EPL/MLS never set this.
    var rating: Double? = nil
}

/// A formation as the provider actually grouped it — `rows` is real structured data
/// (player IDs grouped goalkeeper-first, then each tactical line), not derived by
/// parsing the display string. A pitch view renders directly from `rows` and only
/// needs `raw` for the on-screen label (e.g. "4-2-3-1"). Any formation the provider
/// supplies works without a hardcoded list of known formations.
nonisolated struct SoccerFormation: Codable, Sendable, Equatable {
    let raw: String
    let rows: [[String]]   // player IDs, grouped goalkeeper-first through most advanced line
}

/// One team's lineup for a match. `nil` (not an empty `SoccerLineup`) is how a
/// caller should represent "not announced yet" — PulseLive returns HTTP 200 with an
/// empty players array before lineups are released (Step 34/51), which the mapper
/// turns into `nil` rather than a zero-player lineup.
nonisolated struct SoccerLineup: Codable, Sendable, Equatable {
    let team: SoccerTeam
    let formation: SoccerFormation?
    let starters: [SoccerLineupPlayer]
    let substitutes: [SoccerLineupPlayer]
    var managerName: String?
}
