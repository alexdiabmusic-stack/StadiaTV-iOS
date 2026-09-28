import Foundation

nonisolated enum CourseStatsQuery {
    static let operation = PGAQuery(operationName: "CourseStats", document: """
    query CourseStats($tournamentId: ID!) {
      courseStats(tournamentId: $tournamentId) {
        ...CourseStatsFragment
      }
    }

    fragment CourseStatsFragment on TournamentHoleStats {
      tournamentId
      courses {
        tournamentId
        courseId
        courseName
        courseCode
        holeDetailsAvailability
        par
        yardage
        hostCourse
        courseImage
        roundHoleStats {
          roundHeader
          roundNum
          live
          enablePaceOfPlay
          paceOfPlayLabelTitle
          paceOfPlayDescription
          paceOfPlayHeader
          scoringHeader
          holeStats {
            ... on CourseHoleStats {
              __typename
              paceOfPlay {
                ...PaceOfPlayFragment
              }
              averagePaceOfPlay
              courseHoleNum
              parValue
              yards
              scoringAverage
              scoringAverageDiff
              scoringDiffTendency
              eagles
              birdies
              pars
              bogeys
              doubleBogey
              rank
              holeImage
              live
            }
            ... on SummaryRow {
              __typename
              rowType
              par
              scoringAverageDiff
              scoringDiffTendency
              yardage
              scoringAverage
              eagles
              birdies
              pars
              bogeys
              doubleBogey
              averagePaceOfPlay
            }
          }
        }
        courseOverview {
          id
          image
          name
          city
          state
          country
        }
      }
    }

    fragment PaceOfPlayFragment on CourseHoleStatsPaceData {
      puttingRank
      puttingTime
      offTeeRank
      offTeeTime
      overallRank
      overallTime
      approachRank
      approachTime
      averageHoleRank
      averageHoleTime
    }
    """)
}
