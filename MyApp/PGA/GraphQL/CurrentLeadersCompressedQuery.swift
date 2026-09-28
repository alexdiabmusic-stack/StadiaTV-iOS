import Foundation

nonisolated enum CurrentLeadersCompressedQuery {
    static let operation = PGAQuery(operationName: "CurrentLeadersCompressed", document: """
    query CurrentLeadersCompressed($tournamentId: ID!) {
      currentLeadersCompressed(tournamentId: $tournamentId) {
        id
        payload
      }
    }
    """)
}
