import Foundation

// MARK: - Premium ESPN networking
//
// Extends `ESPNService` with the richer endpoints that power the premium
// experience: standings, rosters, player stats & bios, statistical leaders,
// league injury reports, and the real-time "Now" news feed.
//
// These live in a separate file with their own session helper so the core
// scoreboard service stays focused.

/// Shared session tuned for the premium endpoints (short-lived, cached).
private let premiumSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.requestCachePolicy = .reloadRevalidatingCacheData
    config.timeoutIntervalForRequest = 20
    return URLSession(configuration: config)
}()

extension ESPNService {

    // MARK: Generic fetch

    /// Fetches `url` and decodes JSON into `T`, throwing `ServiceError.badResponse` on failure.
    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, response) = try await premiumSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.badResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The `a.espncdn.com` headshot slug for a league, or `nil` when ESPN has no headshots.
    static func headshotSlug(for league: League) -> String? {
        switch league.path {
        case "football/nfl": return "nfl"
        case "basketball/nba": return "nba"
        case "baseball/mlb": return "mlb"
        case "hockey/nhl": return "nhl"
        default:
            return league.group == .soccer ? "soccer" : nil
        }
    }

    private static func headshotURL(league: League, athleteID: String) -> URL? {
        guard let slug = headshotSlug(for: league) else { return nil }
        return URL(string: "https://a.espncdn.com/i/headshots/\(slug)/players/full/\(athleteID).png")
    }

    // MARK: Standings

    /// League standings, flattened into conference/division groups.
    func standings(for league: League) async throws -> [StandingsGroup] {
        // ⚠️ Standings live under /apis/v2/ — /apis/site/v2/ returns a stub.
        let url = URL(string: "https://site.api.espn.com/apis/v2/sports/\(league.path)/standings")!
        let root = try await fetch(StandingsRoot.self, from: url)
        var groups: [StandingsGroup] = []
        root.collectGroups(into: &groups)
        // Fallback: a flat table directly on the root.
        if groups.isEmpty, let table = root.standings?.toGroup(name: league.name) {
            groups.append(table)
        }
        return groups
    }

    // MARK: Roster

    /// A team's roster, grouped by position when the sport provides groupings.
    func roster(for league: League, teamID: String) async throws -> [RosterGroup] {
        let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/teams/\(teamID)/roster")!
        let response = try await fetch(RosterResponse.self, from: url)
        return response.toGroups()
    }

    // MARK: Athlete overview (stats + news)

    /// A player's season stat line and recent news, from the Web overview endpoint.
    func athleteOverview(for league: League, athleteID: String) async throws -> AthleteOverview {
        let url = URL(string: "https://site.web.api.espn.com/apis/common/v3/sports/\(league.path)/athletes/\(athleteID)/overview")!
        let response = try await fetch(AthleteOverviewResponse.self, from: url)
        return response.toOverview(league: league)
    }

    // MARK: Statistical leaders

    /// Statistical leaders boards for a league (best-effort; empty for unsupported sports like soccer).
    func leaders(for league: League) async throws -> [LeaderBoard] {
        var components = URLComponents(string: "https://site.web.api.espn.com/apis/common/v3/sports/\(league.path)/statistics/byathlete")!
        components.queryItems = [URLQueryItem(name: "limit", value: "50")]
        let response = try await fetch(ByAthleteResponse.self, from: components.url!)
        return response.toBoards(league: league)
    }

    // MARK: Injuries

    /// League-wide injury report grouped as a flat, most-severe-first list.
    func injuries(for league: League) async throws -> [LeagueInjury] {
        let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/injuries")!
        let response = try await fetch(InjuriesResponse.self, from: url)
        return response.toInjuries()
    }

    // MARK: Real-time news (Now API)

    /// Real-time news for a league from ESPN's Now feed — fresher and richer than the site news feed.
    func realtimeNews(for league: League, limit: Int = 20) async throws -> [ESPNArticle] {
        guard let leagueSlug = league.path.split(separator: "/").last.map(String.init) else { return [] }
        var components = URLComponents(string: "https://now.core.api.espn.com/v1/sports/news")!
        components.queryItems = [
            URLQueryItem(name: "leagues", value: leagueSlug),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        let response = try await fetch(NowNewsResponse.self, from: components.url!)
        return (response.headlines ?? []).compactMap { $0.toArticle(league: league) }
    }

    // MARK: Game summary (in-game stats)

    /// Boxscore team stats and game leaders for one event.
    func gameSummary(for league: League, eventID: String) async throws -> GameSummary {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/summary")!
        components.queryItems = [URLQueryItem(name: "event", value: eventID)]
        let response = try await fetch(GameSummaryResponse.self, from: components.url!)
        return response.toSummary()
    }
}

// MARK: - Game summary DTOs

private struct GameSummaryResponse: Decodable {
    let boxscore: BoxscoreDTO?
    let leaders: [SummaryLeaderNodeDTO]?

    func toSummary() -> GameSummary {
        let teams = (boxscore?.teams ?? []).compactMap { entry -> GameSummary.TeamBox? in
            guard let info = entry.team, let id = info.id else { return nil }
            let stats = (entry.statistics ?? []).compactMap { stat -> GameSummary.GameStat? in
                guard let value = stat.displayValue, let label = stat.label ?? stat.name else { return nil }
                return GameSummary.GameStat(label: label, displayValue: value)
            }
            return GameSummary.TeamBox(
                id: id,
                name: info.displayName ?? "",
                abbreviation: info.abbreviation ?? "",
                stats: stats
            )
        }

        // The leaders tree nests differently per sport (team → category → athlete
        // or category → athlete), so walk it generically and keep the top entry
        // of each category per team.
        var leaders: [GameSummary.GameLeader] = []
        var seen: Set<String> = []
        func walk(_ nodes: [SummaryLeaderNodeDTO], category: String?, teamAbbreviation: String?) {
            for node in nodes {
                let abbreviation = node.team?.abbreviation ?? teamAbbreviation
                if let athlete = node.athlete, let value = node.displayValue,
                   let athleteName = athlete.displayName, let category {
                    let key = "\(category)|\(abbreviation ?? "")"
                    if seen.insert(key).inserted {
                        leaders.append(GameSummary.GameLeader(
                            id: "\(key)|\(athlete.id ?? athleteName)",
                            category: category,
                            athleteName: athleteName,
                            teamAbbreviation: abbreviation,
                            displayValue: value
                        ))
                    }
                }
                if let children = node.leaders, !children.isEmpty {
                    walk(children, category: node.displayName ?? node.name ?? category, teamAbbreviation: abbreviation)
                }
            }
        }
        walk(self.leaders ?? [], category: nil, teamAbbreviation: nil)

        return GameSummary(teams: teams, leaders: Array(leaders.prefix(8)))
    }
}

private struct BoxscoreDTO: Decodable {
    let teams: [BoxscoreTeamDTO]?
}

private struct BoxscoreTeamDTO: Decodable {
    let team: SummaryTeamInfoDTO?
    let statistics: [BoxscoreStatDTO]?
}

private struct SummaryTeamInfoDTO: Decodable {
    let id: String?
    let displayName: String?
    let abbreviation: String?
}

private struct BoxscoreStatDTO: Decodable {
    let name: String?
    let label: String?
    let displayValue: String?
}

private struct SummaryLeaderNodeDTO: Decodable {
    let name: String?
    let displayName: String?
    let displayValue: String?
    let team: SummaryTeamInfoDTO?
    let athlete: SummaryAthleteDTO?
    let leaders: [SummaryLeaderNodeDTO]?
}

private struct SummaryAthleteDTO: Decodable {
    let id: String?
    let displayName: String?
}

// MARK: - Standings DTOs

private struct StandingsRoot: Decodable {
    let name: String?
    let children: [StandingsNode]?
    let standings: StandingsTable?

    func collectGroups(into groups: inout [StandingsGroup]) {
        children?.forEach { $0.collectGroups(into: &groups) }
    }
}

private struct StandingsNode: Decodable {
    let id: String?
    let name: String?
    let children: [StandingsNode]?
    let standings: StandingsTable?

    func collectGroups(into groups: inout [StandingsGroup]) {
        if let table = standings, let group = table.toGroup(name: name ?? "Standings") {
            groups.append(group)
        }
        children?.forEach { $0.collectGroups(into: &groups) }
    }
}

private struct StandingsTable: Decodable {
    let entries: [StandingsEntry]?

    func toGroup(name: String) -> StandingsGroup? {
        let rows = (entries ?? []).compactMap { $0.toRow() }
        guard !rows.isEmpty else { return nil }
        return StandingsGroup(id: name, name: name, rows: rows)
    }
}

private struct StandingsEntry: Decodable {
    let team: StandingsTeam?
    let stats: [StandingsStat]?

    func toRow() -> StandingRow? {
        guard let team else { return nil }
        let byType = Dictionary(stats?.compactMap { stat -> (String, String)? in
            guard let key = (stat.type ?? stat.name)?.lowercased(), let value = stat.displayValue else { return nil }
            return (key, value)
        } ?? [], uniquingKeysWith: { first, _ in first })

        let wins = byType["wins"]
        let losses = byType["losses"]
        let record: String
        if let overall = byType["overall"] ?? byType["total"], overall.contains("-") {
            record = overall
        } else if let wins, let losses {
            record = "\(wins)-\(losses)"
        } else {
            record = byType["points"] ?? "—"
        }

        return StandingRow(
            teamID: team.id ?? team.uid ?? UUID().uuidString,
            displayName: team.displayName ?? team.name ?? "—",
            abbreviation: team.abbreviation ?? "",
            logoURL: team.logos?.first?.href.flatMap(URL.init(string:)),
            record: record,
            winPercent: byType["winpercent"],
            gamesBack: byType["gamesbehind"] ?? byType["gamesbehindnumber"],
            streak: byType["streak"],
            pointsFor: byType["pointsfor"] ?? byType["avgpointsfor"] ?? byType["pointspergame"],
            pointsAgainst: byType["pointsagainst"] ?? byType["avgpointsagainst"]
        )
    }
}

private struct StandingsTeam: Decodable {
    let id: String?
    let uid: String?
    let name: String?
    let displayName: String?
    let abbreviation: String?
    let logos: [PremiumLogo]?
}

private struct PremiumLogo: Decodable {
    let href: String?
}

private struct StandingsStat: Decodable {
    let name: String?
    let type: String?
    let displayValue: String?
}

// MARK: - Roster DTOs

private struct RosterResponse: Decodable {
    let athletes: [RosterElement]?

    func toGroups() -> [RosterGroup] {
        guard let athletes else { return [] }
        // Grouped shape (NFL etc.): each element has a `position` label + `items`.
        let grouped = athletes.compactMap { element -> RosterGroup? in
            guard let items = element.items, !items.isEmpty else { return nil }
            let players = items.compactMap { $0.toAthlete() }
            guard !players.isEmpty else { return nil }
            let title = element.position?.capitalized ?? "Players"
            return RosterGroup(id: title, title: title, athletes: players)
        }
        if !grouped.isEmpty { return grouped }

        // Flat shape (NBA etc.): elements are athletes themselves.
        let flat = athletes.compactMap { $0.toAthleteFromSelf() }
        guard !flat.isEmpty else { return [] }
        return [RosterGroup(id: "Roster", title: "Roster", athletes: flat)]
    }
}

/// A roster element that may be a position group (`position` + `items`) or an athlete itself.
private struct RosterElement: Decodable {
    let position: String?     // only when a group ("offense", "defense"...)
    let items: [RosterAthleteDTO]?

    // Athlete fields (present when the element IS the athlete).
    let id: String?
    let displayName: String?
    let jersey: String?
    let athletePosition: RosterPosition?
    let headshot: RosterHeadshot?
    let age: Int?
    let displayHeight: String?
    let displayWeight: String?
    let college: RosterCollege?
    let experience: RosterExperience?
    let birthPlace: RosterBirthPlace?
    let injuries: [RosterInjuryStub]?

    private enum CodingKeys: String, CodingKey {
        case position, items, id, displayName, jersey
        case headshot, age, displayHeight, displayWeight, college, experience, birthPlace, injuries
    }

    // `position` is a String for groups but an object for athletes — decode both from the one key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try c.decodeIfPresent([RosterAthleteDTO].self, forKey: .items)
        self.position = try? c.decodeIfPresent(String.self, forKey: .position)
        self.athletePosition = try? c.decodeIfPresent(RosterPosition.self, forKey: .position)
        self.id = try? c.decodeIfPresent(String.self, forKey: .id)
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        self.jersey = try c.decodeIfPresent(String.self, forKey: .jersey)
        self.headshot = try c.decodeIfPresent(RosterHeadshot.self, forKey: .headshot)
        self.age = try c.decodeIfPresent(Int.self, forKey: .age)
        self.displayHeight = try c.decodeIfPresent(String.self, forKey: .displayHeight)
        self.displayWeight = try c.decodeIfPresent(String.self, forKey: .displayWeight)
        self.college = try c.decodeIfPresent(RosterCollege.self, forKey: .college)
        self.experience = try c.decodeIfPresent(RosterExperience.self, forKey: .experience)
        self.birthPlace = try c.decodeIfPresent(RosterBirthPlace.self, forKey: .birthPlace)
        self.injuries = try c.decodeIfPresent([RosterInjuryStub].self, forKey: .injuries)
    }

    func toAthleteFromSelf() -> RosterAthlete? {
        guard let id, let displayName else { return nil }
        return RosterAthlete(
            id: id,
            displayName: displayName,
            jersey: jersey,
            position: athletePosition?.abbreviation,
            positionName: athletePosition?.displayName,
            headshotURL: headshot?.href.flatMap(URL.init(string:)),
            age: age,
            displayHeight: displayHeight,
            displayWeight: displayWeight,
            college: college?.name,
            experienceYears: experience?.years,
            birthPlace: birthPlace?.summary,
            isInjured: !(injuries ?? []).isEmpty
        )
    }
}

private struct RosterAthleteDTO: Decodable {
    let id: String?
    let displayName: String?
    let jersey: String?
    let position: RosterPosition?
    let headshot: RosterHeadshot?
    let age: Int?
    let displayHeight: String?
    let displayWeight: String?
    let college: RosterCollege?
    let experience: RosterExperience?
    let birthPlace: RosterBirthPlace?
    let injuries: [RosterInjuryStub]?

    func toAthlete() -> RosterAthlete? {
        guard let id, let displayName else { return nil }
        return RosterAthlete(
            id: id,
            displayName: displayName,
            jersey: jersey,
            position: position?.abbreviation,
            positionName: position?.displayName,
            headshotURL: headshot?.href.flatMap(URL.init(string:)),
            age: age,
            displayHeight: displayHeight,
            displayWeight: displayWeight,
            college: college?.name,
            experienceYears: experience?.years,
            birthPlace: birthPlace?.summary,
            isInjured: !(injuries ?? []).isEmpty
        )
    }
}

private struct RosterPosition: Decodable {
    let abbreviation: String?
    let displayName: String?
}

private struct RosterHeadshot: Decodable {
    let href: String?
}

private struct RosterCollege: Decodable {
    let name: String?
}

private struct RosterExperience: Decodable {
    let years: Int?
}

private struct RosterBirthPlace: Decodable {
    let city: String?
    let state: String?
    let country: String?

    var summary: String? {
        let parts = [city, state ?? country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private struct RosterInjuryStub: Decodable {
    let status: String?
}

// MARK: - Athlete overview DTOs

private struct AthleteOverviewResponse: Decodable {
    let statistics: OverviewStatistics?
    let news: [NowHeadlineDTO]?

    func toOverview(league: League) -> AthleteOverview {
        let (label, stats) = statistics?.toStatline() ?? ("Season", [])
        let headline = OverviewStatistics.headline(from: stats)
        let articles = (news ?? []).prefix(6).compactMap { $0.toArticle(league: league) }
        return AthleteOverview(statlineLabel: label, stats: stats, headlineStats: headline, news: Array(articles))
    }
}

private struct OverviewStatistics: Decodable {
    let labels: [String]?
    let displayNames: [String]?
    let names: [String]?
    let splits: [OverviewSplit]?

    func toStatline() -> (String, [StatValue]) {
        guard let split = splits?.first, let values = split.stats else { return ("Season", []) }
        let labels = labels ?? []
        let displayNames = displayNames ?? labels
        var stats: [StatValue] = []
        for (index, value) in values.enumerated() {
            let label = index < labels.count ? labels[index] : "—"
            let display = index < displayNames.count ? displayNames[index] : label
            stats.append(StatValue(label: label, displayName: display, value: value))
        }
        return (split.displayName ?? "Season", stats)
    }

    /// Picks the 3-4 most meaningful stats for a compact header.
    static func headline(from stats: [StatValue]) -> [StatValue] {
        let priority: Set<String> = ["PTS", "REB", "AST", "HR", "RBI", "AVG", "G", "A", "P",
                                     "YDS", "TD", "GP", "W", "ERA", "SO", "GOALS", "PPG"]
        let matched = stats.filter { priority.contains($0.label.uppercased()) }
        if matched.count >= 3 { return Array(matched.prefix(4)) }
        return Array(stats.suffix(4))
    }
}

private struct OverviewSplit: Decodable {
    let displayName: String?
    let stats: [String]?
}

// MARK: - Leaders (byathlete) DTOs

private struct ByAthleteResponse: Decodable {
    let categories: [ByAthleteCategory]?
    let athletes: [ByAthleteEntry]?

    /// Stats we surface as leader boards, in priority order, when present for the sport.
    private static let preferredStats = [
        "avgPoints", "avgRebounds", "avgAssists", "avgSteals", "avgBlocks",
        "goals", "assists", "points", "avgGoals",
        "passingYards", "passingTouchdowns", "rushingYards", "receivingYards", "receptions",
        "totalTackles", "sacks", "interceptions",
        "homeRuns", "RBIs", "battingAverage", "hits", "runs",
        "wins", "strikeouts", "ERA", "saves"
    ]

    func toBoards(league: League) -> [LeaderBoard] {
        guard let categories, let athletes else { return [] }

        // Map each stat key -> (categoryName, index within that category).
        var statLocation: [String: (String, Int)] = [:]
        var statDisplay: [String: String] = [:]
        for category in categories {
            guard let catName = category.name, let names = category.names else { continue }
            let displays = category.displayNames ?? names
            for (index, key) in names.enumerated() {
                statLocation[key] = (catName, index)
                statDisplay[key] = index < displays.count ? displays[index] : key
            }
        }

        var boards: [LeaderBoard] = []
        for statKey in Self.preferredStats where statLocation[statKey] != nil {
            guard let (catName, index) = statLocation[statKey] else { continue }
            var rows: [(Double, LeaderRow)] = []
            for entry in athletes {
                guard let athlete = entry.athlete,
                      let id = athlete.id,
                      let totals = entry.totals(forCategory: catName),
                      index < totals.count else { continue }
                let raw = totals[index]
                guard let numeric = Double(raw.replacingOccurrences(of: ",", with: "")) else { continue }
                let row = LeaderRow(
                    rank: 0,
                    athleteID: id,
                    displayName: athlete.displayName ?? "—",
                    teamAbbreviation: athlete.teamShortName,
                    headshotURL: ESPNService.headshotSlug(for: league).flatMap {
                        URL(string: "https://a.espncdn.com/i/headshots/\($0)/players/full/\(id).png")
                    },
                    value: raw
                )
                rows.append((numeric, row))
            }
            let sorted = rows.sorted { $0.0 > $1.0 }.prefix(10)
            guard sorted.count >= 3 else { continue }
            let ranked = sorted.enumerated().map { offset, pair in
                LeaderRow(rank: offset + 1, athleteID: pair.1.athleteID, displayName: pair.1.displayName,
                          teamAbbreviation: pair.1.teamAbbreviation, headshotURL: pair.1.headshotURL, value: pair.1.value)
            }
            boards.append(LeaderBoard(id: statKey, statName: statKey,
                                      displayName: statDisplay[statKey] ?? statKey, rows: ranked))
            if boards.count >= 6 { break }
        }
        return boards
    }
}

private struct ByAthleteCategory: Decodable {
    let name: String?
    let names: [String]?
    let displayNames: [String]?
}

private struct ByAthleteEntry: Decodable {
    let athlete: ByAthleteAthlete?
    let categories: [ByAthleteEntryCategory]?

    func totals(forCategory name: String) -> [String]? {
        categories?.first { $0.name == name }?.totals
    }
}

private struct ByAthleteEntryCategory: Decodable {
    let name: String?
    let totals: [String]?
}

private struct ByAthleteAthlete: Decodable {
    let id: String?
    let displayName: String?
    let teamShortName: String?
}

// MARK: - Injuries DTOs

private struct InjuriesResponse: Decodable {
    let injuries: [InjuryGroup]?

    func toInjuries() -> [LeagueInjury] {
        let all = (injuries ?? []).flatMap { group in
            (group.injuries ?? []).compactMap { $0.toInjury(teamName: group.displayName) }
        }
        // Most severe (out) first, then by athlete name.
        return all.sorted { lhs, rhs in
            if lhs.isOut != rhs.isOut { return lhs.isOut }
            return lhs.athleteName < rhs.athleteName
        }
    }
}

private struct InjuryGroup: Decodable {
    let displayName: String?
    let injuries: [InjuryItem]?
}

private struct InjuryItem: Decodable {
    let id: String?
    let status: String?
    let shortComment: String?
    let longComment: String?
    let athlete: InjuryAthlete?

    func toInjury(teamName: String?) -> LeagueInjury? {
        guard let athlete, let name = athlete.displayName else { return nil }
        return LeagueInjury(
            id: id ?? "\(name)-\(status ?? "")",
            athleteName: name,
            teamAbbreviation: teamName,
            position: athlete.position?.abbreviation,
            status: status ?? "Unknown",
            detail: shortComment ?? longComment,
            headshotURL: athlete.headshot?.href.flatMap(URL.init(string:))
        )
    }
}

private struct InjuryAthlete: Decodable {
    let displayName: String?
    let position: RosterPosition?
    let headshot: RosterHeadshot?
}

// MARK: - Now news DTOs

private struct NowNewsResponse: Decodable {
    let headlines: [NowHeadlineDTO]?
}

private struct NowHeadlineDTO: Decodable {
    let id: JSONValue?
    let headline: String?
    let description: String?
    let published: String?
    let byline: String?
    let type: String?
    let premium: Bool?
    let images: [NowImageDTO]?
    let links: NowLinksDTO?
    let categories: [NowCategoryDTO]?

    func toArticle(league: League) -> ESPNArticle? {
        guard let headline, !headline.isEmpty else { return nil }
        let tags = (categories ?? []).compactMap { $0.description ?? $0.type }
            .filter { !$0.isEmpty }
        return ESPNArticle(
            id: id?.stringValue ?? "\(league.id)-\(headline)",
            headline: headline,
            description: description ?? "",
            published: published.flatMap(NowHeadlineDTO.isoFormatter.date(from:)),
            url: (links?.web?.href ?? links?.mobile?.href).flatMap(URL.init(string:)),
            imageURL: images?.first?.url.flatMap(URL.init(string:)),
            league: league,
            byline: byline,
            type: type?.capitalized,
            isPremium: premium ?? false,
            categories: Array(Set(tags)).sorted()
        )
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private struct NowImageDTO: Decodable {
    let url: String?
}

private struct NowLinksDTO: Decodable {
    let web: NowLinkDTO?
    let mobile: NowLinkDTO?
}

private struct NowLinkDTO: Decodable {
    let href: String?
}

private struct NowCategoryDTO: Decodable {
    let type: String?
    let description: String?
}

/// Minimal JSON scalar so `id` decodes whether ESPN sends a number or string.
private enum JSONValue: Decodable {
    case string(String)
    case int(Int)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .other
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .other: return nil
        }
    }
}
