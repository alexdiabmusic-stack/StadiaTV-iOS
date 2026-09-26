import Foundation

/// Discovery-layer provider — `NativeSportsProvider` already serves the role the
/// WNBA integration brief calls `BasketballLiveProvider`; introducing a second,
/// redundant protocol alongside it would just be two names for the same seam
/// (`NBAProvider` conforms to the identical protocol). Standings/roster/player
/// calls go to `WNBAStatsClient` only — kept isolated from the live CDN client
/// (Step 20/21), never invoked from the Game Center poll path.
actor WNBAProvider: NativeSportsProvider {
    nonisolated let leaguePath = "basketball/wnba"
    private let client: any WNBALiveCDNClientProtocol
    private let stats: any WNBAStatsClientProtocol
    private var scoresCache: [String: (Date, [Match])] = [:]
    private var schedules: [String: (Date, [Match])] = [:]
    private var teamCache: (Date, [Team])?
    private var standingCache: (Date, [StandingsGroup])?
    private var rosterCache: [String: (Date, [RosterGroup])] = [:]
    private var personCache: [String: (Date, AthleteOverview)] = [:]

    init(client: any WNBALiveCDNClientProtocol = WNBALiveCDNClient.shared, stats: any WNBAStatsClientProtocol = WNBAStatsClient.shared) {
        self.client = client
        self.stats = stats
    }

    /// Only a decoded, successful response may populate the cache or return an
    /// empty array — a throw always propagates. An empty WNBA slate during the
    /// offseason is a legitimate result; a blocked/failed request is not.
    func scores(on date: Date?) async throws -> [Match] {
        let day = date ?? Date()
        let key = WNBASeason.day(day)
        if let (time, cached) = scoresCache[key], Date().timeIntervalSince(time) < 10 { return cached }
        let today = try await client.todaysScoreboard()
        let raw: [WNBAValue]
        if WNBASeason.day(day) == WNBASeason.day(Date()) {
            raw = today.games
        } else {
            // Non-today, current-season day — filter the static schedule (Step 8);
            // no historical-day support exists on this CDN file.
            let schedule = try await client.scheduleLeagueV2()
            raw = schedule.games.filter { game in
                guard let start = WNBASeason.parse(game["gameDateTimeUTC"].string ?? game["gameDateUTC"].string) else { return false }
                return WNBASeason.day(start) == key
            }
        }
        let matches = await Self.matches(raw)
        scoresCache[key] = (Date(), matches)
        return matches
    }

    func schedule(start: Date, days: Int) async throws -> [Match] {
        let end = Calendar.current.date(byAdding: .day, value: max(0, days - 1), to: start) ?? start
        let key = WNBASeason.day(start) + ":" + WNBASeason.day(end)
        if let (time, cached) = schedules[key], Date().timeIntervalSince(time) < 120 { return cached }
        // Step 8: cache the season file itself in-memory (via `scheduleLeagueV2`'s
        // own client-level result) rather than re-downloading it for every screen —
        // the day-range cache above already avoids redundant network calls for
        // repeated nearby ranges within 120s.
        let response = try await client.scheduleLeagueV2()
        let startDay = WNBASeason.day(start), endDay = WNBASeason.day(end)
        let filtered = response.games.filter { game in
            guard let gameStart = WNBASeason.parse(game["gameDateTimeUTC"].string ?? game["gameDateUTC"].string) else { return false }
            let day = WNBASeason.day(gameStart)
            return day >= startDay && day <= endDay
        }
        let matches = await Self.matches(filtered)
        schedules[key] = (Date(), matches)
        return matches
    }

    @MainActor private static func matches(_ raw: [WNBAValue]) -> [Match] {
        let matches = WNBAGameMapper.games(raw).map { BasketballLegacyMapper.match($0, config: .wnba) }
        return Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.date < $1.date }
    }

    /// No WNBA team-list endpoint exists on the live CDN, so teams are derived by
    /// deduplicating every `homeTeam`/`awayTeam` seen across the current season's
    /// schedule (Step 23 — team identity resolved dynamically, never a hardcoded
    /// historical roster of franchises, since the league can and does expand).
    func teams() async throws -> [Team] {
        if let (time, cached) = teamCache, Date().timeIntervalSince(time) < 86400 { return cached }
        let response = try await client.scheduleLeagueV2()
        let result = await MainActor.run {
            var seen: [Int: BasketballTeam] = [:]
            for game in response.games {
                if let home = WNBAGameMapper.team(game["homeTeam"]) { seen[home.id] = home }
                if let away = WNBAGameMapper.team(game["awayTeam"]) { seen[away.id] = away }
            }
            return seen.values.sorted { $0.tricode < $1.tricode }.map { team in
                Team(id: String(team.id), displayName: team.displayName, shortDisplayName: team.tricode, abbreviation: team.tricode,
                     logoURL: team.logo, canonicalIDString: "team:league.basketball-wnba:wnba:\(team.id)")
            }
        }
        teamCache = (Date(), result)
        return result
    }

    /// stats.wnba.com's exact `leaguestandingsv3` header set is UNVERIFIED this
    /// session (unreachable from this sandbox) — mirrors `NBAProvider.standings()`'s
    /// same disclosed caveat. Cached aggressively (15 min) and never polled at
    /// live-score frequency (Step 20).
    func standings() async throws -> [StandingsGroup] {
        if let (time, cached) = standingCache, Date().timeIntervalSince(time) < 900 { return cached }
        let response = try await stats.leagueStandingsV3(season: WNBASeason.current(), seasonType: "Regular Season")
        let result = await MainActor.run { Self.standingsGroups(response.rows) }
        standingCache = (Date(), result)
        return result
    }

    @MainActor private static func standingsGroups(_ rows: [[String: WNBAValue]]) -> [StandingsGroup] {
        let byConference = Dictionary(grouping: rows) { $0.field("Conference").string ?? "WNBA" }
        return byConference.map { conference, rows in
            let standingRows = rows.compactMap(standingRow).sorted { (Double($0.winPercent ?? "") ?? 0) > (Double($1.winPercent ?? "") ?? 0) }
            return StandingsGroup(id: conference, name: conference, rows: standingRows)
        }.sorted { $0.name < $1.name }
    }

    private static func standingRow(_ row: [String: WNBAValue]) -> StandingRow? {
        guard let teamID = row.field("TeamID").int else { return nil }
        let wins = row.field("WINS").int, losses = row.field("LOSSES").int
        let name = [row.field("TeamCity").string, row.field("TeamName").string].compactMap { $0 }.joined(separator: " ")
        let abbreviation = row.field("TeamAbbreviation").string ?? ""
        let gamesPlayed = wins.flatMap { w in losses.map { l in w + l } }
        return StandingRow(teamID: String(teamID), displayName: name, abbreviation: abbreviation,
            logoURL: URL(string: "banner-asset:/NBALogo_\(abbreviation)"),
            record: [wins, losses].compactMap { $0.map(String.init) }.joined(separator: "-"),
            wins: wins.map(String.init), losses: losses.map(String.init), ties: nil,
            winPercent: row.field("WinPCT").string, gamesBack: row.field("ConferenceGamesBack").string,
            streak: row.field("strCurrentStreak").string, pointsFor: row.field("PointsPG").string, pointsAgainst: row.field("OppPointsPG").string,
            leaguePoints: nil, gamesPlayed: gamesPlayed?.description,
            goalDiff: row.field("DiffPointsPG").string, divisionRank: row.field("DivisionRank").string, leagueRank: row.field("PlayoffRank").string,
            wildCardRank: nil, wildCardGamesBack: nil, lastTen: row.field("L10").string)
    }

    /// stats.wnba.com's `commonteamroster` shape is likewise unverified; same
    /// caveat as `standings()`.
    func roster(teamID: String) async throws -> [RosterGroup] {
        if let (time, cached) = rosterCache[teamID], Date().timeIntervalSince(time) < 3600 { return cached }
        let response = try await stats.commonTeamRoster(teamID: teamID, season: WNBASeason.current())
        let result = await MainActor.run {
            let athletes = response.players.compactMap { row -> RosterAthlete? in
                guard let id = row.field("PLAYER_ID").int else { return nil }
                let name = row.field("PLAYER").string ?? "Unknown player"
                return BasketballLegacyMapper.athlete(id: id, name: name, jersey: row.field("NUM").string, position: row.field("POSITION").string, config: .wnba,
                    height: row.field("HEIGHT").string, weight: row.field("WEIGHT").string, age: row.field("AGE").int,
                    experienceYears: row.field("EXP").string.flatMap { Int($0) }, college: row.field("SCHOOL").string)
            }
            let groups = Dictionary(grouping: athletes) { athlete -> String in
                switch athlete.position {
                case "G": return "Guards"
                case "F": return "Forwards"
                case "C": return "Centers"
                default: return "Other"
                }
            }
            return groups.keys.sorted().map { RosterGroup(id: $0, title: $0, athletes: groups[$0] ?? []) }
        }
        rosterCache[teamID] = (Date(), result)
        return result
    }

    func playerOverview(id: String) async throws -> AthleteOverview {
        if let (time, cached) = personCache[id], Date().timeIntervalSince(time) < 3600 { return cached }
        let response = try await stats.playerCareerStats(playerID: id)
        guard let season = response.seasonTotalsRegularSeason.last else { throw WNBAAPIError.invalidResponse }
        let values = season.sorted { $0.key < $1.key }.compactMap { key, value -> StatValue? in
            guard let text = value.string else { return nil }
            return StatValue(label: key, displayName: BasketballPlayDescriptionBuilder.humanize(key), value: text)
        }
        let result = AthleteOverview(statlineLabel: "Season", stats: values, headlineStats: Array(values.prefix(4)), news: [])
        personCache[id] = (Date(), result)
        return result
    }
}
