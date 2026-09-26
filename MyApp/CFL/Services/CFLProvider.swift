import Foundation

actor CFLProvider: NativeSportsProvider {
    nonisolated let leaguePath = "football/cfl"
    private let client: CFLClient
    init(client: CFLClient = .shared) { self.client = client }

    private func teamsByID() async throws -> [String: CFLValue] {
        let raw = try await client.get(.teams, as: [CFLValue].self, maxAge: 3600)
        return Dictionary(raw.compactMap { team in team["ID"].string.map { ($0, team) } }, uniquingKeysWith: { _, new in new })
    }
    private func venuesByID() async throws -> [String: CFLValue] {
        let raw = try await client.get(.venues, as: [CFLValue].self, maxAge: 86400)
        return Dictionary(raw.compactMap { venue in venue["ID"].string.map { ($0, venue) } }, uniquingKeysWith: { _, new in new })
    }
    private func fixtures(year: Int) async throws -> (seasonID: Int, games: [CFLGameState]) {
        let seasonID = try await CFLSeasonIdentity.shared.seasonID(for: year)
        let raw = try await client.get(.fixtures(seasonID: seasonID), as: [CFLValue].self, maxAge: 300)
        let teams = try await teamsByID()
        let venues = try await venuesByID()
        let games = raw.compactMap { CFLFixtureMapper.game($0, teams: teams, venues: venues, seasonID: seasonID, year: year) }
        return (seasonID, games)
    }
    func scores(on date: Date?) async throws -> [Match] {
        let day = date ?? Date()
        let year = Calendar.current.component(.year, from: day)
        let (_, games) = try await fixtures(year: year)
        let filtered = date == nil ? games : games.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
        return await MainActor.run { filtered.sorted { $0.start < $1.start }.map(CFLLegacyMapper.match) }
    }
    func schedule(start: Date, days: Int) async throws -> [Match] {
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start) ?? start
        var years = Set<Int>(), games: [String: CFLGameState] = [:]
        var day = start
        while day < end {
            years.insert(Calendar.current.component(.year, from: day))
            day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? end
        }
        for year in years {
            let (_, yearGames) = try await fixtures(year: year)
            for game in yearGames where game.start >= Calendar.current.startOfDay(for: start) && game.start < end { games[game.id] = game }
        }
        let values = games.values.sorted { $0.start < $1.start }
        return await MainActor.run { values.map(CFLLegacyMapper.match) }
    }
    func teams() async throws -> [Team] {
        let raw = try await teamsByID()
        return await MainActor.run {
            raw.values.compactMap { team -> Team? in
                guard let id = team["ID"].string else { return nil }
                let abbreviation = team["abbreviation"].string ?? "CFL"
                return Team(id: id, displayName: team["clubname"].string ?? abbreviation, shortDisplayName: abbreviation,
                    abbreviation: abbreviation, logoURL: nil, canonicalIDString: "team:league.football-cfl:cfl:\(id)")
            }.sorted { $0.displayName < $1.displayName }
        }
    }
    func standings() async throws -> [StandingsGroup] {
        let year = Calendar.current.component(.year, from: Date())
        let raw = try await client.get(.standings(year: year), as: CFLValue.self, maxAge: 900)
        let teams = try await teamsByID()
        return CFLStandingsMapper.groups(raw, teams: teams)
    }
    func roster(teamID: String) async throws -> [RosterGroup] {
        let raw = try await client.get(.roster(teamID: teamID), as: CFLValue.self, maxAge: 14400)
        return CFLRosterMapper.groups(raw)
    }
    func playerOverview(id: String) async throws -> AthleteOverview {
        let year = Calendar.current.component(.year, from: Date())
        let seasonID = try await CFLSeasonIdentity.shared.seasonID(for: year)
        let raw = try await client.get(.playerRecords(seasonID: seasonID), as: [CFLValue].self, maxAge: 3600)
        guard let record = raw.first(where: { $0["player_id"].string == id }) else { throw CFLAPIError.invalidResponse }
        let position = record["position"].string
        let stats: [StatValue] = position.map { [StatValue(label: "position", displayName: "Position", value: $0)] } ?? []
        return AthleteOverview(statlineLabel: "Player", stats: stats, headlineStats: stats, news: [])
    }
    /// Not part of `NativeSportsProvider` — league leaders, never polled during a live
    /// Game Centre (Step: leaders isolation).
    func leaders(year: Int) async throws -> [String: [CFLLeaderCategory]] {
        let raw = try await CFLStatsClient.shared.leaders(year: year)
        return CFLLeadersMapper.groups(raw)
    }
}
