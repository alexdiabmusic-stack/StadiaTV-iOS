import Foundation

nonisolated struct HockeyPeriod: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case regulation, overtime, shootout, unknown }
    let number: Int
    let kind: Kind
    let regulationPeriods: Int
    init(raw: NHLValue) {
        number = raw["number"].int ?? 0
        regulationPeriods = raw["maxRegulationPeriods"].int ?? 3
        switch raw["periodType"].string {
        case "REG": kind = .regulation
        case "OT": kind = .overtime
        case "SO": kind = .shootout
        default: kind = .unknown
        }
    }
    var label: String {
        switch kind {
        case .shootout: return "Shootout"
        case .overtime: let count = max(1, number - regulationPeriods); return count == 1 ? "OT" : "\(count)OT"
        case .regulation: return ["1st", "2nd", "3rd"].indices.contains(number - 1) ? ["1st", "2nd", "3rd"][number - 1] + " period" : "Period \(number)"
        case .unknown: return number > 0 ? "Period \(number)" : "Pregame"
        }
    }
}
nonisolated enum HockeyEventType: Codable, Hashable, Sendable {
    case faceoff, hit, giveaway, goal, shot, missedShot, blockedShot, penalty, stoppage
    case periodStart, periodEnd, shootoutComplete, gameEnd, takeaway, delayedPenalty, failedShot
    case unknown(rawValue: String)
    init(key: String?, code: Int?) {
        let fallback = [502:"faceoff",503:"hit",504:"giveaway",505:"goal",506:"shot-on-goal",507:"missed-shot",508:"blocked-shot",509:"penalty",516:"stoppage",520:"period-start",521:"period-end",523:"shootout-complete",524:"game-end",525:"takeaway",535:"delayed-penalty",537:"failed-shot-attempt"]
        switch key ?? code.flatMap({ fallback[$0] }) ?? "" {
        case "faceoff": self = .faceoff
        case "hit": self = .hit
        case "giveaway": self = .giveaway
        case "goal": self = .goal
        case "shot-on-goal": self = .shot
        case "missed-shot": self = .missedShot
        case "blocked-shot": self = .blockedShot
        case "penalty": self = .penalty
        case "stoppage": self = .stoppage
        case "period-start": self = .periodStart
        case "period-end": self = .periodEnd
        case "shootout-complete": self = .shootoutComplete
        case "game-end": self = .gameEnd
        case "takeaway": self = .takeaway
        case "delayed-penalty": self = .delayedPenalty
        case "failed-shot-attempt": self = .failedShot
        default: self = .unknown(rawValue: key ?? code.map(String.init) ?? "")
        }
    }
    var isShot: Bool { [.shot, .missedShot, .blockedShot, .failedShot].contains(self) }
    var isBoundary: Bool { [.periodStart, .periodEnd, .shootoutComplete, .gameEnd].contains(self) }
}
nonisolated struct HockeyPlayerReference: Identifiable, Codable, Hashable, Sendable {
    let id: Int
    let name: String
    let teamID: Int?
    let jersey: Int?
    let position: String?
    let headshot: URL?
}
nonisolated struct HockeyPlayEvent: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let nhlEventID: Int?
    let sortOrder: Int
    let period: HockeyPeriod
    let timeInPeriod: String?
    let timeRemaining: String?
    let eventType: HockeyEventType
    let teamID: Int?
    let title: String
    let subtitle: String?
    let xCoordinate: Double?
    let yCoordinate: Double?
    let homeTeamDefendingSide: String?
    let homeScore: Int?
    let awayScore: Int?
    let homeShots: Int?
    let awayShots: Int?
    let primaryPlayer: HockeyPlayerReference?
    let secondaryPlayer: HockeyPlayerReference?
    let tertiaryPlayer: HockeyPlayerReference?
    let assists: [HockeyPlayerReference]
    let shotType: String?
    var strength: String?
    var videoURL: URL?
    let rawSituationCode: String?
    let shootoutRound: Int?
    var scorerSeasonGoals: Int? = nil
    var assistSeasonTotals: [Int: Int] = [:]
}
nonisolated struct HockeyTeam: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let abbreviation: String
    let name: String
    let logo: URL?
    let score: Int?
    let shots: Int?
}
nonisolated struct HockeyGame: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let start: Date
    let status: BannerGameStatus
    let period: HockeyPeriod
    let clock: String?
    let secondsRemaining: Int?
    let clockRunning: Bool
    let intermission: Bool
    let home: HockeyTeam
    let away: HockeyTeam
    let broadcasts: [String]
    let venue: String?
    let gameCenterURL: URL?
    var statusLabel: String {
        if status == .final { return "FINAL" + (period.kind == .overtime || period.kind == .shootout ? " · " + period.label : "") }
        if status == .live { return (intermission ? "INTERMISSION" : "LIVE") + " · " + period.label }
        switch status {
        case .postponed: return "Postponed"
        case .suspended: return "Suspended"
        case .cancelled: return "Cancelled"
        case .delayed: return "Delayed"
        case .unknown: return "Status unavailable"
        default: return start.formatted(date: .abbreviated, time: .shortened)
        }
    }
}
nonisolated struct HockeyStat: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
}
nonisolated struct HockeyPlayerGameStats: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let teamID: Int
    let group: String
    let player: HockeyPlayerReference
    let stats: [HockeyStat]
}
nonisolated struct HockeyTeamComparison: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let away: String
    let home: String
}
nonisolated struct HockeyGameCenterSnapshot: Codable, Equatable, Sendable {
    let gameID: Int
    var game: HockeyGame?
    var events: [HockeyPlayEvent] = []
    var scoringSummary: [HockeyPlayEvent] = []
    var players: [HockeyPlayerGameStats] = []
    var teamStats: [HockeyTeamComparison] = []
    var recapURL: URL?
    var fetchedAt: Date = .distantPast
    var landingLoaded = false
    var boxscoreLoaded = false
    var playsLoaded = false
}
