import Foundation

actor NHLProvider: NativeSportsProvider {
    nonisolated let leaguePath = "hockey/nhl"
    private let client: any NHLAPIClientProtocol
    private let league = League(name: "NHL", shortName: "NHL", path: "hockey/nhl", group: .hockey)
    private var scoreCache: [String: (Date, [Match])] = [:]
    private var standingsCache: (Date, NHLStandingsResponse)?
    private var rosterCache: [String: (Date, [RosterGroup])] = [:]
    private var scheduleCache: [String: (Date, [Match])] = [:]
    init(client: any NHLAPIClientProtocol = NHLAPIClient.shared) { self.client = client }
    func scores(on date: Date?) async throws -> [Match] {
        let key = date.map(NHLDate.day) ?? "now"
        if let (time, matches) = scoreCache[key], Date().timeIntervalSince(time) < 10 { return matches }
        let response = try await client.score(date: date)
        let matches = response.games.compactMap(NHLGameMapper.game).map { NHLGameMapper.match($0, league: league) }
        scoreCache[key] = (Date(), matches)
        return matches
    }
    func schedule(start: Date, days: Int) async throws -> [Match] {
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start) ?? start
        var cursor = start
        var matches: [String: Match] = [:]
        while cursor < end {
            try Task.checkCancellation()
            let key = NHLDate.day(cursor)
            let loaded: [Match]
            if let (time, cached) = scheduleCache[key], Date().timeIntervalSince(time) < 120 { loaded = cached }
            else {
                let response = try await client.schedule(date: cursor)
                loaded = response.games.compactMap(NHLGameMapper.game).map { NHLGameMapper.match($0, league: league) }
                scheduleCache[key] = (Date(), loaded)
            }
            for match in loaded where match.date >= Calendar.current.startOfDay(for: start) && match.date < end { matches[match.id] = match }
            guard let next = Calendar.current.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        // Today's discovery endpoint owns live scores, even in a long schedule.
        if start <= Date(), end > Date() {
            for match in try await scores(on: nil) { matches[match.id] = match }
        }
        return matches.values.sorted { $0.date < $1.date }
    }
    private func standingRows() async throws -> [NHLValue] {
        if let (time, response) = standingsCache, Date().timeIntervalSince(time) < 900 { return response.rows }
        let response = try await client.standings()
        standingsCache = (Date(), response)
        return response.rows
    }
    func teams() async throws -> [Team] {
        try await standingRows().compactMap { row in
            guard let abbreviation = row["teamAbbrev"].localized else { return nil }
            return Team(id: Self.teamAbbreviations.first(where: { $0.value == abbreviation }).map { String($0.key) } ?? abbreviation, displayName: row["teamName"].localized ?? abbreviation,
                        shortDisplayName: row["teamCommonName"].localized ?? abbreviation, abbreviation: abbreviation,
                        logoURL: TeamLogoAssetResolver.assetURL(leaguePath: leaguePath, abbreviation: abbreviation),
                        canonicalIDString: "team:\(league.bannerKey):nhl:\(Self.teamAbbreviations.first(where: { $0.value == abbreviation }).map { String($0.key) } ?? abbreviation)")
        }
    }
    func standings() async throws -> [StandingsGroup] {
        let rows = try await standingRows()
        let grouped = Dictionary(grouping: rows) { $0["divisionName"].localized ?? "NHL" }
        return grouped.keys.sorted().map { group in
            let standings = (grouped[group] ?? []).sorted { ($0["divisionSequence"].int ?? 99) < ($1["divisionSequence"].int ?? 99) }
            return StandingsGroup(id: group, name: group, rows: standings.compactMap { row in
                guard let abbr = row["teamAbbrev"].localized else { return nil }
                return StandingRow(teamID: Self.teamAbbreviations.first(where: { $0.value == abbr }).map { String($0.key) } ?? abbr, displayName: row["teamName"].localized ?? abbr, abbreviation: abbr,
                                   logoURL: TeamLogoAssetResolver.assetURL(leaguePath: leaguePath, abbreviation: abbr),
                                   record: ["wins","losses","otLosses"].compactMap { row[$0].string }.joined(separator: "-"),
                                   wins: row["wins"].string, losses: row["losses"].string, ties: row["otLosses"].string,
                                   winPercent: row["winPctg"].string, gamesBack: nil, streak: row["streakCode"].string,
                                   pointsFor: row["goalFor"].string, pointsAgainst: row["goalAgainst"].string,
                                   leaguePoints: row["points"].string, gamesPlayed: row["gamesPlayed"].string, goalDiff: row["goalDifferential"].string)
            })
        }
    }
    func roster(teamID: String) async throws -> [RosterGroup] {
        if let (time, cached) = rosterCache[teamID], Date().timeIntervalSince(time) < 3600 { return cached }
        var abbreviation = teamID
        if let number = Int(teamID) {
            // Game identity remains numeric. The roster route requires an abbreviation;
            // resolve it from NHL discovery, never from an ESPN ID or display name.
            let games = try await client.score(date: nil).games
            let team = games.flatMap { [$0.homeTeam, $0.awayTeam] }.first { $0.id == number }
            if let team { abbreviation = team.abbreviation }
            else {
                let currentTeams = try await teams()
                // NHL player/roster responses do not expose a complete team-ID catalog.
                // Team IDs for historical games can be resolved from the bundled NHL catalog.
                abbreviation = Self.teamAbbreviations[number] ?? ""
                guard currentTeams.contains(where: { $0.abbreviation == abbreviation }) || !abbreviation.isEmpty else { throw SportsDataError.invalidResponse }
            }
        }
        let response = try await client.roster(team: abbreviation)
        let players = NHLPlayMapper.roster(response.players).values.sorted { $0.name < $1.name }
        let groups = Dictionary(grouping: players) { $0.position == "G" ? "Goalies" : $0.position == "D" ? "Defensemen" : "Forwards" }
        let result = groups.keys.sorted().map { group in
            RosterGroup(id: group, title: group, athletes: (groups[group] ?? []).map(Self.athlete))
        }
        rosterCache[teamID] = (Date(), result)
        return result
    }
    nonisolated static func athlete(_ player: HockeyPlayerReference) -> RosterAthlete {
        var athlete = RosterAthlete(id: String(player.id), displayName: player.name, jersey: player.jersey.map(String.init),
                                  position: player.position, positionName: player.position, headshotURL: player.headshot, age: nil,
                                  displayHeight: nil, displayWeight: nil, college: nil, experienceYears: nil, birthPlace: nil, isInjured: false)
        athlete.canonicalID = "player:league.hockey-nhl:nhl:\(player.id)"
        return athlete
    }
    func playerOverview(id: String) async throws -> AthleteOverview {
        guard let number = Int(id) else { throw SportsDataError.invalidResponse }
        let player = try await client.player(playerID: number)
        let stats = player.raw["featuredStats"]["regularSeason"]["subSeason"]
        let keys = ["gamesPlayed","goals","assists","points","plusMinus","pim","shots","shootingPctg","wins","losses","savePctg","goalsAgainstAvg","shutouts"]
        let values = keys.compactMap { key -> StatValue? in
            guard let value = stats[key].string else { return nil }
            let names = ["gamesPlayed":"Games played","plusMinus":"+/−","pim":"Penalty minutes","shootingPctg":"Shooting %","savePctg":"Save %","goalsAgainstAvg":"Goals against average"]
            let label = names[key] ?? HockeyPlayDescriptionBuilder.humanize(key)
            return StatValue(label: key, displayName: label, value: value)
        }
        return AthleteOverview(statlineLabel: player.raw["featuredStats"]["season"].string ?? "Season",
                               stats: values, headlineStats: Array(values.prefix(4)), news: [])
    }
    nonisolated static let teamAbbreviations = [1:"NJD",2:"NYI",3:"NYR",4:"PHI",5:"PIT",6:"BOS",7:"BUF",8:"MTL",9:"OTT",10:"TOR",12:"CAR",13:"FLA",14:"TBL",15:"WSH",16:"CHI",17:"DET",18:"NSH",19:"STL",20:"CGY",21:"COL",22:"EDM",23:"VAN",24:"ANA",25:"DAL",26:"LAK",28:"SJS",29:"CBJ",30:"MIN",52:"WPG",53:"ARI",54:"VGK",55:"SEA",59:"UTA"]
}
