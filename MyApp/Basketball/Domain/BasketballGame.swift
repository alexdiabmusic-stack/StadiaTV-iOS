import Foundation

nonisolated enum BasketballGameStatus: String, Codable, Sendable {
    case scheduled, pregame, live, halftime, delayed, postponed, suspended, final, cancelled, unknown
    var stopsPolling: Bool { [.final, .postponed, .cancelled].contains(self) }
}

nonisolated struct NBAQuarterScore: Codable, Sendable, Equatable, Identifiable {
    var id: Int { period }
    let period: Int
    let periodType: String?
    let score: Int
    var label: String { NBADuration.periodLabel(period) }
}

nonisolated struct BasketballTeam: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let city: String
    let name: String
    let tricode: String
    var slug: String?
    var wins: Int?
    var losses: Int?
    var score: Int?
    var timeoutsRemaining: Int?
    var inBonus: Bool?
    var periods: [NBAQuarterScore] = []
    var seed: Int?
    var displayName: String { [city, name].filter { !$0.isEmpty }.joined(separator: " ") }
    var record: String? {
        guard let wins, let losses else { return nil }
        return "\(wins)-\(losses)"
    }
    /// Local bundled asset, matching NHL's convention — NBA/WNBA remote logos are
    /// SVG (unsupported by AsyncImage); each league's own asset catalog entries
    /// use this same `{League}Logo_{tricode}` naming.
    var logo: URL? { URL(string: "banner-asset:/NBALogo_\(tricode)") }
}

nonisolated struct NBAOfficial: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let name: String
    let jerseyNum: String?
    let assignment: String?
}

nonisolated struct NBAArena: Codable, Sendable, Equatable {
    var name: String?
    var city: String?
    var state: String?
    var country: String?
    var timezone: String?
    var isEmpty: Bool { name == nil && city == nil }
}

nonisolated struct NBAGameLeaderLine: Codable, Sendable, Equatable {
    var personID: Int?
    var name: String?
    var teamTricode: String?
    var points: Int?
    var rebounds: Int?
    var assists: Int?
}

nonisolated struct BasketballGame: Codable, Sendable, Equatable, Identifiable {
    let id: BasketballGameID
    var gameCode: String?
    let start: Date
    var away: BasketballTeam
    var home: BasketballTeam
    var status: BasketballGameStatus
    var rawStatus: Int?
    var statusText: String
    var period: Int
    var regulationPeriods: Int
    var gameClock: TimeInterval?
    var arena: NBAArena?
    var attendance: Int?
    var officials: [NBAOfficial] = []
    var seriesGameNumber: String?
    var seriesText: String?
    var gameLabel: String?
    var gameSubLabel: String?
    var gameSubtype: String?
    var homeLeader: NBAGameLeaderLine?
    var awayLeader: NBAGameLeaderLine?
    var broadcasts: [String] = []

    var isOvertime: Bool { period > regulationPeriods }
    var periodLabel: String { NBADuration.periodLabel(period, regulation: regulationPeriods) }
    /// "FINAL", "FINAL/OT", "FINAL/2OT" — never just a bare "FINAL" once OT has occurred.
    var finalLabel: String { isOvertime ? "FINAL/\(periodLabel)" : "FINAL" }
}

nonisolated struct BasketballGameSnapshot: Codable, Sendable, Equatable {
    let gameID: BasketballGameID
    var game: BasketballGame?
    var homeBox: [NBAPlayerGameLine] = []
    var awayBox: [NBAPlayerGameLine] = []
    var homeTeamStats: NBATeamStatLine?
    var awayTeamStats: NBATeamStatLine?
    var homeLeaders: NBATeamGameLeaders?
    var awayLeaders: NBATeamGameLeaders?
    var plays: [NBAPlayEvent] = []
    var onCourtHome: [Int] = []
    var onCourtAway: [Int] = []
    var shots: [NBAShotCoordinate] = []
    var fetchedAt: Date = .distantPast
    var lastScoreUpdate: Date?
    var lastBoxUpdate: Date?
    var lastPlayUpdate: Date?
    var timestamp: String?
    var source: String = "cdn"
    var playsLoaded = false
    var boxLoaded = false
}
