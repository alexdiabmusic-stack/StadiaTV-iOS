import Foundation

nonisolated enum LeaderboardCompressedV3Query {
    static let operation = PGAQuery(operationName: "LeaderboardCompressedV3", document: """
    query LeaderboardCompressedV3($leaderboardCompressedV3Id: ID!) {
      leaderboardCompressedV3(id: $leaderboardCompressedV3Id) {
        id
        payload
      }
    }
    """)
}
