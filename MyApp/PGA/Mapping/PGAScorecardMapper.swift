import Foundation

/// Maps the decompressed `ScorecardCompressedV3` payload. Holes are split
/// across `firstNine`/`secondNine` sub-objects upstream; this flattens them
/// back into one ordered `holes` array per round, using `sequenceNumber`
/// (when present) to preserve true play order for players who started on
/// the back nine (STEP 72).
nonisolated enum PGAScorecardMapper {
    static func scorecard(_ value: PGAValue, tournamentID: String, playerID: String) -> GolfScorecard {
        let rounds = value["roundScores"].array.map(round)
        return GolfScorecard(tournamentID: tournamentID, playerID: playerID, rounds: rounds)
    }

    private static func round(_ value: PGAValue) -> GolfRoundScorecard {
        let holes = value["firstNine"]["holes"].array.map(hole) + value["secondNine"]["holes"].array.map(hole)
        return GolfRoundScorecard(
            roundNumber: value["roundNumber"].int ?? 0,
            courseName: value["courseName"].string,
            totalStrokes: value["total"].int,
            scoreToParDisplay: value["scoreToPar"].string,
            holes: holes.sorted { $0.holeNumber < $1.holeNumber }
        )
    }

    private static func hole(_ value: PGAValue) -> GolfHoleScore {
        GolfHoleScore(
            holeNumber: value["holeNumber"].int ?? 0,
            par: value["par"].int,
            yardage: value["yardage"].int,
            strokes: value["score"].int,
            statusRaw: value["status"].string,
            sequenceNumber: value["sequenceNumber"].int
        )
    }
}
