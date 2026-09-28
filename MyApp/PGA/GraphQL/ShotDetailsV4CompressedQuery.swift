import Foundation

nonisolated enum ShotDetailsV4CompressedQuery {
    static let operation = PGAQuery(operationName: "shotDetailsV4Compressed", document: """
    query shotDetailsV4Compressed($tournamentId: ID!, $playerId: ID!, $round: Int!, $includeRadar: Boolean) {
      shotDetailsV4Compressed(tournamentId: $tournamentId, playerId: $playerId, round: $round, includeRadar: $includeRadar) {
        id
        payload
      }
    }
    """)
}
