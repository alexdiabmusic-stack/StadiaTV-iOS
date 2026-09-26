import Foundation

/// Shared by every football league — NFL and CFL construct the same leaf types from their
/// own, entirely different network schemas; nothing here depends on either league's raw
/// wire format.
nonisolated enum FootballGameStatus: String, Codable, Sendable {
    case scheduled, pregame, live, halftime, delayed, suspended, postponed, cancelled, final, unknown
    var polls: Bool { ![.final, .cancelled, .postponed].contains(self) }
}
nonisolated struct FootballTeamState: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let abbreviation: String
    let logo: URL?
    var score: Int?
    var quarters: [String: Int]
    var possession: Bool
}
nonisolated struct FootballFieldPosition: Codable, Equatable, Sendable {
    let text: String
    let sideAbbreviation: String?
    let yard: Int?
    let yardsToGoal: Int?
}
nonisolated struct FootballGameDrive: Codable, Equatable, Identifiable, Sendable {
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
nonisolated struct FootballPlayParticipant: Codable, Equatable, Sendable {
    let id: String?
    let name: String
    let teamID: String?
    let rawStatType: Int?
    let yards: Int?
}
/// `totalDowns` travels with the play itself (rather than being looked up from a league
/// config at render time) so a shared play row can never accidentally borrow another
/// league's down count.
nonisolated struct FootballPlay: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sequence: Double
    let driveSequence: Int?
    let quarter: Int?
    let clock: String?
    let down: Int?
    let distance: Int?
    let goalToGo: Bool
    let field: String?
    let type: FootballPlayType
    let text: String
    let yards: Int?
    let scoring: Bool
    let turnover: Bool
    let penalty: Bool
    let teamID: String?
    let participants: [FootballPlayParticipant]
    let totalDowns: Int
}
/// `.single` is CFL's rouge — a real 1-point score distinct from `.extraPoint`'s convert
/// kick, never conflated with it.
nonisolated enum FootballPlayType: Codable, Equatable, Sendable {
    case run, pass, passIncomplete, sack, interception, fumble, punt, kickoff, fieldGoal, fieldGoalMissed, extraPoint, extraPointMissed, twoPoint, penalty, timeout, kneel, spike, touchdown, safety, single, review, quarterEnd, gameEnd, unknown(String)
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
        case .single: "Single (Rouge)"
        case .review: "Review"
        case .quarterEnd: "End of quarter"
        case .gameEnd: "Final"
        case .unknown: "Play"
        }
    }
}
