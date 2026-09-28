import Foundation

/// Maps the decompressed `LeaderboardCompressedV3` and `CurrentLeadersCompressed`
/// payloads. Both are decoded via `PGAPayloadDecoder` before reaching here —
/// this file only ever sees already-decompressed `PGAValue` JSON.
nonisolated enum PGALeaderboardMapper {
    /// Full leaderboard. `tournamentID` is passed in (rather than trusted
    /// from the payload) so a stale/mismatched payload can never mislabel
    /// itself into the wrong tournament's leaderboard.
    static func leaderboard(_ value: PGAValue, tournamentID: String) -> [GolfLeaderboardEntry] {
        value["players"].array.map { row(tournamentID: tournamentID, row: $0) }
    }

    private static func row(tournamentID: String, row value: PGAValue) -> GolfLeaderboardEntry {
        let player = PGAMappingSupport.player(value["player"])
        let scoring = value["scoringData"]
        let positionDisplay = scoring["position"].string
        return GolfLeaderboardEntry(
            tournamentID: tournamentID,
            player: player,
            positionDisplay: positionDisplay,
            positionSort: Self.derivedPositionSort(positionDisplay),
            totalDisplay: scoring["total"].string,
            totalSort: scoring["totalSort"].double,
            totalStrokes: scoring["totalStrokes"].int,
            currentRoundScoreDisplay: scoring["score"].string,
            thruDisplay: scoring["thru"].string,
            holesCompleted: Self.holesCompleted(scoring["thru"].string),
            currentRound: scoring["currentRound"].int,
            teeTime: PGAMappingSupport.epochMillis(scoring["teeTime"]),
            playerStateRaw: scoring["playerState"].string,
            courseID: scoring["courseId"].string,
            groupNumber: scoring["groupNumber"].int,
            startingNine: (scoring["backNine"].bool ?? false) ? .back : .front,
            roundScores: Self.rounds(scoring["rounds"]),
            movement: (scoring["movementDirection"].isNull && scoring["movementAmount"].isNull) ? nil :
                GolfLeaderboardMovement(directionRaw: scoring["movementDirection"].string, amountRaw: scoring["movementAmount"].string),
            official: scoring["official"].bool,
            projected: scoring["projected"].bool
        )
    }

    private static func rounds(_ value: PGAValue) -> [GolfRoundSummary] {
        value.array.enumerated().map { index, entry in
            let display = entry.string
            return GolfRoundSummary(roundNumber: index + 1, displayValue: display, strokes: display.flatMap { Int($0) })
        }
    }

    /// "Thru" can be "F", "F*", a hole number, or blank for not-yet-started.
    private static func holesCompleted(_ thru: String?) -> Int? {
        guard let thru else { return nil }
        return Int(thru.trimmingCharacters(in: CharacterSet(charactersIn: "*")))
    }

    /// The compressed payload doesn't carry a distinct `positionSort` field
    /// (only `totalSort`/`scoreSort`); this derives an approximate sort key
    /// from the display string so ties/CUT/WD still land at a sane relative
    /// position when the caller wants a pure position-only ordering. The
    /// leaderboard view itself should still prefer the provider's own row
    /// order (STEP 94) rather than resorting by this value.
    private static func derivedPositionSort(_ display: String?) -> Double? {
        guard let display else { return nil }
        let digits = display.trimmingCharacters(in: CharacterSet(charactersIn: "T"))
        return Double(digits)
    }

    /// Lightweight `CurrentLeadersCompressed` snapshot.
    static func currentLeaders(_ value: PGAValue) -> [GolfCurrentLeader] {
        value["players"].array.map { entry in
            GolfCurrentLeader(
                playerID: entry["id"].string ?? UUID().uuidString,
                firstName: entry["firstName"].string,
                lastName: entry["lastName"].string,
                displayName: entry["displayName"].string,
                country: entry["country"].string,
                positionDisplay: entry["position"].string,
                totalScoreDisplay: entry["totalScore"].string,
                thruDisplay: entry["thru"].string,
                roundScoreDisplay: entry["roundScore"].string,
                roundHeader: entry["roundHeader"].string,
                playerStateRaw: entry["playerState"].string,
                backNine: entry["backNine"].bool,
                groupNumber: entry["groupNumber"].int
            )
        }
    }
}
