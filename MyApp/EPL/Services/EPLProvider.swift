import Foundation

/// Native EPL data provider on the Premier League PulseLive/SDP JSON API. Registered
/// into `SportsRepository` alongside NHL/MLB/F1/NFL/NBA — no ESPN, no FPL, no backend,
/// no API key. See EPL-INTEGRATION.md for endpoint/licensing notes.
actor EPLProvider: NativeSportsProvider {
    nonisolated let leaguePath = "soccer/eng.1"
    private let client: any EPLPulseLiveClientProtocol
    private var dayCache: [String: (Date, [Match])] = [:]
    private var rangeCache: [String: (Date, [Match])] = [:]
    private var teamCache: (Date, [Team])?
    private var standingsCache: (Date, [StandingsGroup])?
    private var squadCache: [String: (Date, [RosterGroup])] = [:]
    private var playerCache: [String: (Date, AthleteOverview)] = [:]

    init(client: any EPLPulseLiveClientProtocol = EPLPulseLiveClient.shared) { self.client = client }

    private static var londonCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .current
        return calendar
    }

    func scores(on date: Date?) async throws -> [Match] {
        let day = date ?? Date()
        let key = EPLDate.day(day)
        if let (time, cached) = dayCache[key], Date().timeIntervalSince(time) < 10 { return cached }
        let calendar = Self.londonCalendar
        let start = calendar.startOfDay(for: day)
        let matches = try await Self.matches(client: client, season: EPLSeasonResolver.seasonParameter(for: day),
            kickoffAfter: calendar.date(byAdding: .day, value: -1, to: start), kickoffBefore: calendar.date(byAdding: .day, value: 1, to: start))
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
        dayCache[key] = (Date(), matches)
        return matches
    }

    func schedule(start: Date, days: Int) async throws -> [Match] {
        let calendar = Self.londonCalendar
        let end = calendar.date(byAdding: .day, value: max(0, days - 1), to: start) ?? start
        let key = EPLDate.day(start) + ":" + EPLDate.day(end)
        if let (time, cached) = rangeCache[key], Date().timeIntervalSince(time) < 120 { return cached }
        // A range can straddle a season boundary (e.g. late May into a new season's
        // pre-season) — query both the start and end season and de-duplicate by ID.
        let seasons = Set([EPLSeasonResolver.seasonParameter(for: start), EPLSeasonResolver.seasonParameter(for: end)])
        var byID: [String: Match] = [:]
        for season in seasons {
            let matches = try await Self.matches(client: client, season: season,
                kickoffAfter: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)), kickoffBefore: calendar.date(byAdding: .day, value: 1, to: end))
            for match in matches { byID[match.id] = match }
        }
        let result = byID.values.sorted { $0.date < $1.date }
        rangeCache[key] = (Date(), result)
        return result
    }

    func teams() async throws -> [Team] {
        if let (time, cached) = teamCache, Date().timeIntervalSince(time) < 86400 { return cached }
        let raw = try await client.teams(season: EPLSeasonResolver.seasonParameter())
        let result = EPLPagedResponse(raw).data.compactMap { EPLMatchMapper.team($0) }.map { EPLLegacyMapper.team($0) }
        teamCache = (Date(), result)
        return result
    }

    func standings() async throws -> [StandingsGroup] {
        if let (time, cached) = standingsCache, Date().timeIntervalSince(time) < 900 { return cached }
        let raw = try await client.standings(season: EPLSeasonResolver.seasonParameter(), live: false)
        let result = EPLLegacyMapper.standings(EPLMatchMapper.standingsTable(raw, live: false))
        standingsCache = (Date(), result)
        return result
    }

    func roster(teamID: String) async throws -> [RosterGroup] {
        if let (time, cached) = squadCache[teamID], Date().timeIntervalSince(time) < 3600 { return cached }
        let raw = try await client.squad(season: EPLSeasonResolver.seasonParameter(), teamID: teamID)
        let players = raw["players"].array.compactMap { EPLMatchMapper.rosterPlayer($0) }.map { EPLLegacyMapper.athlete($0) }
        let groups = Dictionary(grouping: players) { $0.position ?? "Squad" }
        let order = ["Goalkeeper", "Defender", "Midfielder", "Forward"]
        let result = groups.keys.sorted { (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count) }
            .map { RosterGroup(id: $0, title: $0 + "s", athletes: groups[$0] ?? []) }
        squadCache[teamID] = (Date(), result)
        return result
    }

    func playerOverview(id: String) async throws -> AthleteOverview {
        if let (time, cached) = playerCache[id], Date().timeIntervalSince(time) < 3600 { return cached }
        let season = EPLSeasonResolver.seasonParameter()
        let raw = try await client.playerSeasonStats(season: season, playerID: id)
        let values = raw["stats"].object.sorted { $0.key < $1.key }.compactMap { key, value -> StatValue? in
            guard let text = value.string else { return nil }
            return StatValue(label: key, displayName: Self.humanize(key), value: text)
        }
        let headlineKeys: Set<String> = ["goals", "goalAssists", "gamesPlayed", "cleanSheets"]
        let result = AthleteOverview(statlineLabel: "Season \(season)/\(String((Int(season) ?? 0) + 1).suffix(2))", stats: values,
            headlineStats: values.filter { headlineKeys.contains($0.label) }, news: [])
        playerCache[id] = (Date(), result)
        return result
    }

    /// Fetches one page of matches and maps them to `Match`, deduplicating by ID —
    /// the API can return the same match from adjacent range queries.
    private static func matches(client: any EPLPulseLiveClientProtocol, season: String, kickoffAfter: Date?, kickoffBefore: Date?) async throws -> [Match] {
        let raw = try await client.matches(season: season, matchweek: nil, team: nil, period: nil, limit: 100, next: nil, sort: "kickoff:asc", kickoffAfter: kickoffAfter, kickoffBefore: kickoffBefore)
        let matches = EPLPagedResponse(raw).data.compactMap { EPLMatchMapper.match($0) }.map { EPLLegacyMapper.match($0) }
        return Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.date < $1.date }
    }

    private static func humanize(_ key: String) -> String {
        var result = ""
        for (index, char) in key.enumerated() {
            if char.isUppercase, index > 0 { result += " " }
            result += index == 0 ? String(char).uppercased() : String(char).lowercased()
        }
        return result
    }
}
