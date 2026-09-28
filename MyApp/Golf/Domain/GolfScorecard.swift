import Foundation

/// Traditional scorecard shapes, not color alone (STEP 25/90 accessibility).
nonisolated enum GolfHoleScoreSymbol: Sendable, Hashable {
    case eagleOrBetter
    case birdie
    case par
    case bogey
    case doubleBogeyOrWorse
    case unknown

    init(strokes: Int?, par: Int?) {
        guard let strokes, let par else { self = .unknown; return }
        switch strokes - par {
        case ..<(-1): self = .eagleOrBetter
        case -1: self = .birdie
        case 0: self = .par
        case 1: self = .bogey
        default: self = .doubleBogeyOrWorse
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .eagleOrBetter: return "eagle or better"
        case .birdie: return "birdie"
        case .par: return "par"
        case .bogey: return "bogey"
        case .doubleBogeyOrWorse: return "double bogey or worse"
        case .unknown: return "no score"
        }
    }
}

nonisolated struct GolfHoleScore: Identifiable, Codable, Sendable, Hashable {
    var id: Int { holeNumber }
    let holeNumber: Int
    let par: Int?
    let yardage: Int?
    let strokes: Int?
    let statusRaw: String?
    /// Position within the round accounting for non-sequential starts (a
    /// player starting on hole 10 does not complete holes in 1→18 order) —
    /// STEP 72. Use this instead of `holeNumber` order when rendering.
    let sequenceNumber: Int?

    var symbol: GolfHoleScoreSymbol { GolfHoleScoreSymbol(strokes: strokes, par: par) }
}

nonisolated struct GolfRoundScorecard: Identifiable, Codable, Sendable, Hashable {
    var id: Int { roundNumber }
    let roundNumber: Int
    let courseName: String?
    let totalStrokes: Int?
    let scoreToParDisplay: String?
    let holes: [GolfHoleScore]

    var scoreToPar: GolfScore { GolfScore(raw: scoreToParDisplay) }
    var frontNine: [GolfHoleScore] { holes.filter { $0.holeNumber <= 9 }.sorted { ($0.sequenceNumber ?? $0.holeNumber) < ($1.sequenceNumber ?? $1.holeNumber) } }
    var backNine: [GolfHoleScore] { holes.filter { $0.holeNumber > 9 }.sorted { ($0.sequenceNumber ?? $0.holeNumber) < ($1.sequenceNumber ?? $1.holeNumber) } }
}

nonisolated struct GolfScorecard: Identifiable, Codable, Sendable, Hashable {
    var id: String { "\(tournamentID)-\(playerID)" }
    let tournamentID: String
    let playerID: String
    let rounds: [GolfRoundScorecard]
}
