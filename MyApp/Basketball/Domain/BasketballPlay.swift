import Foundation

/// Structured play classification driven by `actionType`/`subType`, never by the
/// free-text description alone. Unrecognized future action types decode into
/// `.unknown(rawValue)` and stay displayable rather than being dropped.
nonisolated enum NBAPlayType: Codable, Sendable, Equatable {
    case madeShot, missedShot, freeThrow, rebound, assist, turnover, steal, block
    case personalFoul, shootingFoul, offensiveFoul, technicalFoul, flagrantFoul
    case substitution, timeout, jumpBall, violation
    case periodStart, periodEnd, gameEnd, instantReplay
    case unknown(String)

    init(actionType: String, subType: String?, shotResult: String?) {
        switch actionType.lowercased() {
        case "2pt", "3pt": self = (shotResult?.lowercased() == "missed") ? .missedShot : .madeShot
        case "freethrow": self = .freeThrow
        case "rebound": self = .rebound
        case "assist": self = .assist
        case "turnover": self = .turnover
        case "steal": self = .steal
        case "block": self = .block
        case "foul":
            let sub = (subType ?? "").lowercased()
            if sub.contains("shooting") { self = .shootingFoul }
            else if sub.contains("offensive") || sub.contains("charge") { self = .offensiveFoul }
            else if sub.contains("technical") { self = .technicalFoul }
            else if sub.contains("flagrant") { self = .flagrantFoul }
            else { self = .personalFoul }
        case "substitution": self = .substitution
        case "timeout": self = .timeout
        case "jumpball": self = .jumpBall
        case "violation": self = .violation
        case "period": self = (subType ?? "").lowercased().contains("end") ? .periodEnd : .periodStart
        case "game": self = .gameEnd
        case "instant_replay", "replay": self = .instantReplay
        default: self = .unknown(actionType)
        }
    }
    var isShot: Bool { self == .madeShot || self == .missedShot }
    var isScoring: Bool { self == .madeShot || self == .freeThrow }
    var isFoul: Bool { [.personalFoul, .shootingFoul, .offensiveFoul, .technicalFoul, .flagrantFoul].contains(self) }
}

/// Priority tiers driving visual weight in the Play-by-Play timeline (Step 30).
nonisolated enum NBAPlayPriority: Int, Codable, Sendable, Comparable {
    case compact = 0, medium = 1, high = 2
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Court-relative feet, origin at the basket, verified only by `BasketballCourtCoordinateTransformer`.
nonisolated struct NBAShotCoordinate: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let distanceFeet: Double?
    let made: Bool
    let value: Int
}

nonisolated struct NBAPlayEvent: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let gameID: BasketballGameID
    let actionNumber: Int?
    let orderNumber: Int?
    let period: Int
    let clockText: String?
    let type: NBAPlayType
    let teamID: Int?
    let teamTricode: String?
    let personID: Int?
    let playerName: String?
    let title: String
    let subtitle: String?
    let scoreHome: Int?
    let scoreAway: Int?
    let isFieldGoal: Bool
    let shot: NBAShotCoordinate?
    let isPeriodBoundary: Bool
    let priority: NBAPlayPriority
    let assistPlayerName: String?
    let videoAvailable: Bool

    /// Deterministic tie-break for actions sharing the same clock value.
    var sortKey: Int { orderNumber ?? actionNumber ?? 0 }

    /// The one comparator every league's play mapper *and* `BasketballGameCenterReducer`
    /// use — living here (not on any one league's mapper) is what lets the shared
    /// reducer call it without depending on `MyApp/NBA` or `MyApp/WNBA` specifically.
    static func sorted(_ events: [NBAPlayEvent]) -> [NBAPlayEvent] {
        events.sorted { $0.sortKey == $1.sortKey ? $0.id < $1.id : $0.sortKey < $1.sortKey }
    }
}
