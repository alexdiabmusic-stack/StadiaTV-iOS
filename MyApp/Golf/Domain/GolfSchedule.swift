import Foundation

/// One season-schedule row (`schedule/{tour}/{year}`). Deliberately
/// lightweight — this is the catalog list, not full tournament metadata
/// (that's `GolfTournament`, fetched separately and only when a tournament
/// is actually opened).
nonisolated struct GolfScheduleEntry: Identifiable, Codable, Sendable, Hashable {
    var id: String { tournamentID.rawValue }
    let tournamentID: GolfTournamentID
    let name: String
    let year: Int?
    let month: String?
    let displayDate: String?
    let statusRaw: String?
    let purseDisplay: String?
    let fedExCupPointsDisplay: String?
    let championDisplayName: String?
    let championEarningsDisplay: String?
    let courseName: String?
    let city: String?
    let state: String?
    let country: String?
    let tournamentSiteURL: URL?
}

nonisolated struct GolfSeasonSchedule: Codable, Sendable, Hashable {
    let tour: String
    let year: Int
    let tournaments: [GolfScheduleEntry]
}
