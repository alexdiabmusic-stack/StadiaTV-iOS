import Foundation

actor NBAProvider: NativeSportsProvider {
    nonisolated let leaguePath = "basketball/nba"
    private let client: any NBAAPIClientProtocol
    private var scoresCache: [String: (Date, [Match])] = [:]
    private var schedules: [String: (Date, [Match])] = [:]
    private var teamCache: (Date, [Team])?
    private var standingCache: (Date, [StandingsGroup])?
    private var rosterCache: [String: (Date, [RosterGroup])] = [:]
    private var personCache: [String: (Date, AthleteOverview)] = [:]

    init(client: any NBAAPIClientProtocol = NBAAPIClient.shared) { self.client = client }

    /// Only a decoded, successful response may populate the cache or return an
    /// empty array — a throw always propagates. An empty NBA slate during the
    /// offseason is a legitimate result; a blocked/failed request is not, and
    /// must never be silently reported as "no games today".
    func scores(on date: Date?) async throws -> [Match] {
        let date = date ?? Date()
        let key = NBASeason.day(date)
        if let (time, cached) = scoresCache[key], Date().timeIntervalSince(time) < 10 { return cached }
        let raw = try await client.scoreboard(on: date)
        let matches = await Self.matches(raw)
        scoresCache[key] = (Date(), matches)
        return matches
    }

    func schedule(start: Date, days: Int) async throws -> [Match] {
        let end = Calendar.current.date(byAdding: .day, value: max(0, days - 1), to: start) ?? start
        let key = NBASeason.day(start) + ":" + NBASeason.day(end)
        if let (time, cached) = schedules[key], Date().timeIntervalSince(time) < 120 { return cached }
        let response = try await client.scheduleLeagueV2(season: NBASeason.current(on: start))
        let startDay = NBASeason.day(start), endDay = NBASeason.day(end)
        let filtered = response.games.filter { game in
            guard let gameStart = NBASeason.parse(game["gameDateTimeUTC"].string ?? game["gameDateUTC"].string) else { return false }
            let day = NBASeason.day(gameStart)
            return day >= startDay && day <= endDay
        }
        let matches = await Self.matches(filtered)
        schedules[key] = (Date(), matches)
        return matches
    }

    @MainActor private static func matches(_ raw: [NBAValue]) -> [Match] {
        let matches = NBAGameMapper.games(raw).map(NBALegacyMapper.match)
        return Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.date < $1.date }
    }

    /// No NBA team-list endpoint exists on either host, so teams are derived by
    /// deduplicating every `homeTeam`/`awayTeam` seen across the current season's
    /// schedule — a season without a given team never happens in the NBA.
    func teams() async throws -> [Team] {
        if let (time, cached) = teamCache, Date().timeIntervalSince(time) < 86400 { return cached }
        let response = try await client.scheduleLeagueV2(season: NBASeason.current())
        let result = await MainActor.run {
            var seen: [Int: BasketballTeam] = [:]
            for game in response.games {
                if let home = NBAGameMapper.team(game["homeTeam"]) { seen[home.id] = home }
                if let away = NBAGameMapper.team(game["awayTeam"]) { seen[away.id] = away }
            }
            return seen.values.sorted { $0.tricode < $1.tricode }.map { team in
                Team(id: String(team.id), displayName: team.displayName, shortDisplayName: team.tricode, abbreviation: team.tricode,
                     logoURL: team.logo, canonicalIDString: "team:league.basketball-nba:nba:\(team.id)")
            }
        }
        teamCache = (Date(), result)
        return result
    }

    /// Field names follow stats.nba.com's `leaguestandingsv3` columnar shape as
    /// publicly documented (e.g. by the nba_api project); this endpoint has not
    /// been reachable from any network this integration was built on, so the
    /// exact header set is unverified pending a live check.
    func standings() async throws -> [StandingsGroup] {
        if let (time, cached) = standingCache, Date().timeIntervalSince(time) < 900 { return cached }
        let response = try await client.leagueStandingsV3(season: NBASeason.current(), seasonType: "Regular Season")
        let result = await MainActor.run { Self.standingsGroups(response.rows) }
        standingCache = (Date(), result)
        return result
    }

    @MainActor private static func standingsGroups(_ rows: [[String: NBAValue]]) -> [StandingsGroup] {
        let byConference = Dictionary(grouping: rows) { $0.field("Conference").string ?? "NBA" }
        return byConference.map { conference, rows in
            let standingRows = rows.compactMap(standingRow).sorted { (Double($0.winPercent ?? "") ?? 0) > (Double($1.winPercent ?? "") ?? 0) }
            return StandingsGroup(id: conference, name: conference, rows: standingRows)
        }.sorted { $0.name < $1.name }
    }

    private static func standingRow(_ row: [String: NBAValue]) -> StandingRow? {
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

    /// Field names follow stats.nba.com's `commonteamroster` columnar shape as
    /// publicly documented; same unverified caveat as `standings()`.
    func roster(teamID: String) async throws -> [RosterGroup] {
        if let (time, cached) = rosterCache[teamID], Date().timeIntervalSince(time) < 3600 { return cached }
        let response = try await client.commonTeamRoster(teamID: teamID, season: NBASeason.current())
        let result = await MainActor.run {
            let athletes = response.players.compactMap { row -> RosterAthlete? in
                guard let id = row.field("PLAYER_ID").int else { return nil }
                let name = row.field("PLAYER").string ?? "Unknown player"
                return NBALegacyMapper.athlete(id: id, name: name, jersey: row.field("NUM").string, position: row.field("POSITION").string,
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
        let response = try await client.playerCareerStats(playerID: id)
        guard let season = response.seasonTotalsRegularSeason.last else { throw NBAAPIError.invalidResponse }
        let values = season.sorted { $0.key < $1.key }.compactMap { key, value -> StatValue? in
            guard let text = value.string else { return nil }
            return StatValue(label: key, displayName: NBAPlayDescriptionBuilder.humanize(key), value: text)
        }
        let result = AthleteOverview(statlineLabel: "Season", stats: values, headlineStats: Array(values.prefix(4)), news: [])
        personCache[id] = (Date(), result)
        return result
    }
}
