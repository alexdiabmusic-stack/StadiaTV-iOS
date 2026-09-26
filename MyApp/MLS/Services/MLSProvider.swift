import Foundation

/// Native MLS data provider on the Sportec stats-api.mlssoccer.com API. Registered
/// into `SportsRepository` alongside NHL/MLB/NFL/F1/NBA/EPL — no ESPN, no backend,
/// no API key. See MLS-INTEGRATION.md for endpoint/licensing notes and the live
/// discovery that superseded the dead `/v1` + Opta-ID route family.
actor MLSProvider: NativeSportsProvider {
    nonisolated let leaguePath = "soccer/usa.1"
    private let client: any MLSStatsClientProtocol
    private let seasonResolver: MLSSeasonResolver
    private var dayCache: [String: (Date, [Match])] = [:]
    private var rangeCache: [String: (Date, [Match])] = [:]
    private var teamCache: (Date, [Team])?
    private var standingsCache: (Date, [StandingsGroup])?
    private var squadCache: [String: (Date, [RosterGroup])] = [:]

    init(client: any MLSStatsClientProtocol = MLSStatsClient.shared, seasonResolver: MLSSeasonResolver = .shared) {
        self.client = client
        self.seasonResolver = seasonResolver
    }

    func scores(on date: Date?) async throws -> [Match] {
        let day = date ?? Date()
        let key = MLSDate.day(day)
        if let (time, cached) = dayCache[key], Date().timeIntervalSince(time) < 10 { return cached }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: day)
        let matches = try await Self.matches(client: client, seasonResolver: seasonResolver,
            from: calendar.date(byAdding: .day, value: -1, to: start) ?? start, to: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
            .filter { calendar.isDate($0.date, inSameDayAs: day) }
        dayCache[key] = (Date(), matches)
        return matches
    }

    func schedule(start: Date, days: Int) async throws -> [Match] {
        let calendar = Calendar(identifier: .gregorian)
        let end = calendar.date(byAdding: .day, value: max(0, days - 1), to: start) ?? start
        let key = MLSDate.day(start) + ":" + MLSDate.day(end)
        if let (time, cached) = rangeCache[key], Date().timeIntervalSince(time) < 120 { return cached }
        let matches = try await Self.matches(client: client, seasonResolver: seasonResolver,
            from: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: start)) ?? start, to: end)
        rangeCache[key] = (Date(), matches)
        return matches
    }

    func teams() async throws -> [Team] {
        if let (time, cached) = teamCache, Date().timeIntervalSince(time) < 86400 { return cached }
        let seasonID = try await seasonResolver.currentSeasonID()
        let raw = try await client.clubs(competitionID: MLSSeasonResolver.regularSeasonCompetitionID, seasonID: seasonID)
        let result = raw["clubs"].array.compactMap { MLSMatchMapper.club($0) }.map { MLSLegacyMapper.team($0) }
        teamCache = (Date(), result)
        return result
    }

    /// Returns Eastern, Western, and combined/Supporters'-Shield-order groups — MLS
    /// is never forced into a single EPL-style 1-N table.
    func standings() async throws -> [StandingsGroup] {
        if let (time, cached) = standingsCache, Date().timeIntervalSince(time) < 900 { return cached }
        let seasonID = try await seasonResolver.currentSeasonID()
        async let conferenceRaw = client.standings(competitionID: MLSSeasonResolver.regularSeasonCompetitionID, seasonID: seasonID, category: "conference", isLive: false)
        async let overallRaw = client.standings(competitionID: MLSSeasonResolver.regularSeasonCompetitionID, seasonID: seasonID, category: nil, isLive: false)
        let conferenceTables = MLSStandingsMapper.tables(try await conferenceRaw, isLive: false)
        let overallTables = MLSStandingsMapper.tables(try await overallRaw, isLive: false).map { table -> SoccerStandingsTable in
            var renamed = table; renamed.groupLabel = renamed.groupLabel ?? "Supporters' Shield"; return renamed
        }
        let result = MLSLegacyMapper.standingsGroups(overallTables + conferenceTables)
        standingsCache = (Date(), result)
        return result
    }

    func roster(teamID: String) async throws -> [RosterGroup] {
        if let (time, cached) = squadCache[teamID], Date().timeIntervalSince(time) < 3600 { return cached }
        let seasonID = try await seasonResolver.currentSeasonID()
        let raw = try await client.clubSeasonStats(competitionID: MLSSeasonResolver.regularSeasonCompetitionID, seasonID: seasonID)
        // `/statistics/clubs/competitions/{c}/seasons/{s}` is club-scoped season
        // stats, not a roster — MLS's stats API exposes no dedicated squad-list
        // route in the verified surface, so this degrades to an empty roster rather
        // than guessing at an unverified endpoint. Disclosed gap (see MLS-INTEGRATION.md).
        _ = raw
        let result: [RosterGroup] = []
        squadCache[teamID] = (Date(), result)
        return result
    }

    func playerOverview(id: String) async throws -> AthleteOverview {
        let raw = try await client.playerMatchLog(personID: id, competitionID: MLSSeasonResolver.regularSeasonCompetitionID, pageToken: nil)
        let matches = raw["match_log"].array
        let totals: [String: Double] = matches.reduce(into: [:]) { acc, entry in
            for (key, value) in entry["player_statistics"].object { if let d = value.double { acc[key, default: 0] += d } }
        }
        let headlineKeys: Set<String> = ["goals", "assists", "cards_yellow", "cards_red"]
        let values = totals.sorted { $0.key < $1.key }.map { StatValue(label: $0.key, displayName: Self.humanize($0.key), value: String(format: "%.0f", $0.value)) }
        return AthleteOverview(statlineLabel: "\(matches.count) matches", stats: values, headlineStats: values.filter { headlineKeys.contains($0.label) }, news: [])
    }

    private static func matches(client: any MLSStatsClientProtocol, seasonResolver: MLSSeasonResolver, from: Date, to: Date) async throws -> [Match] {
        let seasonID = try await seasonResolver.currentSeasonID()
        let raw = try await client.schedule(seasonID: seasonID, from: MLSDate.day(from), to: MLSDate.day(to), competitionID: MLSSeasonResolver.regularSeasonCompetitionID, teamID: nil, pageToken: nil)
        let matches = raw["schedule"].array.compactMap { MLSMatchMapper.scheduleMatch($0) }.map { MLSLegacyMapper.match($0) }
        return Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.date < $1.date }
    }

    private static func humanize(_ key: String) -> String {
        key.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
