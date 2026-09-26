import Foundation

/// Resolves the current MLS season Sportec ID (`MLS-SEA-...`) dynamically from
/// `/competitions/{id}/seasons` and caches it — never a hardcoded season string, per
/// the integration brief. Unlike `EPLSeasonResolver` (pure calendar math), this
/// genuinely requires a network round trip, since Sportec season IDs are opaque
/// (`MLS-SEA-0001KA` for 2026 — no derivable pattern), so it's an actor.
actor MLSSeasonResolver {
    static let shared = MLSSeasonResolver()
    /// MLS Opta competition `98` maps to two Sportec competitions: the regular
    /// season and the Cup Playoffs. Schedule/standings default to the regular season;
    /// callers that specifically need playoff data pass `cupPlayoffsCompetitionID`.
    static let regularSeasonCompetitionID = "MLS-COM-000001"
    static let cupPlayoffsCompetitionID = "MLS-COM-000002"

    private let client: any MLSStatsClientProtocol
    private var cache: [String: (Date, String)] = [:]

    init(client: any MLSStatsClientProtocol = MLSStatsClient.shared) { self.client = client }

    /// The season with the highest `season` year for the given competition —
    /// chosen by value rather than by trusting the API's return order, since that
    /// ordering isn't a documented contract.
    func currentSeasonID(competitionID: String = MLSSeasonResolver.regularSeasonCompetitionID) async throws -> String {
        if let (time, id) = cache[competitionID], Date().timeIntervalSince(time) < 86400 { return id }
        let raw = try await client.seasons(competitionID: competitionID)
        let seasons = raw["seasons"].array.compactMap { entry -> (Int, String)? in
            guard let year = entry["season"].int, let id = entry["season_id"].string else { return nil }
            return (year, id)
        }
        guard let newest = seasons.max(by: { $0.0 < $1.0 }) else {
            throw MLSAPIError.decoding("No seasons returned for competition \(competitionID)")
        }
        cache[competitionID] = (Date(), newest.1)
        return newest.1
    }
}
