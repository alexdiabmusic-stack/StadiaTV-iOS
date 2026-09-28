import Foundation

/// Live on-course group tracking. Only meaningful for tournaments/rounds the
/// tour is actively tracking; callers should hide any group-map UI when this
/// returns an empty course list rather than treating it as an error.
nonisolated enum GroupLocationsQuery {
    static let operation = PGAQuery(operationName: "GroupLocations", document: """
    query GroupLocations($tournamentId: ID!, $round: Int!) {
      groupLocations(tournamentId: $tournamentId, round: $round) {
        tournamentId
        courses {
          ...GroupCourseFragment
        }
      }
    }

    fragment GroupCourseFragment on GroupLocationCourse {
      tournamentAndCourseId
      tournamentId
      courseId
      round
      courseName
      holes {
        holeNumber
        par
        yardage
        groups {
          groupSort
          groupNum
          round
          location
          color
          playerData {
            addressingBall
            nextToHit
          }
        }
      }
    }
    """)
}
