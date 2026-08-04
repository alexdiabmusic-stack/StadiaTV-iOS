import Foundation

// MARK: - Advanced sport/team podcast matching via PodcastIndex API

actor PodcastMatcher {
    static let shared = PodcastMatcher()
    private let api = PodcastIndexService.shared

    // MARK: - Sport queries

    /// Returns up to `max` podcasts ranked for the given sport group.
    func findPodcasts(for sport: SportGroup, max: Int = 20) async -> [Podcast] {
        let queries = sportSearchQueries(for: sport)
        var scored: [String: (PIFeed, Int)] = [:]

        for query in queries.prefix(3) {
            let results = (try? await api.searchPodcasts(query: query, max: 30)) ?? []
            for feed in results {
                let s = scoreFeed(feed, for: sport)
                guard s > 0 else { continue }
                let key = feed.url.absoluteString
                if (scored[key]?.1 ?? -1) < s { scored[key] = (feed, s) }
            }
        }

        return scored.values
            .sorted { $0.1 > $1.1 }
            .prefix(max)
            .map { $0.0.toPodcast(sport: sport.rawValue) }
    }

    // MARK: - Team queries

    /// Returns up to `max` podcasts ranked for the given team.
    func findPodcasts(for team: FavoriteTeam, max: Int = 8) async -> [Podcast] {
        let queries = teamSearchQueries(for: team)
        var scored: [String: (PIFeed, Int)] = [:]

        for query in queries.prefix(5) {
            let results = (try? await api.searchPodcasts(query: query, max: 25)) ?? []
            for feed in results {
                let s = scoreFeed(feed, for: team)
                guard s >= 40 else { continue }  // minimum threshold
                let key = feed.url.absoluteString
                if (scored[key]?.1 ?? -1) < s { scored[key] = (feed, s) }
            }
        }

        return scored.values
            .sorted { $0.1 > $1.1 }
            .prefix(max)
            .map { $0.0.toPodcast() }
    }

    // MARK: - Search query generation

    private func sportSearchQueries(for sport: SportGroup) -> [String] {
        switch sport {
        case .football:
            return ["NFL football podcast", "American football analysis podcast", "NFL news weekly"]
        case .basketball:
            return ["NBA basketball podcast", "NBA analysis news daily", "basketball podcast"]
        case .hockey:
            return ["NHL hockey podcast", "NHL analysis hockey news", "hockey podcast"]
        case .baseball:
            return ["MLB baseball podcast", "MLB baseball analysis daily", "baseball podcast"]
        case .soccer:
            return ["soccer podcast Premier League MLS", "football soccer analysis podcast", "MLS soccer news podcast"]
        case .golf:
            return ["golf PGA Tour podcast", "PGA golf analysis podcast", "golf podcast weekly"]
        case .racing:
            return ["Formula 1 F1 podcast", "NASCAR racing podcast", "motorsport F1 analysis"]
        case .tennis:
            return ["tennis ATP WTA podcast", "tennis analysis grand slam", "tennis podcast weekly"]
        case .cycling, .wrestling, .esports:
            return []
        }
    }

    private func teamSearchQueries(for team: FavoriteTeam) -> [String] {
        let parts = team.displayName.split(separator: " ").map(String.init)
        let city = parts.dropLast().joined(separator: " ")
        let nickname = parts.last ?? ""
        let league = team.leaguePath.components(separatedBy: "/").last?.uppercased() ?? ""

        return [
            "Locked On \(team.displayName)",
            "\(team.displayName) podcast",
            "\(city) \(nickname) \(league) podcast",
            "\(team.abbreviation) \(league) analysis",
            "\(nickname) \(league) podcast"
        ].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Scoring: sport

    private func scoreFeed(_ feed: PIFeed, for sport: SportGroup) -> Int {
        var score = 0
        let title = feed.title.lowercased()
        let author = feed.author?.lowercased() ?? ""
        let desc = feed.description?.lowercased() ?? ""
        let combined = "\(title) \(author) \(desc)"

        let (primary, secondary) = sportKeywords(for: sport)
        for kw in primary where combined.contains(kw) { score += 30 }
        for kw in secondary where combined.contains(kw) { score += 10 }

        for pub in trustedPublishers where author.contains(pub) { score += 20 }

        // Penalise clearly off-topic or spam signals
        if combined.contains("crypto") || combined.contains("betting tips") { score -= 40 }

        return score
    }

    // MARK: - Scoring: team

    private func scoreFeed(_ feed: PIFeed, for team: FavoriteTeam) -> Int {
        var score = 0
        let parts = team.displayName.split(separator: " ").map { $0.lowercased() }
        let city = parts.dropLast().joined(separator: " ")
        let nickname = parts.last ?? ""
        let abbr = team.abbreviation.lowercased()
        let league = team.leaguePath.components(separatedBy: "/").last?.uppercased() ?? ""
        let leagueLower = league.lowercased()
        let fullNameLower = team.displayName.lowercased()

        let title = feed.title.lowercased()
        let author = feed.author?.lowercased() ?? ""
        let combined = "\(title) \(author)"

        // Locked On pattern is the most reliable signal
        if title.contains("locked on \(nickname)") || title.contains("locked on \(fullNameLower)") {
            score += 120
        }

        // Full team name in title
        if title.contains(fullNameLower) {
            score += 100
        } else if title.contains(nickname) && (title.contains(city) || title.contains(leagueLower) || title.contains(abbr)) {
            score += 85
        } else if title.contains(nickname) {
            score += 50
        } else if title.contains(city) && title.contains(leagueLower) {
            score += 60
        } else if title.contains(abbr) && title.contains(leagueLower) {
            score += 40
        }

        // Author matches team name or is the official team account
        if author.contains(fullNameLower) || author.contains(nickname) { score += 50 }

        // League relevance in content
        if combined.contains(leagueLower) { score += 15 }

        // Trusted sports network
        for pub in trustedPublishers where author.contains(pub) { score += 15 }

        return score
    }

    // MARK: - Data tables

    private func sportKeywords(for sport: SportGroup) -> ([String], [String]) {
        switch sport {
        case .football:
            return (["nfl", "american football", "quarterback", "touchdown"],
                    ["gridiron", "super bowl", "college football", "fantasy football"])
        case .basketball:
            return (["nba", "basketball", "hoops"],
                    ["ncaa basketball", "nba draft", "slam dunk"])
        case .hockey:
            return (["nhl", "hockey", "stanley cup"],
                    ["puck", "goalie", "power play", "icing"])
        case .baseball:
            return (["mlb", "baseball"],
                    ["world series", "home run", "batting", "pitcher", "bullpen"])
        case .soccer:
            return (["soccer", "premier league", "mls", "champions league"],
                    ["epl", "bundesliga", "la liga", "serie a", "world cup"])
        case .golf:
            return (["golf", "pga", "pga tour"],
                    ["masters", "lpga", "birdie", "fairway", "open championship"])
        case .racing:
            return (["formula 1", "f1", "nascar", "motorsport"],
                    ["indycar", "motogp", "grand prix", "verstappen"])
        case .tennis:
            return (["tennis", "atp", "wta"],
                    ["wimbledon", "us open tennis", "french open", "grand slam"])
        case .cycling, .wrestling, .esports:
            return ([], [])
        }
    }

    private let trustedPublishers: Set<String> = [
        "nfl", "nba", "mlb", "nhl", "mls",
        "espn", "the athletic", "barstool sports", "the ringer",
        "cbs sports", "nbc sports", "fox sports", "bleacher report",
        "locked on podcast network", "blue wire", "audacy",
        "iheart", "podcast one", "si media"
    ]
}
