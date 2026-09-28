import Foundation

nonisolated enum GolfStartingNine: String, Codable, Sendable, Hashable {
    case front
    case back
}

nonisolated struct GolfRoundSummary: Identifiable, Codable, Sendable, Hashable {
    var id: Int { roundNumber }
    let roundNumber: Int
    let displayValue: String?
    let strokes: Int?
}

nonisolated struct GolfLeaderboardMovement: Codable, Sendable, Hashable {
    enum Direction: String, Codable, Sendable, Hashable {
        case up, down, none, unknown
    }
    let direction: Direction
    let amount: Int?

    init(directionRaw: String?, amountRaw: String?) {
        switch directionRaw?.uppercased() {
        case "UP": direction = .up
        case "DOWN": direction = .down
        case "NONE", "NEUTRAL", "": direction = .none
        case .some: direction = .unknown
        case nil: direction = .unknown
        }
        amount = amountRaw.flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "+- "))) }
    }
}

/// One row of a tournament leaderboard. Field names mirror STEP 11 of the
/// Golf Tournament Centre spec; raw provider strings are preserved alongside
/// typed computed accessors (`total`, `currentRoundScore`, `playerState`) so
/// formatting logic lives in one place instead of scattered across views.
nonisolated struct GolfLeaderboardEntry: Identifiable, Codable, Sendable, Hashable {
    var id: String { player.id }

    let tournamentID: String
    let player: GolfPlayerReference

    let positionDisplay: String?
    let positionSort: Double?

    let totalDisplay: String?
    let totalSort: Double?
    let totalStrokes: Int?

    let currentRoundScoreDisplay: String?
    let thruDisplay: String?
    let holesCompleted: Int?

    let currentRound: Int?
    let teeTime: Date?

    let playerStateRaw: String?
    let courseID: String?
    let groupNumber: Int?
    let startingNine: GolfStartingNine?

    let roundScores: [GolfRoundSummary]
    let movement: GolfLeaderboardMovement?

    let official: Bool?
    let projected: Bool?

    var total: GolfScore { GolfScore(raw: totalDisplay) }
    var currentRoundScore: GolfScore { GolfScore(raw: currentRoundScoreDisplay) }
    var playerState: GolfPlayerState { GolfPlayerState(playerStateRaw: playerStateRaw, positionDisplay: positionDisplay) }
    var isTied: Bool { positionDisplay?.uppercased().hasPrefix("T") == true }

    /// "Thru 7" vs "Not Started" vs "F" — never "Thru 0" for a player who
    /// hasn't teed off (STEP 69).
    var statusText: String {
        if !playerState.isScoring, let label = playerState.shortLabel { return label }
        if playerState == .finished { return "F" }
        if playerState == .notStarted { return "Not Started" }
        if let thruDisplay, !thruDisplay.isEmpty { return "Thru \(thruDisplay)" }
        return playerState.accessibilityLabel
    }
}

/// Lightweight snapshot from `CurrentLeadersCompressed` — used for compact
/// home-screen / overview cards so a full leaderboard fetch isn't needed
/// just to show the top few golfers.
nonisolated struct GolfCurrentLeader: Identifiable, Codable, Sendable, Hashable {
    var id: String { playerID }
    let playerID: String
    let firstName: String?
    let lastName: String?
    let displayName: String?
    let country: String?
    let positionDisplay: String?
    let totalScoreDisplay: String?
    let thruDisplay: String?
    let roundScoreDisplay: String?
    let roundHeader: String?
    let playerStateRaw: String?
    let backNine: Bool?
    let groupNumber: Int?

    var totalScore: GolfScore { GolfScore(raw: totalScoreDisplay) }
    var playerState: GolfPlayerState { GolfPlayerState(playerStateRaw: playerStateRaw, positionDisplay: positionDisplay) }
}
