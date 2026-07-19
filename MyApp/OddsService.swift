import Foundation

struct MatchOddsDisplay: Equatable {
    let bookmakerName: String
    let awayPrice: Int?
    let homePrice: Int?
    let drawPrice: Int?

    var hasGameLine: Bool {
        awayPrice != nil || homePrice != nil || drawPrice != nil
    }
}

struct OddsService {
    enum OddsError: LocalizedError {
        case notConfigured
        case invalidURL
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Odds are disabled until an API key is provided through app configuration."
            case .invalidURL:
                return "The odds API URL is invalid."
            case .badResponse:
                return "The MoneyLine API returned an unexpected response."
            }
        }
    }

    private let session: URLSession
    private let baseURL: URL
    private let apiKey: String?

    init(session: URLSession = .shared, baseURL: URL = AppConfiguration.oddsAPIBaseURL, apiKey: String? = AppConfiguration.oddsAPIKey) {
        self.session = session
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    var isConfigured: Bool {
        apiKey != nil
    }

    func ensureConfigured() throws {
        guard isConfigured else { throw OddsError.notConfigured }
    }

    func odds(for match: Match) async throws -> MatchOddsDisplay? {
        try ensureConfigured()
        guard let leagueID = oddsLeagueID(for: match.league) else { return nil }
        let events = try await browseOdds(leagueID: leagueID)
        guard let event = bestEventMatch(for: match, in: events) else { return nil }
        let detail = (try? await eventOdds(eventID: event.eventId)) ?? event
        return display(from: detail, match: match)
    }

    private func browseOdds(leagueID: String) async throws -> [OddsEventDTO] {
        var components = URLComponents(url: baseURL.appending(path: "odds"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "league", value: leagueID),
            URLQueryItem(name: "sourceType", value: "sportsbook"),
            URLQueryItem(name: "market", value: "moneyline"),
            URLQueryItem(name: "limit", value: "50")
        ]
        guard let url = components?.url else { throw OddsError.invalidURL }
        let response: OddsListResponse = try await fetch(url)
        return response.data
    }

    private func eventOdds(eventID: String) async throws -> OddsEventDTO {
        var components = URLComponents(url: baseURL.appending(path: "events/\(eventID)/odds"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "sourceType", value: "sportsbook"),
            URLQueryItem(name: "market", value: "moneyline")
        ]
        guard let url = components?.url else { throw OddsError.invalidURL }
        let response: OddsEventResponse = try await fetch(url)
        return response.data
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        guard let apiKey else { throw OddsError.notConfigured }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OddsError.badResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func bestEventMatch(for match: Match, in events: [OddsEventDTO]) -> OddsEventDTO? {
        let awayTokens = nameTokens(match.away.displayName, match.away.shortName, match.away.abbreviation)
        let homeTokens = nameTokens(match.home.displayName, match.home.shortName, match.home.abbreviation)

        return events
            .map { event in (event, score(event: event, awayTokens: awayTokens, homeTokens: homeTokens)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .first?.0
    }

    private func score(event: OddsEventDTO, awayTokens: Set<String>, homeTokens: Set<String>) -> Int {
        let outcomes = event.bookmakers
            .flatMap(\.markets)
            .filter { $0.marketType == "moneyline" }
            .flatMap(\.outcomes)
            .map { normalize($0.name) }

        var score = 0
        for outcome in outcomes {
            if awayTokens.contains(where: { outcome.contains($0) }) { score += 1 }
            if homeTokens.contains(where: { outcome.contains($0) }) { score += 1 }
        }
        return score
    }

    private func display(from event: OddsEventDTO, match: Match) -> MatchOddsDisplay? {
        guard let bookmaker = preferredBookmaker(from: event.bookmakers) else { return nil }

        let moneyline = bookmaker.markets.first { $0.marketType == "moneyline" }?.outcomes ?? []
        let away = price(for: match.away, outcomes: moneyline)
        let home = price(for: match.home, outcomes: moneyline)
        let draw = moneyline.first { normalize($0.name).contains("draw") }?.price

        let display = MatchOddsDisplay(
            bookmakerName: bookmaker.bookmakerName,
            awayPrice: away,
            homePrice: home,
            drawPrice: draw
        )
        return display.hasGameLine ? display : nil
    }

    private func preferredBookmaker(from bookmakers: [OddsBookmakerDTO]) -> OddsBookmakerDTO? {
        let withMoneyline = bookmakers.filter(hasMoneyline)
        return withMoneyline.first { $0.bookmakerId == "draftkings" }
            ?? withMoneyline.first { $0.sourceType == "sportsbook" }
            ?? withMoneyline.first
    }

    private func hasMoneyline(_ bookmaker: OddsBookmakerDTO) -> Bool {
        bookmaker.markets.contains { market in
            market.marketType == "moneyline" && market.outcomes.contains { $0.price != nil }
        }
    }

    private func price(for team: TeamSide, outcomes: [OddsOutcomeDTO]) -> Int? {
        let teamTokens = nameTokens(team.displayName, team.shortName, team.abbreviation)
        return outcomes.first { outcome in
            let normalized = normalize(outcome.name)
            return teamTokens.contains { normalized.contains($0) }
        }?.price
    }

    private func oddsLeagueID(for league: League) -> String? {
        switch league.path {
        case "football/nfl": return "nfl"
        case "basketball/nba": return "nba"
        case "baseball/mlb": return "mlb"
        case "hockey/nhl": return "nhl"
        default: return nil
        }
    }

    private func nameTokens(_ values: String...) -> Set<String> {
        Set(values.map(normalize).flatMap { normalized in
            var tokens = [normalized]
            tokens.append(contentsOf: normalized.split(separator: " ").map(String.init).filter { $0.count >= 3 })
            return tokens.filter { !$0.isEmpty }
        })
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }
}

private struct OddsListResponse: Decodable {
    let success: Bool
    let data: [OddsEventDTO]
}

private struct OddsEventResponse: Decodable {
    let success: Bool
    let data: OddsEventDTO
}

private struct OddsEventDTO: Decodable {
    let eventId: String
    let leagueId: String?
    let sport: String?
    let bookmakers: [OddsBookmakerDTO]
}

private struct OddsBookmakerDTO: Decodable {
    let bookmakerId: String
    let bookmakerName: String
    let sourceType: String?
    let markets: [OddsMarketDTO]
}

private struct OddsMarketDTO: Decodable {
    let marketType: String
    let outcomes: [OddsOutcomeDTO]
}

private struct OddsOutcomeDTO: Decodable {
    let name: String
    let price: Int?
}
