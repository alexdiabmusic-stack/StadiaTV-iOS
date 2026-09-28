import Foundation

nonisolated enum LeaderboardHoleByHoleQuery {
    static let operation = PGAQuery(operationName: "LeaderboardHoleByHole", document: """
    query LeaderboardHoleByHole($tournamentId: ID!, $round: Int) {
      leaderboardHoleByHole(tournamentId: $tournamentId, round: $round) {
        tournamentId
        tournamentName
        currentRound
        holeHeaders {
          holeNumber
          hole
          par
        }
        playerData {
          playerId
          out
          in
          total
          courseId
          courseCode
          totalToPar
          scores {
            holeNumber
            par
            yardage
            sequenceNumber
            score
            status
            roundScore
          }
        }
        courses {
          id
          courseName
          courseCode
          hostCourse
          scoringLevel
        }
        rounds {
          roundNumber
          displayText
        }
      }
    }
    """)
}
