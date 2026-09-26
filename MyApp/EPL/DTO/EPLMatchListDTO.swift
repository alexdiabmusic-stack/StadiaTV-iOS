import Foundation

/// Thin view over the `{pagination:{...}, data:[...]}` envelope shared by every SDP
/// list route (matches, commentary, leaderboards). Not decoded directly — built from
/// whatever `EPLPulseLiveClient` already returned as `EPLValue`, so a schema change to
/// the envelope shape only needs a fix here, not at every call site.
nonisolated struct EPLPagedResponse: Sendable {
    let raw: EPLValue
    init(_ raw: EPLValue) { self.raw = raw }
    var data: [EPLValue] { raw["data"].array }
    /// Opaque cursor — pass back verbatim as `_next`, never parsed or reconstructed.
    var nextCursor: String? { raw["pagination"]["_next"].string }
    var prevCursor: String? { raw["pagination"]["_prev"].string }
}
