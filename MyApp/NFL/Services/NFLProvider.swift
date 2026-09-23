import Foundation

actor NFLProvider: NativeSportsProvider {
    nonisolated let leaguePath = "football/nfl"
    private let client: NFLShieldClient
    init(client: NFLShieldClient = .shared) { self.client = client }
    func weeks(season: Int, type: NFLSeasonType) async throws -> [NFLWeekChoice] {
        let response = try await client.weeks(season: season, type: type)
        return response["weeks"].array.compactMap { raw in
            guard let number = raw["week"].int else { return nil }
            let label = ["WC": "Wild Card", "DIV": "Divisional", "CONF": "Conference Championship", "SB": "Super Bowl"][raw["weekType"].string ?? ""] ?? "Week \(number)"
            return NFLWeekChoice(week: NFLWeek(season: season, seasonType: type, week: number), label: label)
        }.sorted { $0.id < $1.id }
    }
    func weekSchedule(_ week: NFLWeek) async throws -> [Match] {
        let response = try await client.weeklyGameDetails(week, drives: false)
        let metadata = try await teamsByID(season: week.season)
        let games = response.games.compactMap { NFLGameMapper.game($0, metadata: metadata) }.sorted { $0.start < $1.start }
        return await MainActor.run { games.map(NFLLegacyMapper.match) }
    }
    func scores(on date: Date?) async throws -> [Match] {
        let day = date ?? Date(), week = try await client.week(for: date ?? Date())
        let details = try await client.weeklyGameDetails(week, drives: false)
        let metadata = try await teamsByID(season: week.season)
        var games = details.games.compactMap { NFLGameMapper.game($0, metadata: metadata) }
        if date != nil { games = games.filter { Calendar.current.isDate($0.start, inSameDayAs: day) } }
        let result = games
        return await MainActor.run { result.map(NFLLegacyMapper.match) }
    }
    func schedule(start: Date, days: Int) async throws -> [Match] {
        var weeks = Set<NFLWeek>(), games: [String: NFLGameState] = [:]
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start) ?? start
        var day = start
        while day < end {
            let week = try await client.week(for: day)
            if weeks.insert(week).inserted {
                let metadata = try await teamsByID(season: week.season)
                for raw in try await client.weeklyGameDetails(week, drives: false).games {
                    if let game = NFLGameMapper.game(raw, metadata: metadata), game.start >= Calendar.current.startOfDay(for: start), game.start < end { games[game.id] = game }
                }
            }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? end
        }
        let values = games.values.sorted { $0.start < $1.start }
        return await MainActor.run { values.map(NFLLegacyMapper.match) }
    }
    func teamsByID(season: Int) async throws -> [String: NFLValue] {
        let raw = try await client.get(.seasonResource("teams/history", season: season), as: NFLValue.self, maxAge: 86400)
        return Dictionary(raw["teams"].array.compactMap { team in team["id"].string.map { ($0, team) } }, uniquingKeysWith: { _, new in new })
    }
    func teams() async throws -> [Team] {
        let week = try await client.week(for: Date())
        let metadata = try await teamsByID(season: week.season)
        return await MainActor.run {
            metadata.values.filter { $0["divisionFullName"].string != nil }.compactMap { NFLGameMapper.team($0) }.sorted { $0.name < $1.name }.map {
                Team(id: $0.id, displayName: $0.name, shortDisplayName: $0.abbreviation, abbreviation: $0.abbreviation, logoURL: $0.logo,
                     canonicalIDString: "team:league.football-nfl:nfl:\($0.id)")
            }
        }
    }
    func standings() async throws -> [StandingsGroup] {
        let week = try await client.week(for: Date())
        let raw = try await client.get(.resource("standings", week: week), as: NFLValue.self, maxAge: 900)
        let teams = try await teamsByID(season: week.season)
        let rows = raw["weeks"].array.flatMap { $0["standings"].array }
        let groups = Dictionary(grouping: rows) { teams[$0["team"]["id"].string ?? ""]?["divisionFullName"].string ?? "NFL" }
        return groups.keys.sorted().map { key in
            StandingsGroup(id: key, name: key, rows: (groups[key] ?? []).compactMap { row in
                guard let team = NFLGameMapper.team(row["team"], metadata: teams[row["team"]["id"].string ?? ""] ?? .null) else { return nil }
                let total = row["overall"]
                return StandingRow(teamID: team.id, displayName: team.name, abbreviation: team.abbreviation, logoURL: team.logo,
                    record: [total["wins"].string, total["losses"].string, total["ties"].string].compactMap { $0 }.joined(separator: "-"),
                    wins: total["wins"].string, losses: total["losses"].string, ties: total["ties"].string, winPercent: total["winPct"].string,
                    gamesBack: nil, streak: [total["streak"]["type"].string, total["streak"]["length"].string].compactMap { $0 }.joined(),
                    pointsFor: total["points"]["for"].string, pointsAgainst: total["points"]["against"].string, leaguePoints: nil,
                    gamesPlayed: total["games"].string, goalDiff: nil, divisionRank: row["division"]["rank"].string, leagueRank: row["conference"]["rank"].string)
            })
        }
    }
    func roster(teamID: String) async throws -> [RosterGroup] {
        let week = try await client.week(for: Date())
        let raw = try await client.get(.seasonResource("rosters", season: week.season), as: NFLValue.self, maxAge: 14400)
        let persons = raw["rosters"].array.first { $0["team"]["id"].string == teamID }?["persons"].array ?? []
        let groups = Dictionary(grouping: persons) { $0["positionGroup"].string ?? "Players" }
        return groups.keys.sorted().map { key in RosterGroup(id: key, title: key, athletes: (groups[key] ?? []).compactMap { person in
            guard let id = person["id"].string, let name = person["displayName"].string else { return nil }
            var player = RosterAthlete(id: id, displayName: name, jersey: person["jerseyNumber"].string, position: person["position"].string,
                positionName: person["position"].string, headshotURL: NFLGameMapper.image(person["headshot"].string), age: nil,
                displayHeight: person["height"].int.map { "\($0 / 12)′ \($0 % 12)″" }, displayWeight: person["weight"].string.map { "\($0) lb" },
                college: person["collegeNames"].array.compactMap(\.string).joined(separator: ", "), experienceYears: person["nflExperience"].int,
                birthPlace: nil, isInjured: false)
            player.canonicalID = "player:league.football-nfl:nfl:\(id)"; return player
        }) }
    }
    func injuries() async throws -> [LeagueInjury] {
        let week = try await client.week(for: Date())
        let response = try await client.injuries(week)
        let teams = try await teamsByID(season: week.season)
        return response["injuries"].array.compactMap { row in
            guard let id = row["person"]["id"].string, let name = row["person"]["displayName"].string,
                  let status = row["injuryStatus"].string else { return nil }
            return LeagueInjury(id: id, athleteName: name, teamAbbreviation: teams[row["team"]["id"].string ?? ""]?["abbreviation"].string,
                position: row["position"].string, status: status.capitalized, detail: row["injuries"].array.compactMap(\.string).joined(separator: ", "),
                headshotURL: NFLGameMapper.image(row["person"]["headshot"].string))
        }
    }
    func playerOverview(id: String) async throws -> AthleteOverview {
        let week = try await client.week(for: Date())
        let raw = try await client.get(.seasonResource("rosters", season: week.season), as: NFLValue.self, maxAge: 14400)
        guard let person = raw["rosters"].array.flatMap({ $0["persons"].array }).first(where: { $0["id"].string == id }) else { throw NFLAPIError.invalidResponse }
        let stats = ["position", "jerseyNumber", "nflExperience", "height", "weight"].compactMap { key -> StatValue? in
            guard let value = person[key].string else { return nil }
            return StatValue(label: key, displayName: ["position": "Position", "jerseyNumber": "Number", "nflExperience": "Experience", "height": "Height (in)", "weight": "Weight (lb)"][key] ?? key, value: value)
        }
        return AthleteOverview(statlineLabel: "Player", stats: stats, headlineStats: Array(stats.prefix(3)), news: [])
    }
}
