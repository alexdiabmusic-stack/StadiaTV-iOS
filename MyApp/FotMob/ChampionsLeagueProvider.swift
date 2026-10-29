import Foundation

/// Explicit Champions League adapter using the app's existing FotMob transport.
/// No fallback to a different competition or fabricated empty response.
actor ChampionsLeagueProvider: NativeSportsProvider {
    static let shared = ChampionsLeagueProvider()
    nonisolated let leaguePath = "soccer/uefa.champions"
    private let client: any FotMobClientProtocol
    private var cached: (date: Date, value: FotMobValue)?
    private var pending: Task<FotMobValue, Error>?

    init(client: any FotMobClientProtocol = FotMobClient.shared) { self.client = client }

    private func snapshot() async throws -> FotMobValue {
        if let cached, Date().timeIntervalSince(cached.date) < 30 { return cached.value }
        if let pending { return try await pending.value }
        let client = client
        let task = Task { try await client.leagues(id: 42, season: nil) }
        pending = task
        defer { pending = nil }
        let raw = try await task.value
        guard raw["details"]["id"].int == 42 else { throw FotMobAPIError.invalidResponse }
        cached = (Date(), raw)
        return raw
    }

    func scores(on date: Date?) async throws -> [Match] {
        let day = date ?? Date()
        return try await schedule(start: day, days: 1)
    }

    func schedule(start: Date, days: Int) async throws -> [Match] {
        guard days > 0 else { return [] }
        let calendar = Calendar.current
        let lower = calendar.startOfDay(for: start)
        guard let upper = calendar.date(byAdding: .day, value: days, to: lower) else { return [] }
        let raw = try await snapshot()
        var matches: [String: Match] = [:]
        for row in raw["fixtures"]["allMatches"].array {
            if let match = ChampionsLeagueMapper.match(row), match.date >= lower, match.date < upper {
                matches[match.id] = match
            }
        }
        return matches.values.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }

    func teams() async throws -> [Team] {
        let raw = try await snapshot()
        var teams: [String: Team] = [:]
        for row in raw["fixtures"]["allMatches"].array {
            for key in ["home", "away"] {
                if let team = ChampionsLeagueMapper.team(row[key]) { teams[team.id] = team }
            }
        }
        return teams.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func standings() async throws -> [StandingsGroup] {
        let raw = try await snapshot()
        return raw["table"].array.enumerated().compactMap { index, table in
            let data = table["data"]
            let rows = data["table"]["all"].array.compactMap { row -> StandingRow? in
                guard let team = ChampionsLeagueMapper.team(row) else { return nil }
                return StandingRow(teamID: team.id, displayName: team.displayName, abbreviation: team.abbreviation,
                    logoURL: team.logoURL, record: [row["wins"].string, row["draws"].string, row["losses"].string].compactMap { $0 }.joined(separator: "-"),
                    wins: row["wins"].string, losses: row["losses"].string, ties: row["draws"].string,
                    winPercent: nil, gamesBack: nil, streak: nil, pointsFor: nil, pointsAgainst: nil,
                    leaguePoints: row["pts"].string, gamesPlayed: row["played"].string, goalDiff: row["goalConDiff"].string)
            }
            guard !rows.isEmpty else { return nil }
            return StandingsGroup(id: "ucl-fotmob-\(index)", name: data["leagueName"].string ?? "UEFA Champions League", rows: rows)
        }
    }

    func roster(teamID: String) async throws -> [RosterGroup] {
        throw SportsDataError.unsupportedCapability(.rosters)
    }

    func playerOverview(id: String) async throws -> AthleteOverview {
        throw SportsDataError.unsupportedCapability(.players)
    }
}

nonisolated enum ChampionsLeagueMapper {
    static let league = League(name: "UEFA Champions League", shortName: "UCL", path: "soccer/uefa.champions", group: .soccer)

    static func team(_ raw: FotMobValue) -> Team? {
        guard let id = raw["id"].string, !id.isEmpty,
              let name = raw["name"].string, !name.isEmpty else { return nil }
        let short = raw["shortName"].string ?? name
        return Team(id: id, displayName: name, shortDisplayName: short, abbreviation: short,
                    logoURL: URL(string: "https://images.fotmob.com/image_resources/logo/teamlogo/\(id).png"),
                    canonicalIDString: "team:\(league.bannerKey):fotmob:\(id)")
    }

    static func match(_ raw: FotMobValue) -> Match? {
        guard let id = raw["id"].string, !id.isEmpty,
              let home = team(raw["home"]), let away = team(raw["away"]),
              let date = FotMobDate.parse(raw["status"]["utcTime"].string) else { return nil }
        let status = FotMobStatusMapper.status(raw["status"])
        let state: GameState = status == .fullTime ? .final : status.isLive ? .live : .pre
        let scores = (raw["status"]["scoreStr"].string ?? "").components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        let validScores = scores.count == 2 && scores.allSatisfy { Int($0) != nil } && state != .pre
        func side(_ team: Team, index: Int) -> TeamSide {
            TeamSide(displayName: team.displayName, shortName: team.shortDisplayName, abbreviation: team.abbreviation,
                     logoURL: team.logoURL, score: validScores ? scores[index] : nil, record: nil, isWinner: false,
                     teamID: team.id, canonicalIDString: team.canonicalIDString)
        }
        let fallback: String
        switch status {
        case .fullTime: fallback = String(localized: "Final")
        case .postponed: fallback = String(localized: "Postponed")
        case .cancelled: fallback = String(localized: "Cancelled")
        case .suspended, .abandoned: fallback = String(localized: "Suspended")
        case .delayed: fallback = String(localized: "Delayed")
        default: fallback = state == .live ? String(localized: "Live") : date.formatted(date: .abbreviated, time: .shortened)
        }
        let detail = status.isLive
            ? (FotMobClockMapper.clock(status: status, raw: raw["status"])?.display ?? raw["status"]["reason"]["long"].string ?? fallback)
            : fallback
        var match = Match(id: id, league: league, date: date, name: "\(away.displayName) at \(home.displayName)",
                          shortName: "\(away.shortDisplayName) @ \(home.shortDisplayName)", state: state, statusDetail: detail,
                          home: side(home, index: 0), away: side(away, index: 1), broadcasts: [], venue: nil)
        match.canonicalID = "game:\(league.bannerKey):fotmob:\(id)"
        return match
    }
}
