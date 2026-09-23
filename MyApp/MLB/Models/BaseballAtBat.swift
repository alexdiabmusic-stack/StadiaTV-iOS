import Foundation

nonisolated enum BaseballResultType: Codable, Sendable, Equatable {
    case homeRun, single, double, triple, strikeout, walk, hitByPitch, sacrificeFly, doublePlay, error, stolenBase, caughtStealing, wildPitch, passedBall, pitchingChange, substitution, review, out
    case unknown(String)
    init(_ raw: String) {
        switch raw {
        case "home_run": self = .homeRun
        case "single": self = .single
        case "double": self = .double
        case "triple": self = .triple
        case "strikeout", "strikeout_double_play": self = .strikeout
        case "walk", "intent_walk": self = .walk
        case "hit_by_pitch": self = .hitByPitch
        case "sac_fly", "sac_fly_double_play": self = .sacrificeFly
        case "grounded_into_double_play", "double_play": self = .doublePlay
        case "field_error", "error": self = .error
        case "stolen_base_2b", "stolen_base_3b", "stolen_base_home": self = .stolenBase
        case "caught_stealing_2b", "caught_stealing_3b", "caught_stealing_home": self = .caughtStealing
        case "wild_pitch": self = .wildPitch
        case "passed_ball": self = .passedBall
        case "pitching_substitution": self = .pitchingChange
        case "offensive_substitution", "defensive_substitution", "defensive_switch": self = .substitution
        case "review", "umpire_review", "manager_challenge": self = .review
        case "field_out", "force_out", "sac_bunt", "fielders_choice_out": self = .out
        default: self = .unknown(raw)
        }
    }
}
nonisolated struct BaseballPitchCoordinates: Codable, Sendable, Equatable {
    let plateX: Double
    let plateZ: Double
    let zoneTop: Double
    let zoneBottom: Double
}
nonisolated struct BaseballPlayEvent: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let index: Int
    let type: String
    let resultType: BaseballResultType
    let isPitch: Bool
    let pitchNumber: Int?
    let description: String
    let pitchTypeCode: String?
    let pitchTypeDescription: String?
    let callCode: String?
    let callDescription: String?
    let startSpeed: Double?
    let endSpeed: Double?
    let zone: Int?
    let spinRate: Double?
    let spinDirection: Double?
    let count: BaseballCount
    let isBall: Bool
    let isStrike: Bool
    let isInPlay: Bool
    let coordinates: BaseballPitchCoordinates?
    let hitDistance: Double?
    let exitVelocity: Double?
}
nonisolated struct BaseballRunnerMovement: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let runner: BaseballPlayerReference?
    let start: String?
    let end: String?
    let isOut: Bool
    let outBase: String?
    let responsiblePitcher: BaseballPlayerReference?
    let reason: String?
    let earned: Bool?
    let scored: Bool
}
nonisolated struct BaseballAtBat: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(gamePk):\(atBatIndex)" }
    let gamePk: Int
    let atBatIndex: Int
    let inning: Int
    let halfInning: BaseballHalfInning
    let batter: BaseballPlayerReference?
    let pitcher: BaseballPlayerReference?
    let resultType: BaseballResultType
    let resultTitle: String
    let resultDescription: String
    let rbi: Int?
    let awayScore: Int?
    let homeScore: Int?
    let isComplete: Bool
    let isScoringPlay: Bool
    let events: [BaseballPlayEvent]
    let runners: [BaseballRunnerMovement]
    let finalCount: BaseballCount
    let endTime: Date?
    var inningLabel: String { "\(halfInning == .top ? "Top" : halfInning == .bottom ? "Bottom" : "Inning") \(inning)" }
}
