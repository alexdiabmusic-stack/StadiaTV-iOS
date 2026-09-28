import Foundation

/// Season schedule + current/default tournament discovery. Cached in memory
/// since the season list barely changes intra-day and current-tournament
/// discovery only needs to run a few times per session.
actor PGAScheduleService {
    static let shared = PGAScheduleService()

    private let client: PGATourClient
    private var scheduleCache: [String: (Date, GolfSeasonSchedule)] = [:]
    private var currentTournamentCache: (Date, [GolfTournamentID])?

    init(client: PGATourClient = .shared) {
        self.client = client
    }

    func schedule(tour: PGATourCode = .pgaTour, year: Int) async throws -> GolfSeasonSchedule {
        let key = "\(tour.rawValue)-\(year)"
        if let (time, value) = scheduleCache[key], Date().timeIntervalSince(time) < 12 * 3600 {
            return value
        }
        let raw = try await client.rest(path: "schedule/\(tour.rawValue)/\(year)")
        let schedule = PGAScheduleMapper.season(raw, tour: tour.rawValue, year: year)
        scheduleCache[key] = (Date(), schedule)
        return schedule
    }

    /// Discovers the tour's current/featured tournament(s) via
    /// `orchestrator-config.pgatour.com/web-config`'s `defaultTournaments`.
    /// Returns a *list* deliberately — some weeks run an opposite-field or
    /// alternate event alongside (or instead of) the marquee event, so
    /// callers must never assume exactly one result (STEP 4).
    func currentTournamentIDs(tour: PGATourCode = .pgaTour) async throws -> [GolfTournamentID] {
        if let (time, value) = currentTournamentCache, Date().timeIntervalSince(time) < 900 {
            return value
        }
        let raw = try await client.config(path: "web-config")
        let defaults = raw["defaultTournaments"][tour.rawValue].array
        let ids = defaults.compactMap { $0["id"].string }.map { GolfTournamentID(rawValue: $0) }
        currentTournamentCache = (Date(), ids)
        return ids
    }
}
