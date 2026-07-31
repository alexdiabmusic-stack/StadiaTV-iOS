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
        // Keep the timeout tight: Home fans out across many leagues and a
        // single stalled request otherwise delays the slowest phase.
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 8
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

    /// Fetches scoreboards for consecutive days and removes duplicate events.
    /// ESPN caps the events returned per request, so long windows (e.g. a full
    /// year of favorite-team games) are split into concurrent 30-day ranged requests.
    func scoreboards(for league: League, starting startDate: Date, days: Int) async throws -> [Match] {
        let calendar = Calendar.current
        var windows: [(start: Date, end: Date)] = []
        var windowStart = startDate
        var remaining = max(1, days)
        while remaining > 0 {
            let length = min(30, remaining)
            let windowEnd = calendar.date(byAdding: .day, value: length - 1, to: windowStart) ?? windowStart
            windows.append((windowStart, windowEnd))
            windowStart = calendar.date(byAdding: .day, value: length, to: windowStart) ?? windowEnd
            remaining -= length
        }

        var matches: [Match] = []
        try await withThrowingTaskGroup(of: [Match].self) { group in
            for window in windows {
                group.addTask {
                    try await scoreboardRange(for: league, from: window.start, to: window.end)
                }
            }
            for try await loaded in group {
                matches.append(contentsOf: loaded)
            }
        }

        if Self.rangeIncludesToday(start: startDate, end: windows.last?.end ?? startDate),
           let todayMatches = try? await scoreboard(for: league) {
            matches.append(contentsOf: todayMatches)
        }

        return Self.uniqueMatchesPreferringLatest(matches)
    }

    /// A single ranged scoreboard request (dates=YYYYMMDD-YYYYMMDD).
    private func scoreboardRange(for league: League, from startDate: Date, to endDate: Date) async throws -> [Match] {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/scoreboard")!
        components.queryItems = [
            URLQueryItem(name: "dates", value: "\(Self.dateFormatter.string(from: startDate))-\(Self.dateFormatter.string(from: endDate))"),
            URLQueryItem(name: "limit", value: "1000"),
        ]

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }
        let decoded = try JSONDecoder().decode(ScoreboardResponse.self, from: data)
        return decoded.events?.compactMap { $0.toMatch(league: league) } ?? []
    }

    /// Fetches recent ESPN articles for a league.
    func news(for league: League, limit: Int = 10) async throws -> [ESPNArticle] {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/news")!
        components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }
        let decoded = try JSONDecoder().decode(NewsResponse.self, from: data)
        return decoded.articles?.compactMap { $0.toArticle(league: league) } ?? []
    }

    /// Fetches every team in a league (used by the onboarding team picker).
    func teams(for league: League) async throws -> [Team] {
        guard league.group != .golf else { return [] }

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

    /// Fetches the full article body by loading the article's web page and extracting
    /// content from ESPN's Next.js `__NEXT_DATA__` JSON blob, falling back to `<p>` tag parsing.
    /// This is the primary content path — ESPN's API endpoints only return teasers.
    func articleBodyFromURL(_ url: URL) async throws -> [String] {
        var request = URLRequest(url: url)
        // Desktop Safari UA to get server-side rendered HTML with full article content
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ServiceError.badResponse
        }

        // Primary: extract from Next.js __NEXT_DATA__ JSON (structured, clean text)
        if let paragraphs = Self.extractFromNextData(html), paragraphs.count >= 2 {
            return paragraphs
        }

        // Fallback: parse <p> tags from the article section of the HTML
        return Self.extractParagraphsFromHTML(html)
    }

    /// Extracts the "story" HTML from ESPN's server-side Next.js JSON blob.
    private static func extractFromNextData(_ html: String) -> [String]? {
        guard let markerRange = html.range(of: "id=\"__NEXT_DATA__\"") else { return nil }
        guard let tagClose = html.range(of: ">", range: markerRange.upperBound..<html.endIndex) else { return nil }
        guard let scriptClose = html.range(of: "</script>", options: .caseInsensitive,
                                             range: tagClose.upperBound..<html.endIndex) else { return nil }

        let jsonStr = String(html[tagClose.upperBound..<scriptClose.lowerBound])
        guard let jsonData = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }

        // Recursively find the longest "story" value that looks like HTML content
        guard let storyHTML = deepFindLongest(key: "story", in: root, minLength: 200) else { return nil }
        return extractParagraphs(from: storyHTML)
    }

    /// Recursively searches JSON for the longest string value matching `key` with at least `minLength` characters.
    private static func deepFindLongest(key: String, in value: Any, minLength: Int) -> String? {
        var best: String? = nil
        func search(_ v: Any) {
            switch v {
            case let dict as [String: Any]:
                if let str = dict[key] as? String, str.count >= minLength, str.count > (best?.count ?? 0) {
                    best = str
                }
                dict.values.forEach { search($0) }
            case let arr as [Any]:
                arr.forEach { search($0) }
            default: break
            }
        }
        search(value)
        return best
    }

    /// Fallback HTML parser: isolates the article section then pulls `<p>` tag content.
    private static func extractParagraphsFromHTML(_ html: String) -> [String] {
        // Narrow scope to the article body to avoid nav/footer noise
        var scope = html
        for marker in ["class=\"article-body\"", "class=\"story__text\"", "class=\"article__body\"", "<article"] {
            if let r = html.range(of: marker) { scope = String(html[r.lowerBound...]); break }
        }

        var result: [String] = []
        var remaining = scope
        while let pOpen = remaining.range(of: "<p", options: .caseInsensitive),
              let tagEnd = remaining.range(of: ">", range: pOpen.upperBound..<remaining.endIndex),
              let pClose = remaining.range(of: "</p>", options: .caseInsensitive,
                                           range: tagEnd.upperBound..<remaining.endIndex) {
            let inner = String(remaining[tagEnd.upperBound..<pClose.lowerBound])
            result.append(contentsOf: extractParagraphs(from: inner))
            remaining = String(remaining[pClose.upperBound...])
            if remaining.contains("class=\"footer\"") || remaining.contains("id=\"footer\"") { break }
        }
        return result
    }

    /// Converts ESPN HTML story content into plain-text paragraphs (used by both the API and HTML paths).
    static func extractParagraphs(from html: String) -> [String] {
        guard !html.isEmpty else { return [] }
        var text = html
        for tag in ["</p>", "</h1>", "</h2>", "</h3>", "</li>", "<br>", "<br/>", "<br />"] {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        while let open = text.range(of: "<"),
              let close = text.range(of: ">", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("&ndash;", "–"), ("&mdash;", "—"), ("&hellip;", "…"),
            ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
            ("&bull;", "•"), ("&copy;", "©"), ("&reg;", "®"),
        ]
        for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 20 }
    }

    /// Fetches the full entry list for a racing league's current event
    /// (e.g. every F1 driver) from the ESPN scoreboard, then syncs each
    /// racer's constructor/team from ESPN's core athlete records.
    func racers(for league: League) async throws -> [Racer] {
        let components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/scoreboard")!
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }
        let decoded = try JSONDecoder().decode(ScoreboardResponse.self, from: data)
        let entrants = decoded.events?.first?.toRacers() ?? []
        return await withTeams(entrants, league: league)
    }

    /// The scoreboard doesn't carry constructors, so look each racer up in the
    /// core API (e.g. racing/leagues/f1/athletes/{id}), which lists their vehicle/team.
    private func withTeams(_ racers: [Racer], league: League) async -> [Racer] {
        // "racing/f1" -> "racing/leagues/f1"
        let corePath = league.path.replacingOccurrences(of: "/", with: "/leagues/")
        var teamsByRacerID: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for racer in racers {
                group.addTask { [session] in
                    let url = URL(string: "https://sports.core.api.espn.com/v2/sports/\(corePath)/athletes/\(racer.id)")!
                    guard let (data, response) = try? await session.data(from: url),
                          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let vehicles = json["vehicles"] as? [[String: Any]],
                          let vehicle = vehicles.first else {
                        return (racer.id, nil)
                    }
                    return (racer.id, vehicle["team"] as? String ?? vehicle["manufacturer"] as? String)
                }
            }
            for await (id, team) in group {
                teamsByRacerID[id] = team
            }
        }
        return racers.map { racer in
            guard let team = teamsByRacerID[racer.id], !team.isEmpty else { return racer }
            return Racer(id: racer.id, name: racer.name, shortName: racer.shortName,
                         teamName: team, place: racer.place, flagURL: racer.flagURL,
                         isWinner: racer.isWinner)
        }
    }

    private static func rangeIncludesToday(start: Date, end: Date) -> Bool {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return today >= calendar.startOfDay(for: start) && today <= calendar.startOfDay(for: end)
    }

    private static func uniqueMatchesPreferringLatest(_ matches: [Match]) -> [Match] {
        var order: [String] = []
        var byID: [String: Match] = [:]
        for match in matches {
            if byID[match.id] == nil {
                order.append(match.id)
            }
            byID[match.id] = match
        }
        return order.compactMap { byID[$0] }.sorted { $0.date < $1.date }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}

// MARK: - News response models

private struct NewsResponse: Decodable {
    let articles: [ArticleDTO]?
}

private struct ArticleDTO: Decodable {
    let id: Int?
    let headline: String?
    let description: String?
    let published: String?
    let links: ArticleLinksDTO?
    let images: [ArticleImageDTO]?

    func toArticle(league: League) -> ESPNArticle? {
        guard let headline, !headline.isEmpty else { return nil }
        let urlString = links?.web?.href ?? links?.mobile?.href
        return ESPNArticle(
            id: id.map(String.init) ?? "\(league.id)-\(headline)",
            headline: headline,
            description: description ?? "",
            published: published.flatMap {
                EventDTO.isoFormatter.date(from: $0)
                    ?? EventDTO.minuteFormatter.date(from: $0)
                    ?? EventDTO.isoFractionalFormatter.date(from: $0)
            },
            url: urlString.flatMap(URL.init(string:)),
            imageURL: images?.first?.url.flatMap(URL.init(string:)),
            league: league
        )
    }
}

private struct ArticleLinksDTO: Decodable {
    let web: ArticleLinkDTO?
    let mobile: ArticleLinkDTO?
}

private struct ArticleLinkDTO: Decodable {
    let href: String?
}

private struct ArticleImageDTO: Decodable {
    let url: String?
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
        if league.group == .racing { return toRaceMatch(league: league) }
        if league.group == .golf { return toGolfMatch(league: league) }
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

    /// Golf events carry a leaderboard of athletes instead of two teams. The top
    /// two listed players stand in as sides so existing match rows and detail
    /// screens can present the event consistently.
    private func toGolfMatch(league: League) -> Match? {
        let competition = competitions?.first
        let golfers = (competition?.competitors ?? [])
            .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }

        let status = competition?.status ?? status
        let state = Self.gameState(from: status?.type?.state)
        let date = Self.parseDate(date)
        let placeholder = TeamSide(displayName: "Field", shortName: "Field", abbreviation: "",
                                   logoURL: nil, score: nil, record: nil, isWinner: false)

        return Match(
            id: id,
            league: league,
            date: date,
            name: name ?? "Golf Tournament",
            shortName: shortName ?? name ?? "Golf",
            state: state,
            statusDetail: Self.statusDetail(status: status, state: state, date: date),
            home: golfers.dropFirst().first?.toGolferSide() ?? placeholder,
            away: golfers.first?.toGolferSide() ?? placeholder,
            broadcasts: competition?.broadcastNames ?? [],
            venue: competition?.venue?.fullName
        )
    }

    /// Racing events (F1) carry the weekend's sessions and their competitors are
    /// athletes, not teams. The main race is the session with the most entrants;
    /// the top two drivers stand in for the two "team" sides of a `Match`.
    private func toRaceMatch(league: League) -> Match? {
        let competition = raceCompetition
        let racers = (competition?.competitors ?? [])
            .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }

        let status = competition?.status ?? status
        let state = Self.gameState(from: status?.type?.state)
        let date = Self.parseDate(date)

        let placeholder = TeamSide(displayName: "TBD", shortName: "TBD", abbreviation: "",
                                   logoURL: nil, score: nil, record: nil, isWinner: false)
        return Match(
            id: id,
            league: league,
            date: date,
            name: name ?? "Race",
            shortName: shortName ?? "",
            state: state,
            statusDetail: Self.statusDetail(status: status, state: state, date: date),
            home: racers.dropFirst().first?.toRacerSide() ?? placeholder,
            away: racers.first?.toRacerSide() ?? placeholder,
            broadcasts: competition?.broadcastNames ?? [],
            venue: competition?.venue?.fullName
        )
    }

    /// The main race session of a racing weekend. ESPN lists FP1…Quali…Race;
    /// prefer the session typed "Race", falling back to the last session.
    private var raceCompetition: CompetitionDTO? {
        competitions?.first { ($0.type?.abbreviation ?? $0.type?.text ?? "").lowercased().contains("race") }
            ?? competitions?.last
    }

    /// Maps every entrant of the event's main session to a `Racer`.
    func toRacers() -> [Racer] {
        let entrants = (raceCompetition?.competitors ?? [])
            .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
        return entrants.enumerated().compactMap { index, dto in
            guard let athlete = dto.athlete,
                  let name = athlete.displayName ?? athlete.fullName else { return nil }
            return Racer(
                id: dto.id ?? "\(id)-\(index)",
                name: name,
                shortName: athlete.shortName ?? name,
                teamName: dto.vehicle?.manufacturer ?? "Independent",
                place: dto.order,
                flagURL: athlete.flag?.href.flatMap(URL.init(string:)),
                isWinner: dto.winner ?? false
            )
        }
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
        // ESPN usually omits seconds ("2026-07-18T23:00Z"), which ISO8601DateFormatter rejects.
        return minuteFormatter.date(from: string)
            ?? isoFormatter.date(from: string)
            ?? isoFractionalFormatter.date(from: string)
            ?? Date()
    }

    static func statusDetail(status: StatusDTO?, state: GameState, date: Date) -> String {
        if let detail = status?.type?.shortDetail, !detail.isEmpty, state != .pre {
            return detail
        }
        // Upcoming: show local day and start time, e.g. "Today · 7:00 PM" or "Sat, Jul 25 · 7:00 PM".
        let calendar = Calendar.current
        let time = timeFormatter.string(from: date)
        if calendar.isDateInToday(date) { return "Today · \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow · \(time)" }
        return "\(dayFormatter.string(from: date)) · \(time)"
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f
    }()

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Handles ESPN's second-less timestamps, e.g. "2026-07-18T23:00Z".
    static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mmZZZZZ"
        return f
    }()
}

private struct CompetitionDTO: Decodable {
    let type: CompetitionTypeDTO?
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
    let id: String?
    let homeAway: String?
    let score: String?
    let winner: Bool?
    let order: Int?
    let team: TeamDTO?
    let athlete: RaceAthleteDTO?
    let vehicle: VehicleDTO?
    let records: [RecordDTO]?

    /// Golf competitors are leaderboard athletes; score carries their current
    /// tournament total, and order carries leaderboard position.
    func toGolferSide() -> TeamSide {
        let name = athlete?.displayName ?? athlete?.fullName ?? "TBD"
        return TeamSide(
            displayName: name,
            shortName: athlete?.shortName ?? name,
            abbreviation: "",
            logoURL: athlete?.flag?.href.flatMap(URL.init(string:)),
            score: score,
            record: order.map { "#\($0)" },
            isWinner: winner ?? false,
            teamID: nil
        )
    }

    /// Racing competitors are drivers; the constructor shows where a record would.
    func toRacerSide() -> TeamSide {
        TeamSide(
            displayName: athlete?.displayName ?? athlete?.fullName ?? "TBD",
            shortName: athlete?.shortName ?? athlete?.displayName ?? "TBD",
            abbreviation: "",
            logoURL: athlete?.flag?.href.flatMap(URL.init(string:)),
            score: nil,
            record: vehicle?.manufacturer,
            isWinner: winner ?? false,
            teamID: nil
        )
    }

    func toTeamSide() -> TeamSide {
        TeamSide(
            displayName: team?.displayName ?? "TBD",
            shortName: team?.shortDisplayName ?? team?.name ?? "TBD",
            abbreviation: team?.abbreviation ?? "",
            logoURL: team?.logo.flatMap(URL.init(string:)),
            score: score,
            record: records?.first(where: { $0.type == "total" })?.summary ?? records?.first?.summary,
            isWinner: winner ?? false,
            teamID: team?.id
        )
    }
}

private struct TeamDTO: Decodable {
    let id: String?
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

private struct RaceAthleteDTO: Decodable {
    let fullName: String?
    let displayName: String?
    let shortName: String?
    let flag: FlagDTO?
}

private struct FlagDTO: Decodable {
    let href: String?
}

private struct VehicleDTO: Decodable {
    let number: String?
    let manufacturer: String?
}

private struct CompetitionTypeDTO: Decodable {
    let abbreviation: String?
    let text: String?
}

/// Core API athlete record (sports.core.api.espn.com); carries the racer's vehicle/team.
private struct CoreRaceAthleteDTO: Decodable {
    let vehicles: [CoreVehicleDTO]?
}

private struct CoreVehicleDTO: Decodable {
    let team: String?
    let manufacturer: String?
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
