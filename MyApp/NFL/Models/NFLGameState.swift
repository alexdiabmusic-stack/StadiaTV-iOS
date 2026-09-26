import Foundation

nonisolated struct NFLGameState: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let week: NFLWeek
    let start: Date
    var home: FootballTeamState
    var away: FootballTeamState
    var status: FootballGameStatus
    var statusText: String
    var quarter: String?
    var clock: String?
    var down: Int?
    var distance: Int?
    var goalToGo: Bool?
    var redZone: Bool?
    var field: FootballFieldPosition?
    var offset: Int?
    let venue: String?
    var weather: String?
    let broadcasts: [String]
    var drives: [FootballGameDrive]
    var plays: [FootballPlay]
    var summaryUpdated: Date
    var detailsUpdated: Date
    var possession: FootballTeamState? { home.possession ? home : away.possession ? away : nil }
    var downDistance: String? {
        guard let down, (1...4).contains(down) else { return nil }
        let ordinal = footballOrdinal(down)
        if goalToGo == true { return "\(ordinal) & GOAL" }
        return distance.map { "\(ordinal) & \($0)" }
    }
    var isRedZone: Bool? { redZone ?? field?.yardsToGoal.map { (0...20).contains($0) } }
    var currentDrive: FootballGameDrive? {
        guard [.live, .delayed].contains(status), let drive = drives.last else { return nil }
        let completed = ["touchdown", "field goal", "punt", "interception", "fumble", "downs", "missed field goal", "end of half", "end of game", "safety"]
        return completed.contains(drive.result?.lowercased() ?? "") ? nil : drive
    }
}

nonisolated struct NFLWeekChoice: Identifiable, Sendable {
    let week: NFLWeek
    let label: String
    var id: Int { week.week }
}
