import Foundation

nonisolated enum NFLGameStatus: String, Codable, Sendable {
    case scheduled, pregame, live, halftime, delayed, suspended, postponed, cancelled, final, unknown
    var polls: Bool { ![.final, .cancelled, .postponed].contains(self) }
}
nonisolated struct NFLTeamState: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let abbreviation: String
    let logo: URL?
    var score: Int?
    var quarters: [String: Int]
    var possession: Bool
}
nonisolated struct NFLFieldPosition: Codable, Equatable, Sendable {
    let text: String
    let sideAbbreviation: String?
    let yard: Int?
    let yardsToGoal: Int?
}
nonisolated struct NFLGameState: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let week: NFLWeek
    let start: Date
    var home: NFLTeamState
    var away: NFLTeamState
    var status: NFLGameStatus
    var statusText: String
    var quarter: String?
    var clock: String?
    var down: Int?
    var distance: Int?
    var goalToGo: Bool?
    var redZone: Bool?
    var field: NFLFieldPosition?
    var offset: Int?
    let venue: String?
    var weather: String?
    let broadcasts: [String]
    var drives: [NFLDrive]
    var plays: [NFLPlay]
    var summaryUpdated: Date
    var detailsUpdated: Date
    var possession: NFLTeamState? { home.possession ? home : away.possession ? away : nil }
    var downDistance: String? {
        guard let down, (1...4).contains(down) else { return nil }
        let ordinal = [1: "1ST", 2: "2ND", 3: "3RD", 4: "4TH"][down] ?? ""
        if goalToGo == true { return "\(ordinal) & GOAL" }
        return distance.map { "\(ordinal) & \($0)" }
    }
    var isRedZone: Bool? { redZone ?? field?.yardsToGoal.map { (0...20).contains($0) } }
    var currentDrive: NFLDrive? {
        guard [.live, .delayed].contains(status), let drive = drives.last else { return nil }
        let completed = ["touchdown", "field goal", "punt", "interception", "fumble", "downs", "missed field goal", "end of half", "end of game", "safety"]
        return completed.contains(drive.result?.lowercased() ?? "") ? nil : drive
    }
}
nonisolated struct NFLDrive: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sequence: Int
    let teamID: String?
    let startQuarter: Int?
    let endQuarter: Int?
    let startClock: String?
    let endClock: String?
    let startField: String?
    let endField: String?
    let playCount: Int?
    let yards: Int?
    let timeOfPossession: String?
    let result: String?
    let scoring: Bool
}
nonisolated struct NFLPlay: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sequence: Double
    let driveSequence: Int?
    let quarter: Int?
    let clock: String?
    let down: Int?
    let distance: Int?
    let goalToGo: Bool
    let field: String?
    let type: NFLPlayType
    let text: String
    let yards: Int?
    let scoring: Bool
    let turnover: Bool
    let penalty: Bool
    let teamID: String?
    let participants: [NFLPlayParticipant]
}
nonisolated struct NFLPlayParticipant: Codable, Equatable, Sendable {
    let id: String?
    let name: String
    let teamID: String?
    let rawStatType: Int?
    let yards: Int?
}
nonisolated enum NFLPlayType: Codable, Equatable, Sendable {
    case run, pass, passIncomplete, sack, interception, fumble, punt, kickoff, fieldGoal, fieldGoalMissed, extraPoint, extraPointMissed, twoPoint, penalty, timeout, kneel, spike, touchdown, safety, review, quarterEnd, gameEnd, unknown(String)
    var label: String {
        switch self {
        case .run: "Run"
        case .pass: "Pass"
        case .passIncomplete: "Incomplete pass"
        case .sack: "Sack"
        case .interception: "Interception"
        case .fumble: "Fumble"
        case .punt: "Punt"
        case .kickoff: "Kickoff"
        case .fieldGoal: "Field goal"
        case .fieldGoalMissed: "Missed field goal"
        case .extraPoint: "Extra point"
        case .extraPointMissed: "Missed extra point"
        case .twoPoint: "Two-point conversion"
        case .penalty: "Penalty"
        case .timeout: "Timeout"
        case .kneel: "Kneel"
        case .spike: "Spike"
        case .touchdown: "Touchdown"
        case .safety: "Safety"
        case .review: "Review"
        case .quarterEnd: "End of quarter"
        case .gameEnd: "Final"
        case .unknown: "Play"
        }
    }
}

nonisolated struct NFLWeekChoice: Identifiable, Sendable {
    let week: NFLWeek
    let label: String
    var id: Int { week.week }
}
