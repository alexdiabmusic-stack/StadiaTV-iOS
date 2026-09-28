import Foundation

/// A centrally-stored GraphQL operation. Every PGA service resolves its query
/// text from here — no service inlines a GraphQL string. Documents are
/// verbatim from the current pgatour.com frontend (cross-checked against the
/// pgatouR/pgatourPY reference implementations' `inst/graphql` sources), not
/// hand-written approximations.
nonisolated struct PGAQuery: Sendable {
    let operationName: String
    let document: String
}
