import Foundation

actor MLBProvider: NativeSportsProvider {
    nonisolated let leaguePath = "baseball/mlb"
    private let client: any MLBAPIClientProtocol
    private var schedules: [String: (Date, [Match])] = [:]
    private var teamCache: (Date, [Team])?
    private var standingCache: (Date, [StandingsGroup])?
    private var rosterCache: [String: (Date, [RosterGroup])] = [:]
    private var personCache: [String: (Date, AthleteOverview)] = [:]
    init(client: any MLBAPIClientProtocol = MLBAPIClient.shared) { self.client = client }
    func scores(on date: Date?) async throws -> [Match] {
        let date = date ?? Date(), key = MLBDate.day(date)
        if let (time, cached) = schedules[key], Date().timeIntervalSince(time) < 10 { return cached }
        let response = try await client.schedule(date: date)
        let matches = await Self.matches(response)
        schedules[key] = (Date(), matches); return matches
    }
    func schedule(start: Date, days: Int) async throws -> [Match] {
        let end = Calendar.current.date(byAdding: .day, value: max(0, days - 1), to: start) ?? start
        let key = MLBDate.day(start) + ":" + MLBDate.day(end)
        if let (time, cached) = schedules[key], Date().timeIntervalSince(time) < 120 { return cached }
        let result = await Self.matches(try await client.schedule(startDate: start, endDate: end))
        schedules[key] = (Date(), result); return result
    }
    @MainActor private static func matches(_ response: MLBScheduleResponse) -> [Match] {
        let matches = response.games.compactMap { raw -> Match? in
            guard let game = MLBGameMapper.schedule(raw) else { return nil }
            return MLBLegacyMapper.match(game, line: MLBGameMapper.line(raw["linescore"], players: [:]))
        }
        return Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }).values.sorted { $0.date < $1.date }
    }
    func teams() async throws -> [Team] {
        if let (time, cached) = teamCache, Date().timeIntervalSince(time) < 86400 { return cached }
        let response = try await client.teams()
        let result = await MainActor.run { response.raw["teams"].array.compactMap { MLBGameMapper.team($0) }.map { team in
            Team(id: String(team.id), displayName: team.name, shortDisplayName: team.abbreviation, abbreviation: team.abbreviation,
                 logoURL: team.logo, canonicalIDString: "team:league.baseball-mlb:mlb:\(team.id)")
        }
        }
        teamCache = (Date(), result); return result
    }
    func standings() async throws -> [StandingsGroup] {
        if let (time, cached) = standingCache, Date().timeIntervalSince(time) < 900 { return cached }
        let response = try await client.standings(season: Calendar.current.component(.year, from: Date()))
        let result = response.raw["records"].array.map { group in
            StandingsGroup(id: group["division"]["id"].string ?? group["league"]["id"].string ?? "MLB", name: group["division"]["name"].string ?? group["league"]["name"].string ?? "MLB",
                rows: group["teamRecords"].array.compactMap { row in
                    guard let team = MLBGameMapper.team(row["team"]) else { return nil }
                    return StandingRow(teamID: String(team.id), displayName: team.name, abbreviation: team.abbreviation, logoURL: team.logo,
                        record: [row["wins"].string, row["losses"].string].compactMap { $0 }.joined(separator: "-"), wins: row["wins"].string, losses: row["losses"].string, ties: nil,
                        winPercent: row["winningPercentage"].string, gamesBack: row["divisionGamesBack"].string, streak: row["streak"]["streakCode"].string,
                        pointsFor: row["runsScored"].string, pointsAgainst: row["runsAllowed"].string, leaguePoints: nil, gamesPlayed: row["gamesPlayed"].string, goalDiff: row["runDifferential"].string,
                        divisionRank: row["divisionRank"].string, leagueRank: row["leagueRank"].string, wildCardRank: row["wildCardRank"].string, wildCardGamesBack: row["wildCardGamesBack"].string,
                        lastTen: row["records"]["splitRecords"].array.first { $0["type"].string == "lastTen" }.map { "\($0["wins"].string ?? "–")-\($0["losses"].string ?? "–")" })
                })
        }
        standingCache = (Date(), result); return result
    }
    func roster(teamID: String) async throws -> [RosterGroup] {
        if let (time, cached) = rosterCache[teamID], Date().timeIntervalSince(time) < 3600 { return cached }
        guard let id = Int(teamID) else { throw MLBAPIError.invalidResponse }
        let response = try await client.roster(teamID: id)
        let players = response.raw["roster"].array.compactMap { row -> RosterAthlete? in
            guard var player = MLBGameMapper.player(row["person"]) else { return nil }
            player.position = row["position"]["abbreviation"].string; player.jersey = row["jerseyNumber"].string
            return MLBLegacyMapper.athlete(player)
        }
        let groups = Dictionary(grouping: players) { $0.position == "P" ? "Pitchers" : "Position players" }
        let result = groups.keys.sorted().map { RosterGroup(id: $0, title: $0, athletes: groups[$0] ?? []) }
        rosterCache[teamID] = (Date(), result); return result
    }
    func playerOverview(id: String) async throws -> AthleteOverview {
        if let (time, cached) = personCache[id], Date().timeIntervalSince(time) < 3600 { return cached }
        guard let number = Int(id) else { throw MLBAPIError.invalidResponse }
        let response = try await client.player(playerID: number)
        guard let person = response.raw["people"].array.first else { throw MLBAPIError.invalidResponse }
        let values = person["stats"].array.flatMap { group in group["splits"].array.flatMap { split in
            split["stat"].object.sorted { $0.key < $1.key }.compactMap { key, value -> StatValue? in
                guard let text = value.string else { return nil }
                return StatValue(label: "\(group["group"]["displayName"].string ?? "stats"):\(key)", displayName: MLBPlayDescriptionBuilder.humanize(key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)), value: text)
            }
        } }
        let result = AthleteOverview(statlineLabel: "Season", stats: values, headlineStats: Array(values.prefix(4)), news: [])
        personCache[id] = (Date(), result); return result
    }
}
