import Foundation

// MARK: - ESPN networking

/// Fetches scoreboards from ESPN's public site API and maps them into `Match` values.
struct ESPNService {

    enum ServiceError: LocalizedError {
        case badResponse
        var errorDescription: String? { "Couldn't load data from ESPN." }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadRevalidatingCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    /// Fetches the scoreboard for a league. `date` narrows to a single day (YYYYMMDD) when provided.
    func scoreboard(for league: League, on date: Date? = nil) async throws -> [Match] {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/scoreboard")!
        var query: [URLQueryItem] = []
        if let date {
            query.append(URLQueryItem(name: "dates", value: Self.dateFormatter.string(from: date)))
        }
        if !query.isEmpty { components.queryItems = query }

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }
        let decoded = try JSONDecoder().decode(ScoreboardResponse.self, from: data)
        return decoded.events?.compactMap { $0.toMatch(league: league) } ?? []
    }

    /// Fetches every team in a league (used by the onboarding team picker).
    func teams(for league: League) async throws -> [Team] {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/teams")!
        components.queryItems = [URLQueryItem(name: "limit", value: "1000")]

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }
        let decoded = try JSONDecoder().decode(TeamsResponse.self, from: data)
        let entries = decoded.sports?.first?.leagues?.first?.teams ?? []
        return entries.compactMap { $0.team?.toTeam() }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}

// MARK: - Teams response models

private struct TeamsResponse: Decodable {
    let sports: [SportDTO]?
}

private struct SportDTO: Decodable {
    let leagues: [LeagueDTO]?
}

private struct LeagueDTO: Decodable {
    let teams: [TeamEntryDTO]?
}

private struct TeamEntryDTO: Decodable {
    let team: FullTeamDTO?
}

private struct FullTeamDTO: Decodable {
    let id: String?
    let displayName: String?
    let shortDisplayName: String?
    let abbreviation: String?
    let logos: [LogoDTO]?

    func toTeam() -> Team? {
        guard let id, let displayName else { return nil }
        return Team(
            id: id,
            displayName: displayName,
            shortDisplayName: shortDisplayName ?? displayName,
            abbreviation: abbreviation ?? "",
            logoURL: logos?.first?.href.flatMap(URL.init(string:))
        )
    }
}

private struct LogoDTO: Decodable {
    let href: String?
}

// MARK: - Raw ESPN response models

private struct ScoreboardResponse: Decodable {
    let events: [EventDTO]?
}

private struct EventDTO: Decodable {
    let id: String
    let date: String?
    let name: String?
    let shortName: String?
    let competitions: [CompetitionDTO]?
    let status: StatusDTO?

    func toMatch(league: League) -> Match? {
        guard let competition = competitions?.first,
              let competitors = competition.competitors, competitors.count >= 2 else { return nil }

        let homeDTO = competitors.first { $0.homeAway == "home" } ?? competitors[0]
        let awayDTO = competitors.first { $0.homeAway == "away" } ?? competitors[1]

        let status = competition.status ?? status
        let state = Self.gameState(from: status?.type?.state)
        let date = Self.parseDate(date)

        return Match(
            id: id,
            league: league,
            date: date,
            name: name ?? "\(awayDTO.team?.displayName ?? "") @ \(homeDTO.team?.displayName ?? "")",
            shortName: shortName ?? "",
            state: state,
            statusDetail: Self.statusDetail(status: status, state: state, date: date),
            home: homeDTO.toTeamSide(),
            away: awayDTO.toTeamSide(),
            broadcasts: competition.broadcastNames,
            venue: competition.venue?.fullName
        )
    }

    static func gameState(from state: String?) -> GameState {
        switch state {
        case "in": return .live
        case "post": return .final
        default: return .pre
        }
    }

    static func parseDate(_ string: String?) -> Date {
        guard let string else { return Date() }
        return isoFormatter.date(from: string) ?? Date()
    }

    static func statusDetail(status: StatusDTO?, state: GameState, date: Date) -> String {
        if let detail = status?.type?.shortDetail, !detail.isEmpty, state != .pre {
            return detail
        }
        // Upcoming: show local start time.
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private struct CompetitionDTO: Decodable {
    let competitors: [CompetitorDTO]?
    let venue: VenueDTO?
    let broadcasts: [BroadcastDTO]?
    let status: StatusDTO?

    var broadcastNames: [String] {
        (broadcasts ?? []).flatMap { $0.names ?? [] }
    }
}

private struct BroadcastDTO: Decodable {
    let names: [String]?
}

private struct VenueDTO: Decodable {
    let fullName: String?
}

private struct CompetitorDTO: Decodable {
    let homeAway: String?
    let score: String?
    let winner: Bool?
    let team: TeamDTO?
    let records: [RecordDTO]?

    func toTeamSide() -> TeamSide {
        TeamSide(
            displayName: team?.displayName ?? "TBD",
            shortName: team?.shortDisplayName ?? team?.name ?? "TBD",
            abbreviation: team?.abbreviation ?? "",
            logoURL: team?.logo.flatMap(URL.init(string:)),
            score: score,
            record: records?.first(where: { $0.type == "total" })?.summary ?? records?.first?.summary,
            isWinner: winner ?? false
        )
    }
}

private struct TeamDTO: Decodable {
    let displayName: String?
    let shortDisplayName: String?
    let name: String?
    let abbreviation: String?
    let logo: String?
}

private struct RecordDTO: Decodable {
    let type: String?
    let summary: String?
}

private struct StatusDTO: Decodable {
    let type: StatusTypeDTO?
}

private struct StatusTypeDTO: Decodable {
    let state: String?
    let completed: Bool?
    let shortDetail: String?
    let description: String?
}
