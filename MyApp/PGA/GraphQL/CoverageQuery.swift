import Foundation

nonisolated enum CoverageQuery {
    static let operation = PGAQuery(operationName: "Coverage", document: """
    query Coverage($tournamentId: ID!) {
      coverage(tournamentId: $tournamentId) {
        id
        tournamentName
        countryCode
        coverageType {
          __typename
          ... on BroadcastFullTelecast {
            id
            streamTitle
            roundNumber
            channelTitle
            roundDisplay
            startTime
            endTime
            liveStatus
          }
          ... on BroadcastFeaturedGroup {
            id
            streamTitle
            roundNumber
            channelTitle
            roundDisplay
            startTime
            endTime
            courseId
            groups {
              id
              extendedCoverage
              playerLastNames
              liveStatus
            }
            liveStatus
          }
          ... on BroadcastFeaturedHole {
            id
            streamTitle
            roundNumber
            channelTitle
            roundDisplay
            startTime
            endTime
            courseId
            featuredHoles
            liveStatus
          }
        }
      }
    }
    """)
}
