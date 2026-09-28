import Foundation

nonisolated enum TeeTimesCompressedV2Query {
    static let operation = PGAQuery(operationName: "TeeTimesCompressedV2", document: """
    query TeeTimesCompressedV2($teeTimesCompressedV2Id: ID!) {
      teeTimesCompressedV2(id: $teeTimesCompressedV2Id) {
        id
        payload
      }
    }
    """)
}
