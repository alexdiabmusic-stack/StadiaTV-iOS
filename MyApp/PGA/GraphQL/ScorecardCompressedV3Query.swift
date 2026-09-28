import Foundation

nonisolated enum ScorecardCompressedV3Query {
    static let operation = PGAQuery(operationName: "ScorecardCompressedV3", document: """
    query ScorecardCompressedV3($tournamentId: ID!, $playerId: ID!) {
      scorecardCompressedV3(tournamentId: $tournamentId, playerId: $playerId) {
        id
        payload
      }
    }
    """)
}
