import Foundation

/// The app-shell-facing PGA TOUR provider. Conforms to the same
/// `NativeSportsProvider` interface every other native sport uses (so PGA
/// tournaments can appear in Home/Live/Following like any other league) and
/// to `GolfTournamentProvider` (so the existing generic `GolfGameCentre`
/// fallback UI has real data instead of an always-throwing stub).
///
/// The primary, purpose-built experience is `PGATournamentCentreView`, wired
/// directly into `MatchDetailView` for `league.path == "golf/pga"` — this
/// provider's `golfTournament(for:gameID:)` exists for the generic fallback
/// path only (STEP 59-60 of the Golf Tournament Centre spec).
actor PGAProvider: NativeSportsProvider, GolfTournamentProvider {
    nonisolated let leaguePath = "golf/pga"

    nonisolated var metadata: SportsDataProviderMetadata {
        SportsDataProviderMetadata(
            id: .pga,
            name: "PGA TOUR",
            supportLevel: .undocumented,
            supportedSports: [.golf],
            supportedLeagues: ["golf/pga"],
            capabilities: [.golfTournament, .schedule, .liveScores, .standings],
            authenticationType: .apiKey,
            isEnabled: true,
            requestTimeout: 30
        )
    }

    private let client: PGATourClient
    private let schedule: PGAScheduleService

    init(client: PGATourClient = .shared, schedule: PGAScheduleService = .shared) {
        self.client = client
        self.schedule = schedule
    }

    // MARK: - NativeSportsProvider

    /// Surfaces this week's featured PGA TOUR event(s) so a golf card can
    /// appear in Home/Live like any other league. Full multi-week schedule
    /// browsing lives in the Tournament Centre itself, not this generic path.
    func scores(on date: Date?) async throws -> [Match] {
        guard Calendar.current.isDateInToday(date ?? Date()) || date == nil else { return [] }
        let ids = try await schedule.currentTournamentIDs()
        guard !ids.isEmpty else { return [] }
        let data = try await client.graphQL(
            operation: TournamentsQuery.operation.operationName,
            document: TournamentsQuery.operation.document,
            variables: .object(["ids": .array(ids.map { .string($0.rawValue) })])
        )
        let tournaments = PGATournamentMapper.tournaments(data)
        return await MainActor.run { tournaments.map(Self.match) }
    }

    /// This generic interface only ever answers for "current" events — see
    /// the doc comment above. A range that doesn't include today returns
    /// empty rather than guessing from unparsed display-date strings.
    func schedule(start: Date, days: Int) async throws -> [Match] {
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: start) ?? start
        guard (start...end).contains(Date()) || Calendar.current.isDateInToday(start) else { return [] }
        return try await scores(on: Date())
    }

    func teams() async throws -> [Team] { [] }

    /// FedExCup standings, presented through the app's generic standings UI.
    func standings() async throws -> [StandingsGroup] {
        let currentYear = Calendar.current.component(.year, from: Date())
        let data = try await client.graphQL(
            operation: TourCupSplitQuery.operation.operationName,
            document: TourCupSplitQuery.operation.document,
            variables: .object(["tourCode": .string("R"), "id": .string(PGAStatIdentifier.fedExCup), "year": .number(Double(currentYear))])
        )
        let standings = PGAFedExMapper.standings(data["tourCupSplit"])
        let rows = standings.map { standing -> StandingRow in
            StandingRow(
                teamID: standing.playerID,
                displayName: standing.displayName,
                abbreviation: standing.country ?? standing.displayName,
                logoURL: nil,
                record: standing.officialPointsDisplay.map { "\($0) pts" } ?? "–",
                wins: nil, losses: nil, ties: nil, winPercent: nil, gamesBack: nil, streak: nil,
                pointsFor: nil, pointsAgainst: nil,
                leaguePoints: standing.officialPointsDisplay,
                gamesPlayed: nil, goalDiff: nil,
                leagueRank: standing.officialRankDisplay
            )
        }
        return [StandingsGroup(id: "pga-fedexcup", name: "FedExCup Standings", rows: rows)]
    }

    func roster(teamID: String) async throws -> [RosterGroup] {
        // Golf has no team roster concept; individual golfers are reached
        // through the Tournament Centre's field/leaderboard instead.
        throw PGATourError.invalidResponse
    }

    func playerOverview(id: String) async throws -> AthleteOverview {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { throw PGATourError.invalidResponse }
        let ids = try await schedule.currentTournamentIDs()
        for tournamentID in ids {
            let data = try await client.graphQL(
                operation: LeaderboardCompressedV3Query.operation.operationName,
                document: LeaderboardCompressedV3Query.operation.document,
                variables: .object(["leaderboardCompressedV3Id": .string(tournamentID.rawValue)])
            )
            guard let payload = data["leaderboardCompressedV3"]["payload"].string,
                  let decoded = try? PGAPayloadDecoder.decode(payload) else { continue }
            let entries = PGALeaderboardMapper.leaderboard(decoded, tournamentID: tournamentID.rawValue)
            guard let entry = entries.first(where: { $0.player.id == id }) else { continue }
            let stats: [StatValue] = [
                StatValue(label: "position", displayName: "Position", value: entry.positionDisplay ?? "-"),
                StatValue(label: "total", displayName: "Total", value: entry.total.display),
                StatValue(label: "thru", displayName: "Thru", value: entry.thruDisplay ?? "-")
            ]
            return AthleteOverview(statlineLabel: "This Week", stats: stats, headlineStats: stats, news: [])
        }
        throw PGATourError.invalidResponse
    }

    @MainActor private static func match(_ tournament: GolfTournament) -> Match {
        let league = League(name: "PGA Tour", shortName: "PGA", path: "golf/pga", group: .golf, keywords: ["pga", "golf", "tour"])
        let side = TeamSide(
            displayName: tournament.hostCourse?.name ?? tournament.name,
            shortName: "PGA",
            abbreviation: "PGA",
            logoURL: tournament.logoURL,
            score: nil,
            record: nil,
            isWinner: false
        )
        let state: GameState = tournament.status.isLive ? .live : (tournament.status == .tournamentComplete || tournament.status == .roundComplete ? .final : .pre)
        var match = Match(
            id: tournament.id,
            league: league,
            date: Date(),
            name: tournament.name,
            shortName: tournament.name,
            state: state,
            statusDetail: tournament.roundStatusDisplay ?? tournament.status.displayLabel,
            home: side,
            away: side,
            broadcasts: [],
            venue: tournament.hostCourse?.name
        )
        match.canonicalID = "game:\(league.bannerKey):pga:\(tournament.id)"
        return match
    }

    // MARK: - GolfTournamentProvider (generic fallback bridge — STEP 59-60)

    func golfTournament(for league: League, gameID: BannerEntityID) async throws -> BannerGolfTournament {
        let tournamentID = GolfTournamentID(rawValue: gameID.rawValue)
        async let tournamentData = client.graphQL(
            operation: TournamentsQuery.operation.operationName,
            document: TournamentsQuery.operation.document,
            variables: .object(["ids": .array([.string(tournamentID.rawValue)])])
        )
        async let leaderboardData = client.graphQL(
            operation: LeaderboardCompressedV3Query.operation.operationName,
            document: LeaderboardCompressedV3Query.operation.document,
            variables: .object(["leaderboardCompressedV3Id": .string(tournamentID.rawValue)])
        )
        let (tData, lData) = try await (tournamentData, leaderboardData)
        guard let tournament = PGATournamentMapper.tournaments(tData).first else {
            throw SportsDataError.noProviderAvailable(.golfTournament, league.name)
        }
        var leaderboard: [GolfLeaderboardEntry] = []
        if let payload = lData["leaderboardCompressedV3"]["payload"].string, let decoded = try? PGAPayloadDecoder.decode(payload) {
            leaderboard = PGALeaderboardMapper.leaderboard(decoded, tournamentID: tournamentID.rawValue)
        }
        return PGABannerGolfBridge.tournament(tournament, leaderboard: leaderboard, league: league)
    }
}
