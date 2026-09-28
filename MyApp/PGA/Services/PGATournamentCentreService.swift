import Foundation

/// Coordinates every data need of the Golf Tournament Centre so Overview,
/// Leaderboard, Following, Course, and Tee Times tabs share one normalized
/// state and one set of in-flight requests instead of each polling
/// independently (STEP 81/106).
///
/// Stale-request protection (STEP 101): every load captures the tournament
/// (and, for player-scoped loads, player+round) it was issued for in a local
/// generation token and only commits its result if that token still matches
/// current state when the network call returns. A tournament/player switch
/// that lands after a newer one has already resolved is silently discarded.
@MainActor
@Observable
final class PGATournamentCentreService {
    private(set) var tournament: GolfTournament?
    private(set) var leaderboard: [GolfLeaderboardEntry] = []
    private(set) var currentLeaders: [GolfCurrentLeader] = []
    private(set) var teeTimes: GolfTeeTimes?
    private(set) var courses: [GolfCourse] = []
    private(set) var weather: GolfWeather?
    private(set) var fedExStandings: [GolfCupStanding] = []
    private(set) var coverage: [GolfCoverageWindow] = []

    private(set) var isLoadingTournament = false
    private(set) var isLoadingLeaderboard = false

    private(set) var tournamentError: String?
    private(set) var leaderboardError: String?
    private(set) var teeTimesError: String?
    private(set) var courseError: String?
    private(set) var weatherError: String?
    private(set) var fedExError: String?
    private(set) var coverageError: String?

    private(set) var lastTournamentUpdate: Date?
    private(set) var lastLeaderboardUpdate: Date?
    private(set) var lastTeeTimesUpdate: Date?
    private(set) var lastCourseUpdate: Date?
    private(set) var lastWeatherUpdate: Date?
    private(set) var lastFedExUpdate: Date?

    // Selected-player state (Player Tournament Detail)
    private(set) var selectedPlayerID: String?
    private(set) var selectedPlayerScorecard: GolfScorecard?
    private(set) var selectedPlayerShotsByRound: [Int: GolfShotRound] = [:]
    private(set) var isLoadingSelectedPlayer = false
    private(set) var selectedPlayerError: String?

    private var activeTournamentID: GolfTournamentID?
    private var activePlayerID: String?
    private var pollingTask: Task<Void, Never>?

    private let client: PGATourClient

    init(client: PGATourClient = .shared) {
        self.client = client
    }

    var isLeaderboardStale: Bool {
        guard tournament?.status.isLive == true, let last = lastLeaderboardUpdate else { return false }
        return Date().timeIntervalSince(last) > max(90, PGALiveRefreshCoordinator.leaderboardInterval(for: tournament?.status ?? .unknown("")) * 3)
    }

    // MARK: - Tournament lifecycle

    /// Loads (or switches to) a tournament and starts live polling appropriate
    /// to its status. Cancels any previous tournament's polling loop first.
    func open(tournamentID: GolfTournamentID) {
        guard activeTournamentID != tournamentID else { return }
        activeTournamentID = tournamentID
        pollingTask?.cancel()
        tournament = nil
        leaderboard = []
        currentLeaders = []
        teeTimes = nil
        courses = []
        weather = nil
        fedExStandings = []
        coverage = []
        selectedPlayerID = nil
        selectedPlayerScorecard = nil
        selectedPlayerShotsByRound = [:]

        pollingTask = Task { [weak self] in
            await self?.loadTournamentMetadata(tournamentID)
            await self?.pollLoop(tournamentID)
        }
    }

    func close() {
        pollingTask?.cancel()
        pollingTask = nil
        activeTournamentID = nil
    }

    private func pollLoop(_ tournamentID: GolfTournamentID) async {
        while !Task.isCancelled, activeTournamentID == tournamentID {
            await refreshLeaderboard(tournamentID)

            let now = Date()
            if now.timeIntervalSince(lastTeeTimesUpdate ?? .distantPast) > PGALiveRefreshCoordinator.teeTimesInterval {
                await refreshTeeTimes(tournamentID)
            }
            if now.timeIntervalSince(lastCourseUpdate ?? .distantPast) > PGALiveRefreshCoordinator.courseInterval {
                await refreshCourse(tournamentID)
            }
            if now.timeIntervalSince(lastWeatherUpdate ?? .distantPast) > PGALiveRefreshCoordinator.weatherInterval {
                await refreshWeather(tournamentID)
            }
            if now.timeIntervalSince(lastFedExUpdate ?? .distantPast) > PGALiveRefreshCoordinator.fedExInterval {
                await refreshFedEx()
            }

            let interval = PGALiveRefreshCoordinator.leaderboardInterval(for: tournament?.status ?? .unknown(""))
            guard interval.isFinite else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func loadTournamentMetadata(_ tournamentID: GolfTournamentID) async {
        isLoadingTournament = true
        defer { isLoadingTournament = false }
        do {
            let data = try await client.graphQL(
                operation: TournamentsQuery.operation.operationName,
                document: TournamentsQuery.operation.document,
                variables: .object(["ids": .array([.string(tournamentID.rawValue)])])
            )
            guard activeTournamentID == tournamentID else { return }
            let resolved = PGATournamentMapper.tournaments(data).first
            guard let resolved else {
                tournamentError = "Tournament not found."
                return
            }
            tournament = resolved
            courses = resolved.courses
            weather = resolved.weather
            lastTournamentUpdate = Date()
            tournamentError = nil
        } catch {
            guard activeTournamentID == tournamentID else { return }
            tournamentError = error.localizedDescription
        }
    }

    // MARK: - Leaderboard (primary live view)

    private func refreshLeaderboard(_ tournamentID: GolfTournamentID) async {
        isLoadingLeaderboard = leaderboard.isEmpty
        defer { isLoadingLeaderboard = false }
        do {
            let data = try await client.graphQL(
                operation: LeaderboardCompressedV3Query.operation.operationName,
                document: LeaderboardCompressedV3Query.operation.document,
                variables: .object(["leaderboardCompressedV3Id": .string(tournamentID.rawValue)])
            )
            guard activeTournamentID == tournamentID else { return }
            guard let payload = data["leaderboardCompressedV3"]["payload"].string else {
                leaderboardError = "No leaderboard data returned."
                return
            }
            let decoded = try PGAPayloadDecoder.decode(payload)
            guard activeTournamentID == tournamentID else { return }
            leaderboard = Self.merge(existing: leaderboard, incoming: PGALeaderboardMapper.leaderboard(decoded, tournamentID: tournamentID.rawValue))
            lastLeaderboardUpdate = Date()
            leaderboardError = nil
        } catch {
            // Cached leaderboard stays visible on failure (STEP 98) — never clear it here.
            guard activeTournamentID == tournamentID else { return }
            leaderboardError = error.localizedDescription
        }
    }

    /// Merge by playerID rather than replacing the array outright, so
    /// SwiftUI identity stays stable and unrelated rows don't visually jump
    /// (STEP 102/108).
    /// Internal (not `private`) so tests can exercise the merge rule directly.
    static func merge(existing: [GolfLeaderboardEntry], incoming: [GolfLeaderboardEntry]) -> [GolfLeaderboardEntry] {
        // An empty refresh is treated as a transient hiccup, not "the field is
        // now empty" — the cached leaderboard stays exactly as it was.
        guard !incoming.isEmpty else { return existing }
        // Rows present in the fresh response are authoritative and keep the
        // provider's own order (STEP 94). Any previously-known player who
        // didn't come back this cycle is kept (not silently dropped) rather
        // than assumed withdrawn.
        let incomingIDs = Set(incoming.map(\.id))
        let leftover = existing.filter { !incomingIDs.contains($0.id) }
        return incoming + leftover
    }

    func loadCurrentLeaders(tournamentID: GolfTournamentID) async {
        do {
            let data = try await client.graphQL(
                operation: CurrentLeadersCompressedQuery.operation.operationName,
                document: CurrentLeadersCompressedQuery.operation.document,
                variables: .object(["tournamentId": .string(tournamentID.rawValue)])
            )
            guard activeTournamentID == tournamentID, let payload = data["currentLeadersCompressed"]["payload"].string else { return }
            let decoded = try PGAPayloadDecoder.decode(payload)
            guard activeTournamentID == tournamentID else { return }
            currentLeaders = PGALeaderboardMapper.currentLeaders(decoded)
        } catch {
            // Overview quietly falls back to the full leaderboard's top rows.
        }
    }

    // MARK: - Tee times / course / weather / FedEx (independent failure domains)

    private func refreshTeeTimes(_ tournamentID: GolfTournamentID) async {
        do {
            let data = try await client.graphQL(
                operation: TeeTimesCompressedV2Query.operation.operationName,
                document: TeeTimesCompressedV2Query.operation.document,
                variables: .object(["teeTimesCompressedV2Id": .string(tournamentID.rawValue)])
            )
            guard activeTournamentID == tournamentID, let payload = data["teeTimesCompressedV2"]["payload"].string else { return }
            let decoded = try PGAPayloadDecoder.decode(payload)
            guard activeTournamentID == tournamentID else { return }
            teeTimes = PGATeeTimesMapper.teeTimes(decoded, tournamentID: tournamentID.rawValue)
            lastTeeTimesUpdate = Date()
            teeTimesError = nil
        } catch {
            guard activeTournamentID == tournamentID else { return }
            teeTimesError = error.localizedDescription
        }
    }

    private func refreshCourse(_ tournamentID: GolfTournamentID) async {
        do {
            let data = try await client.graphQL(
                operation: CourseStatsQuery.operation.operationName,
                document: CourseStatsQuery.operation.document,
                variables: .object(["tournamentId": .string(tournamentID.rawValue)])
            )
            guard activeTournamentID == tournamentID else { return }
            let mapped = PGACourseMapper.courses(data["courseStats"])
            guard !mapped.isEmpty else { return }
            courses = mapped
            lastCourseUpdate = Date()
            courseError = nil
        } catch {
            guard activeTournamentID == tournamentID else { return }
            // Course tab still shows the basic metadata already captured from Tournaments.
            courseError = error.localizedDescription
        }
    }

    private func refreshWeather(_ tournamentID: GolfTournamentID) async {
        do {
            let data = try await client.graphQL(
                operation: WeatherQuery.operation.operationName,
                document: WeatherQuery.operation.document,
                variables: .object(["tournamentId": .string(tournamentID.rawValue)])
            )
            guard activeTournamentID == tournamentID else { return }
            weather = PGAWeatherMapper.forecast(data["weather"], current: weather?.current)
            lastWeatherUpdate = Date()
            weatherError = nil
        } catch {
            guard activeTournamentID == tournamentID else { return }
            // Weather UI simply hides itself on failure (STEP 98); the header keeps its last-known reading.
            weatherError = error.localizedDescription
        }
    }

    private func refreshFedEx() async {
        guard let year = tournament?.seasonYear else { return }
        let tournamentID = activeTournamentID
        do {
            let data = try await client.graphQL(
                operation: TourCupSplitQuery.operation.operationName,
                document: TourCupSplitQuery.operation.document,
                variables: .object(["tourCode": .string("R"), "id": .string(PGAStatIdentifier.fedExCup), "year": .number(Double(year))])
            )
            guard activeTournamentID == tournamentID else { return }
            fedExStandings = PGAFedExMapper.standings(data["tourCupSplit"])
            lastFedExUpdate = Date()
            fedExError = nil
        } catch {
            guard activeTournamentID == tournamentID else { return }
            fedExError = error.localizedDescription
        }
    }

    func loadCoverage(tournamentID: GolfTournamentID) async {
        do {
            let data = try await client.graphQL(
                operation: CoverageQuery.operation.operationName,
                document: CoverageQuery.operation.document,
                variables: .object(["tournamentId": .string(tournamentID.rawValue)])
            )
            guard activeTournamentID == tournamentID else { return }
            coverage = PGACoverageMapper.windows(data["coverage"])
            coverageError = nil
        } catch {
            guard activeTournamentID == tournamentID else { return }
            coverageError = error.localizedDescription
        }
    }

    // MARK: - Selected player (Scorecard / Shots)

    func selectPlayer(_ playerID: String) {
        guard let tournamentID = activeTournamentID else { return }
        activePlayerID = playerID
        selectedPlayerID = playerID
        selectedPlayerScorecard = nil
        selectedPlayerShotsByRound = [:]
        selectedPlayerError = nil
        Task { [weak self] in await self?.loadScorecard(tournamentID: tournamentID, playerID: playerID) }
    }

    func deselectPlayer() {
        activePlayerID = nil
        selectedPlayerID = nil
        selectedPlayerScorecard = nil
        selectedPlayerShotsByRound = [:]
    }

    private func loadScorecard(tournamentID: GolfTournamentID, playerID: String) async {
        isLoadingSelectedPlayer = true
        defer { isLoadingSelectedPlayer = false }
        do {
            let data = try await client.graphQL(
                operation: ScorecardCompressedV3Query.operation.operationName,
                document: ScorecardCompressedV3Query.operation.document,
                variables: .object(["tournamentId": .string(tournamentID.rawValue), "playerId": .string(playerID)])
            )
            guard activePlayerID == playerID, activeTournamentID == tournamentID else { return }
            guard let payload = data["scorecardCompressedV3"]["payload"].string else {
                selectedPlayerError = "No scorecard available."
                return
            }
            let decoded = try PGAPayloadDecoder.decode(payload)
            guard activePlayerID == playerID, activeTournamentID == tournamentID else { return }
            selectedPlayerScorecard = PGAScorecardMapper.scorecard(decoded, tournamentID: tournamentID.rawValue, playerID: playerID)
            selectedPlayerError = nil
        } catch {
            guard activePlayerID == playerID, activeTournamentID == tournamentID else { return }
            selectedPlayerError = error.localizedDescription
        }
    }

    /// Shot data is heavy — only ever fetched for the selected player's
    /// currently-viewed round (STEP 75), never speculatively for the field.
    func loadShots(round: Int, includeRadar: Bool = false) {
        guard let tournamentID = activeTournamentID, let playerID = activePlayerID else { return }
        Task { [weak self] in await self?.fetchShots(tournamentID: tournamentID, playerID: playerID, round: round, includeRadar: includeRadar) }
    }

    private func fetchShots(tournamentID: GolfTournamentID, playerID: String, round: Int, includeRadar: Bool) async {
        do {
            let data = try await client.graphQL(
                operation: ShotDetailsV4CompressedQuery.operation.operationName,
                document: ShotDetailsV4CompressedQuery.operation.document,
                variables: .object([
                    "tournamentId": .string(tournamentID.rawValue),
                    "playerId": .string(playerID),
                    "round": .number(Double(round)),
                    "includeRadar": .bool(includeRadar)
                ])
            )
            guard activePlayerID == playerID, activeTournamentID == tournamentID else { return }
            guard let payload = data["shotDetailsV4Compressed"]["payload"].string else { return }
            let decoded = try PGAPayloadDecoder.decode(payload)
            guard activePlayerID == playerID, activeTournamentID == tournamentID else { return }
            selectedPlayerShotsByRound[round] = PGAShotMapper.shotRound(decoded, tournamentID: tournamentID.rawValue, playerID: playerID, round: round)
        } catch {
            // Shot-detail failure never disturbs the scorecard that's already showing (STEP 98).
        }
    }
}
