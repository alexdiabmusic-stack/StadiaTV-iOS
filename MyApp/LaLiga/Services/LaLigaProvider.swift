import Foundation

/// Native La Liga discovery-layer provider on the official LaLiga website API.
/// Registered into `SportsRepository` alongside NHL/MLB/F1/NFL/NBA/EPL/MLS. This
/// provider only ever talks to the official API — score/schedule/teams/standings/
/// roster/playerOverview never depend on FotMob (Step 19: FotMob owns live Game
/// Centre enrichment only). See LALIGA-INTEGRATION.md for endpoint/licensing notes.
actor LaLigaProvider: NativeSportsProvider, LaLigaOfficialMatchSource {
    /// Shared instance so `LaLigaGameCentreService` (Phase 5) reuses this actor's
    /// in-memory season-match cache instead of re-paginating all ~380 fixtures on
    /// every Game Centre poll tick — the official API has no single-match-by-id
    /// route (Step 4/10), only the paginated list.
    static let shared = LaLigaProvider()

    nonisolated let leaguePath = "soccer/esp.1"
    private let client: any LaLigaClientProtocol
    private let seasonResolver: LaLigaSeasonResolver
    /// Keyed by subscription slug, since a schedule range can straddle a season boundary.
    private var seasonMatchesCache: [String: (Date, [Match])] = [:]
    /// Canonical `SoccerMatch` counterpart of `seasonMatchesCache`, populated in
    /// the same fetch — kept separate from the legacy `Match` cache since Game
    /// Centre callers need the canonical shape, not the legacy-bridged one.
    private var canonicalMatchesCache: [String: (Date, [SoccerMatch])] = [:]
    private var teamCache: (Date, [Team])?
    private var standingsCache: (Date, [StandingsGroup])?
    private var squadCache: [String: (Date, [RosterGroup])] = [:]
    private var playerCache: [String: (Date, AthleteOverview)] = [:]
    /// Team numeric-id -> slug directory, built from whatever standings/match rows
    /// have already been fetched — `roster(teamID:)` only has the numeric id in
    /// hand, but `/api/v1/teams/{slug}/squad` needs the slug (Step 8).
    private var teamSlugsByID: [String: String] = [:]

    init(client: any LaLigaClientProtocol = LaLigaClient.shared, seasonResolver: LaLigaSeasonResolver = .shared) {
        self.client = client
        self.seasonResolver = seasonResolver
    }

    func scores(on date: Date?) async throws -> [Match] {
        let day = date ?? Date()
        let matches = try await seasonMatches(for: day)
        let calendar = Calendar.current
        return matches.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    func schedule(start: Date, days: Int) async throws -> [Match] {
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: max(0, days - 1), to: start) ?? start
        let years = Set([LaLigaSeasonResolver.startingYear(for: start), LaLigaSeasonResolver.startingYear(for: end)])
        var byID: [String: Match] = [:]
        for year in years {
            for match in try await seasonMatches(forYear: year) where match.date >= calendar.startOfDay(for: start) && match.date <= end {
                byID[match.id] = match
            }
        }
        return byID.values.sorted { $0.date < $1.date }
    }

    func teams() async throws -> [Team] {
        if let (time, cached) = teamCache, Date().timeIntervalSince(time) < 86400 { return cached }
        let table = try await currentStandingsTable()
        let result = table.entries.map { LaLigaLegacyMapper.team($0.team) }.sorted { $0.displayName < $1.displayName }
        teamCache = (Date(), result)
        return result
    }

    func standings() async throws -> [StandingsGroup] {
        if let (time, cached) = standingsCache, Date().timeIntervalSince(time) < 900 { return cached }
        let result = LaLigaLegacyMapper.standings(try await currentStandingsTable())
        standingsCache = (Date(), result)
        return result
    }

    func roster(teamID: String) async throws -> [RosterGroup] {
        if let (time, cached) = squadCache[teamID], Date().timeIntervalSince(time) < 3600 { return cached }
        if teamSlugsByID[teamID] == nil { _ = try await teams() }
        guard let slug = teamSlugsByID[teamID] else { throw LaLigaAPIError.notFound("team \(teamID)") }
        let subscriptionSlug = try await seasonResolver.currentSubscriptionSlug()
        let raw = try await client.squad(teamSlug: slug, subscriptionSlug: subscriptionSlug)
        let players = LaLigaSquadMapper.roster(raw).map { LaLigaLegacyMapper.athlete($0) }
        let groups = Dictionary(grouping: players) { $0.position ?? "Squad" }
        let order = ["Goalkeeper", "Defender", "Midfielder", "Forward"]
        let result = groups.keys.sorted { (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count) }
            .map { RosterGroup(id: $0, title: $0 + "s", athletes: groups[$0] ?? []) }
        squadCache[teamID] = (Date(), result)
        return result
    }

    /// `id` is the player's `opta_id` (Step 6/18 — `LaLigaLegacyMapper.athlete` mints
    /// canonical IDs from it), so this joins the season stats list on `opta_id`,
    /// never the list's own row id (only meaningful within that one response).
    func playerOverview(id: String) async throws -> AthleteOverview {
        if let (time, cached) = playerCache[id], Date().timeIntervalSince(time) < 3600 { return cached }
        let slug = try await seasonResolver.currentSubscriptionSlug()
        var found: LaLigaValue?
        for page in 0..<8 { // covers 800 players; 564 observed live 2026-09-24
            let raw = try await client.playerStats(subscriptionSlug: slug, limit: 100, offset: page * 100)
            if let match = LaLigaPlayerStatsMapper.find(raw, optaID: id) { found = match; break }
            if raw["player_stats"].array.count < 100 { break }
        }
        guard let found else { throw LaLigaAPIError.notFound("player \(id)") }
        let values = LaLigaPlayerStatsMapper.statValues(found)
        let year = LaLigaSeasonResolver.startingYear()
        let headlineKeys: Set<String> = ["goals", "goal_assists", "appearances", "clean_sheets"]
        let result = AthleteOverview(statlineLabel: "Season \(year)/\(String(year + 1).suffix(2))",
            stats: values, headlineStats: values.filter { headlineKeys.contains($0.label) }, news: [])
        playerCache[id] = (Date(), result)
        return result
    }

    /// The single official match matching `id`, for `LaLigaGameCentreService`'s
    /// baseline fetch — reuses this actor's season-match cache (5 min TTL) rather
    /// than re-paginating every poll tick. No kickoff is known up front (the
    /// official API has no single-match-by-id route, Step 4/10), so this tries
    /// the current season first, falling back to the immediate neighbors for a
    /// match right at a season boundary.
    func officialMatch(id: String) async throws -> SoccerMatch? {
        let currentYear = LaLigaSeasonResolver.startingYear()
        for year in [currentYear, currentYear - 1, currentYear + 1] {
            if let match = try await canonicalSeasonMatches(forYear: year).first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    // MARK: Helpers

    private func currentStandingsTable() async throws -> SoccerStandingsTable {
        let slug = try await seasonResolver.currentSubscriptionSlug()
        let raw = try await client.standing(subscriptionSlug: slug)
        for entry in raw["standings"].array { recordSlug(from: entry["team"]) }
        return LaLigaMatchMapper.standingsTable(raw)
    }

    private func seasonMatches(for date: Date) async throws -> [Match] {
        try await seasonMatches(forYear: LaLigaSeasonResolver.startingYear(for: date))
    }

    /// Fetches every `primera-division` fixture for one season, paginating at <=100
    /// (Step 4 — `limit>100` returns HTTP 500, verified live 2026-09-24) until a
    /// short page signals the end. A full season is 380 fixtures (verified live),
    /// but this never hardcodes that count — it just keeps paging until the API says stop.
    private func seasonMatches(forYear year: Int) async throws -> [Match] {
        if let (time, cached) = seasonMatchesCache[try await slugForYear(year)], Date().timeIntervalSince(time) < 300 { return cached }
        let canonical = try await canonicalSeasonMatches(forYear: year)
        let matches = canonical.map { LaLigaLegacyMapper.match($0) }
        let deduped = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.date < $1.date }
        seasonMatchesCache[try await slugForYear(year)] = (Date(), deduped)
        return deduped
    }

    /// The canonical counterpart of `seasonMatches(forYear:)` — shares the same
    /// underlying paginated fetch and 5-minute cache TTL, keyed by subscription slug.
    private func canonicalSeasonMatches(forYear year: Int) async throws -> [SoccerMatch] {
        let slug = try await slugForYear(year)
        if let (time, cached) = canonicalMatchesCache[slug], Date().timeIntervalSince(time) < 300 { return cached }
        var rows: [LaLigaValue] = []
        for page in 0..<10 {
            let raw = try await client.matches(subscriptionSlug: slug, competition: LaLigaProviderConfiguration.competitionSlug, limit: 100, offset: page * 100)
            let batch = raw["matches"].array
            rows.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        for row in rows { recordSlug(from: row["home_team"]); recordSlug(from: row["away_team"]) }
        let season = String(year)
        let matches = rows.compactMap { LaLigaMatchMapper.match($0, season: season) }
        let deduped = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.kickoff < $1.kickoff }
        canonicalMatchesCache[slug] = (Date(), deduped)
        return deduped
    }

    private func slugForYear(_ year: Int) async throws -> String {
        let date = Calendar.current.date(from: DateComponents(year: year, month: 9, day: 1)) ?? Date()
        return try await seasonResolver.currentSubscriptionSlug(for: date)
    }

    private func recordSlug(from raw: LaLigaValue) {
        guard let id = raw["id"].string, let slug = raw["slug"].string else { return }
        teamSlugsByID[id] = slug
    }
}
