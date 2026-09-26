import Foundation

/// Stat keys mirror NBA/WNBA's own field names (`fieldGoalsMade`, `reboundsTotal`, …) so the
/// mapper can copy values straight across without inventing a parallel vocabulary.
nonisolated struct NBAPlayerGameLine: Codable, Sendable, Equatable, Identifiable {
    var id: Int { personID }
    let personID: Int
    let teamID: Int
    let name: String
    let nameInitial: String?
    let jerseyNum: String?
    let position: String?
    let order: Int?
    let starter: Bool
    let onCourt: Bool
    let played: Bool
    let status: String?
    let notPlayingReason: String?
    let notPlayingDescription: String?
    let minutesSeconds: Double?
    let stats: [String: Double]

    /// Whole minutes, matching NBA.com's own box-score convention (no seconds shown).
    var minutesText: String {
        guard let minutesSeconds else { return played ? "0" : "—" }
        return String(Int(minutesSeconds.rounded(.down)) / 60)
    }
    var isDNP: Bool { !played }
    func stat(_ key: String) -> Double? { stats[key] }
    func statInt(_ key: String) -> Int? { stats[key].map { Int($0.rounded()) } }
    var points: Int { statInt("points") ?? 0 }
    var rebounds: Int { statInt("reboundsTotal") ?? 0 }
    var assists: Int { statInt("assists") ?? 0 }
}

nonisolated struct NBATeamStatLine: Codable, Sendable, Equatable {
    let teamID: Int
    let stats: [String: Double]
    func stat(_ key: String) -> Double? { stats[key] }
}

/// This-game leaders, computed from currently-supplied box-score stats — safe because
/// it's simply the highest current value, never a season projection (Step 24).
nonisolated struct NBAStatLeader: Codable, Sendable, Equatable, Identifiable {
    var id: Int { personID }
    let personID: Int
    let name: String
    let value: Int
}
nonisolated struct NBATeamGameLeaders: Codable, Sendable, Equatable {
    var points: NBAStatLeader?
    var rebounds: NBAStatLeader?
    var assists: NBAStatLeader?
}
