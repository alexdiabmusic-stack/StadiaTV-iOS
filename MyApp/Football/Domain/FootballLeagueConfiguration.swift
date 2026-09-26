import Foundation

nonisolated enum FootballLeague: String, Codable, Sendable {
    case nfl, cfl
}

/// Centralizes the rules that genuinely differ between American and Canadian football —
/// down count and field dimensions — so a league's Game Centre never silently inherits
/// another league's hardcoded assumptions.
nonisolated struct FootballLeagueConfiguration: Sendable {
    let league: FootballLeague
    let downs: Int
    let fieldLength: Int
    let endZoneLength: Int
    let leaguePath: String
    let displayName: String

    static let nfl = FootballLeagueConfiguration(league: .nfl, downs: 4, fieldLength: 100, endZoneLength: 10, leaguePath: "football/nfl", displayName: "NFL")
    static let cfl = FootballLeagueConfiguration(league: .cfl, downs: 3, fieldLength: 110, endZoneLength: 20, leaguePath: "football/cfl", displayName: "CFL")
}

/// Pure geometry for the field visual — CFL's 110-yard field with 20-yard end zones renders
/// at genuinely different proportions than NFL's 100-yard field, never a relabeled copy.
nonisolated struct FootballFieldGeometry: Sendable {
    let fieldLength: Int
    let endZoneLength: Int
    var tickCount: Int { fieldLength / 10 + 1 }
    func ballOffsetFraction(yardsToGoal: Int) -> Double { Double(fieldLength - yardsToGoal) / Double(fieldLength) }

    static let nfl = FootballFieldGeometry(fieldLength: 100, endZoneLength: 10)
    static let cfl = FootballFieldGeometry(fieldLength: 110, endZoneLength: 20)
}

/// Ordinal-suffix formatting for down count ("1ST", "2ND", "3RD" for CFL; up to "4TH" for
/// NFL) — one implementation instead of a fixed 1-4 dictionary that silently caps at 4.
nonisolated func footballOrdinal(_ n: Int) -> String {
    let suffix: String
    switch n % 10 {
    case 1 where n % 100 != 11: suffix = "ST"
    case 2 where n % 100 != 12: suffix = "ND"
    case 3 where n % 100 != 13: suffix = "RD"
    default: suffix = "TH"
    }
    return "\(n)\(suffix)"
}
