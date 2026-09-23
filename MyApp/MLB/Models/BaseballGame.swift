import Foundation

nonisolated enum BaseballGameStatus: String, Codable, Sendable {
    case scheduled, pregame, warmup, live, delayed, suspended, postponed, cancelled, final, unknown
    var stopsPolling: Bool { [.final, .postponed, .cancelled].contains(self) }
}
nonisolated struct BaseballTeam: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let name: String
    let abbreviation: String
    var runs: Int?
    var record: String?
    var logo: URL? { URL(string: "https://www.mlbstatic.com/team-logos/share/\(id).jpg") }
}
nonisolated struct BaseballPlayerReference: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let name: String
    var position: String?
    var jersey: String?
}
nonisolated struct BaseballGame: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let start: Date
    var away: BaseballTeam
    var home: BaseballTeam
    var status: BaseballGameStatus
    var detailedStatus: String
    var venue: String?
    var weather: String?
    var season: Int?
    var gameType: String?
    var gameGuid: String?
    var officialDate: String?
    var doubleHeader: String?
    var gameNumber: Int?
    var seriesGameNumber: Int?
    var seriesDescription: String?
    var scheduledInnings: Int?
    var probableAway: BaseballPlayerReference?
    var probableHome: BaseballPlayerReference?
    var broadcasts: [String] = []
}
nonisolated enum BaseballHalfInning: String, Codable, Sendable {
    case top, bottom, unknown
}
nonisolated struct BaseballCount: Codable, Sendable, Equatable {
    let balls: Int?
    let strikes: Int?
    let outs: Int?
}
nonisolated struct BaseballBaseState: Codable, Sendable, Equatable {
    var first: BaseballPlayerReference?
    var second: BaseballPlayerReference?
    var third: BaseballPlayerReference?
    var occupied: [Bool] { [first != nil, second != nil, third != nil] }
    var accessibilityLabel: String {
        let names = zip(occupied, ["first", "second", "third"]).filter { $0.0 }.map(\.1)
        if names.count == 3 { return "Bases loaded" }
        return names.isEmpty ? "Bases empty" : "Runners on " + names.joined(separator: " and ")
    }
}
nonisolated struct BaseballInningLine: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let awayRuns: Int?
    let homeRuns: Int?
}
nonisolated struct BaseballLineScore: Codable, Sendable, Equatable {
    let currentInning: Int?
    let inningState: String?
    let scheduledInnings: Int?
    let count: BaseballCount
    let bases: BaseballBaseState
    let batter: BaseballPlayerReference?
    let pitcher: BaseballPlayerReference?
    let awayRuns: Int?
    let homeRuns: Int?
    let awayHits: Int?
    let homeHits: Int?
    let awayErrors: Int?
    let homeErrors: Int?
    let innings: [BaseballInningLine]
    var betweenInnings: Bool { ["middle", "end"].contains(inningState?.lowercased() ?? "") || count.outs == 3 }
    var label: String { [inningState, currentInning.map { "\($0)" }].compactMap { $0 }.joined(separator: " ") }
}
nonisolated struct BaseballBoxPlayer: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(teamID):\(player.id)" }
    let teamID: Int
    let player: BaseballPlayerReference
    let battingOrder: Int?
    let batting: [String: String]
    let pitching: [String: String]
    let fielding: [String: String]
}
nonisolated struct BaseballHighlight: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let url: URL
}
nonisolated struct BaseballWinProbability: Codable, Sendable, Equatable, Identifiable {
    var id: Int { atBatIndex }
    let atBatIndex: Int
    let homePercent: Double
}
nonisolated struct BaseballGameSnapshot: Codable, Sendable, Equatable {
    let gamePk: Int
    var game: BaseballGame?
    var line: BaseballLineScore?
    var atBats: [BaseballAtBat] = []
    var players: [Int: BaseballPlayerReference] = [:]
    var box: [BaseballBoxPlayer] = []
    var highlights: [BaseballHighlight] = []
    var probabilities: [BaseballWinProbability] = []
    var fetchedAt: Date = .distantPast
    var timestamp: String?
    var playsLoaded = false
    var boxLoaded = false
}
