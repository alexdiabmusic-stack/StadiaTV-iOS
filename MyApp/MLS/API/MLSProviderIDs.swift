import Foundation

/// MLS exposes two identifier families, and they are NOT interchangeable:
///
/// - **Sportec IDs** (`MLS-MAT-...`, `MLS-COM-...`, `MLS-SEA-...`, `MLS-CLU-...`,
///   `MLS-OBJ-...`) — the primary key for every route this provider actually uses
///   (verified live 2026-09-23).
/// - **Opta IDs** (numeric, e.g. competition `98`) — referenced throughout the
///   original integration brief and the MLS website's own embedded config, but no
///   verified-live route in this provider accepts one. Carried here only as an
///   optional diagnostic value, never sent into a Sportec-ID route.
nonisolated struct MLSProviderIDs: Sendable, Equatable {
    var gameID: String?
    var competitionID: String?
    var seasonID: String?
    var clubID: String?
    var personID: String?
    /// Diagnostic only — MLS competition `98` (regular season + playoffs combined
    /// under one Opta ID; Sportec splits them into `MLS-COM-000001`/`000002`).
    var optaCompetitionID: Int? = 98
}
