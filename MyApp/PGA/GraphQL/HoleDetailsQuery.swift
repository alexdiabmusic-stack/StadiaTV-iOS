import Foundation

nonisolated enum HoleDetailsQuery {
    static let operation = PGAQuery(operationName: "HoleDetails", document: """
    query HoleDetails($tournamentId: ID!, $courseId: ID!, $hole: Int!) {
      holeDetails(tournamentId: $tournamentId, courseId: $courseId, hole: $hole) {
        id
        tournamentId
        statsAvailability
        holeNum
        courseId
        holeImage
        holeImageLandscape
        tourcastURL
        tourcastURLWeb
        statsSummary {
          tournamentId
          courseId
          holeNum
          eagles
          eaglesPercent
          birdies
          birdiesPercent
          pars
          parsPercent
          bogeys
          bogeysPercent
          doubleBogeys
          doubleBogeysPercent
        }
        holeInfo {
          holeNum
          par
          yards
          scoringAverageDiff
          aboutThisHole
          rank
        }
        rounds {
          roundNum
          groups {
            groupNumber
            groupLocation
            groupLocationCode
            tourcastURL
            tourcastURLWeb
            players {
              playerId
              firstName
              lastName
              countryFlag
              headshot
              position
              total
              roundScore
              country
            }
          }
        }
      }
    }
    """)
}
