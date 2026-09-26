import Foundation

nonisolated struct SportsLiveMatchSnapshot: Sendable {
    let live: [Match]
    let startingSoon: [Match]
    let next: [Match]
    let failures: [String]
    let pastStartToday: [Match]
}
nonisolated struct SportsRepository: Sendable {
    static let shared = SportsRepository()
    private let providers: [String: any NativeSportsProvider]
    init(providers: [any NativeSportsProvider] = [NHLProvider(), MLBProvider(), F1Provider(), NFLProvider(), CFLProvider(), NBAProvider(), WNBAProvider(), EPLProvider(), MLSProvider(), LaLigaProvider()]) {
        self.providers = Dictionary(providers.map { ($0.leaguePath, $0) }, uniquingKeysWith: { _, new in new })
    }
    private func provider(_ league: League, _ capability: SportsDataCapability) throws -> any NativeSportsProvider {
        guard let provider = providers[league.path] else { throw SportsDataError.noProviderAvailable(capability, league.name) }
        return provider
    }
    func legacyScoreboard(for league: League, on date: Date? = nil) async throws -> [Match] {
        try await provider(league, .liveScores).scores(on: date)
    }
    func legacyScoreboards(for league: League, starting start: Date, days: Int) async throws -> [Match] {
        try await provider(league, .schedule).schedule(start: start, days: days)
    }
    func legacyTeams(for league: League) async throws -> [Team] { try await provider(league, .teams).teams() }
    func legacyStandings(for league: League) async throws -> [StandingsGroup] { try await provider(league, .standings).standings() }
    func legacyRoster(for league: League, teamID: String) async throws -> [RosterGroup] { try await provider(league, .rosters).roster(teamID: teamID) }
    func legacyAthleteOverview(for league: League, athleteID: String) async throws -> AthleteOverview { try await provider(league, .players).playerOverview(id: athleteID) }
    func liveMatchSnapshot(leagues: [League], startingSoonWindow: TimeInterval, nextLimit: Int,
                           onPartialResult: (@Sendable (SportsLiveMatchSnapshot) -> Void)? = nil) async -> SportsLiveMatchSnapshot {
        var matches: [Match] = [], failures: [String] = []
        await withTaskGroup(of: ([Match], String?).self) { group in
            for league in leagues where providers[league.path] != nil {
                group.addTask {
                    do { return (try await legacyScoreboard(for: league), nil) }
                    catch { return ([], "\(league.shortName): \(error.localizedDescription)") }
                }
            }
            for await (loaded, failure) in group {
                matches += loaded
                if let failure { failures.append(failure) }
                onPartialResult?(Self.snapshot(loaded, window: startingSoonWindow, limit: nextLimit, failures: failure.map { [$0] } ?? []))
            }
        }
        return Self.snapshot(matches, window: startingSoonWindow, limit: nextLimit, failures: failures)
    }
    private static func snapshot(_ matches: [Match], window: TimeInterval, limit: Int, failures: [String]) -> SportsLiveMatchSnapshot {
        let now = Date()
        let upcoming = matches.filter { $0.state == .pre && $0.date >= now }.sorted { $0.date < $1.date }
        return SportsLiveMatchSnapshot(live: matches.filter { $0.state == .live },
                                       startingSoon: upcoming.filter { $0.date.timeIntervalSince(now) <= window },
                                       next: Array(upcoming.prefix(max(0, limit))), failures: failures,
                                       pastStartToday: matches.filter { $0.state == .pre && $0.date < now && Calendar.current.isDateInToday($0.date) })
    }
    func enrichedLegacyMatch(_ match: Match) async -> Match {
        if match.league.path == "baseball/mlb", let id = Int(match.id),
           let feed = try? await MLBAPIClient.shared.liveFeed(gamePk: id), feed.gamePk == id,
           let game = MLBGameMapper.feed(feed) {
            return await MLBLegacyMapper.match(game, line: MLBGameMapper.line(feed.live["linescore"], players: MLBGameMapper.players(feed.data["players"])))
        }
        if match.league.path == "basketball/nba", let id = BasketballGameID.validated(match.id, league: .nba),
           let response = try? await NBAAPIClient.shared.boxScore(gameID: id.providerID), response.gameID == id.providerID,
           let game = NBAGameMapper.boxScore(response) {
            return await BasketballLegacyMapper.match(game, config: .nba)
        }
        guard match.league.path == "hockey/nhl", let id = Int(match.id),
              let dto = try? await NHLAPIClient.shared.landing(gameID: id), dto.id == id,
              let game = NHLGameMapper.game(dto) else { return match }
        return NHLGameMapper.match(game, league: match.league)
    }
    func legacyGameSummary(for match: Match) async throws -> GameSummary {
        guard match.league.path == "hockey/nhl", let id = Int(match.id) else { throw SportsDataError.unsupportedCapability(.gameDetails) }
        let update = try await NHLGameCenterService().fetch(gameID: id)
        let snapshot = NHLGameCenterReducer.apply(update, to: HockeyGameCenterSnapshot(gameID: id))
        guard snapshot.game != nil else { throw SportsDataError.unavailable }
        let teams = [snapshot.game?.away, snapshot.game?.home].compactMap { $0 }.map { team in
            GameSummary.TeamBox(id: String(team.id), name: team.name, abbreviation: team.abbreviation,
                                stats: team.shots.map { [GameSummary.GameStat(label: "Shots on goal", displayValue: String($0))] } ?? [])
        }
        let plays = snapshot.events.map {
            PlayByPlayEntry(id: $0.id, clock: $0.timeInPeriod, period: $0.period.label, periodNumber: $0.period.number,
                            text: [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: " • "), teamAbbreviation: nil,
                            awayScore: $0.awayScore.map(String.init), homeScore: $0.homeScore.map(String.init), isScoringPlay: $0.eventType == .goal)
        }
        let highlights = snapshot.events.compactMap { event -> MatchHighlight? in
            guard let url = event.videoURL else { return nil }
            return MatchHighlight(id: event.id, title: event.title, thumbnailURL: event.primaryPlayer?.headshot, webURL: url, duration: nil)
        }
        return GameSummary(teams: teams, leaders: [], plays: plays, headToHead: nil, highlights: highlights)
    }
    // Capabilities without a configured source fail explicitly. They never contact
    // another sport's endpoint or report a successful empty mock response.
    func legacyLeaders(for league: League) async throws -> [LeaderBoard] { throw SportsDataError.noProviderAvailable(.leagueLeaders, league.name) }
    func legacyInjuries(for league: League) async throws -> [LeagueInjury] {
        if let nfl = providers[league.path] as? NFLProvider { return try await nfl.injuries() }
        throw SportsDataError.noProviderAvailable(.injuries, league.name)
    }
    func legacyRacers(for league: League) async throws -> [Racer] {
        if league.path == "racing/f1", let f1 = providers[league.path] as? F1Provider { return try await f1.racers() }
        throw SportsDataError.noProviderAvailable(.players, league.name)
    }
    func golfTournament(for league: League, gameID: BannerEntityID) async throws -> BannerGolfTournament { throw SportsDataError.noProviderAvailable(.golfTournament, league.name) }
    func legacyArticleBody(from url: URL) async throws -> [String] { throw SportsDataError.unsupportedCapability(.newsMetadata) }
    func playerStats(for league: League, playerIDs: Set<BannerEntityID>, range: SportsDateRange?) async throws -> [BannerPlayerStat] {
        var output: [BannerPlayerStat] = []
        for id in playerIDs {
            let provider: SportsDataProviderID = league.path == "football/nfl" ? .nfl : league.path == "football/cfl" ? .cfl : league.path == "racing/f1" ? .f1 : league.path == "baseball/mlb" ? .mlb : league.path == "basketball/nba" ? .nba : league.path == "basketball/wnba" ? .wnba : .nhl
            guard let rawID = SportsIdentityResolver.providerID(from: id, provider: provider) else { throw SportsDataError.invalidResponse }
            let overview = try await legacyAthleteOverview(for: league, athleteID: rawID)
            output.append(BannerPlayerStat(id: id, playerID: id, playerDisplayName: nil, teamAbbreviation: nil, headshotURL: nil,
                                           teamID: nil, seasonID: nil, stats: overview.stats.map { BannerStatValue(key: $0.label, displayName: $0.displayName, value: $0.value) },
                                           provenance: DataProvenance(provider: provider, fetchedAt: Date(), providerEntityID: rawID, confidence: 1)))
        }
        return output
    }
    func legacyNews(for league: League, limit: Int = 10, page: Int = 1) async throws -> [ESPNArticle] {
        let providers: [any SportsNewsProvider] = [BBCSportNewsProvider(), CBSRSSNewsProvider(), NBCSportsNewsProvider(), SkySportsNewsProvider(), FOXRSSNewsProvider()]
        var articles: [BannerNewsArticle] = []
        await withTaskGroup(of: [BannerNewsArticle].self) { group in
            for provider in providers where provider.metadata.isEnabled {
                group.addTask { (try? await provider.newsMetadata(for: league, limit: limit, page: page)) ?? [] }
            }
            for await result in group { articles += result }
        }
        return Array(BannerNewsDeduplicator.deduplicate(articles).prefix(limit)).map { $0.toLegacyArticle(league: league) }
    }
    func prefetchNews(for leagues: [League]) async {
        for league in leagues { _ = try? await legacyNews(for: league) }
    }
}
