import Foundation

nonisolated struct GolfTeeGroupPlayer: Identifiable, Codable, Sendable, Hashable {
    var id: String
    let firstName: String?
    let lastName: String?
    let displayName: String?
    let country: String?
}

/// A tee-time grouping. Identity is `(round, groupNumber)` from the
/// provider, never derived by matching identical tee-time strings
/// (STEP 37) — that would incorrectly merge unrelated groups that happen to
/// start at the same clock time on different tees.
nonisolated struct GolfTeeGroup: Identifiable, Codable, Sendable, Hashable {
    var id: String { "\(roundNumber)-\(groupNumber)" }
    let roundNumber: Int
    let groupNumber: Int
    let teeTime: Date?
    /// 1 or 10 — tee times commonly start groups on both nines (STEP 71).
    let startingTee: Int?
    let backNine: Bool
    let players: [GolfTeeGroupPlayer]
}

nonisolated struct GolfTeeTimesRound: Identifiable, Codable, Sendable, Hashable {
    var id: Int { roundNumber }
    let roundNumber: Int
    let roundDisplay: String?
    let roundStatusRaw: String?
    let groups: [GolfTeeGroup]
}

nonisolated struct GolfTeeTimes: Codable, Sendable, Hashable {
    let tournamentID: String
    let timezoneIdentifier: String?
    let rounds: [GolfTeeTimesRound]

    var timeZone: TimeZone? { timezoneIdentifier.flatMap(TimeZone.init(identifier:)) }
}
