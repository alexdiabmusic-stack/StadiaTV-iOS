import Foundation

/// The rest of the app depends only on this protocol — it never needs to know
/// whether a resource came from the live CDN or stats.nba.com. Fallback between
/// the two hosts happens inside the methods below, never at the call site.
nonisolated protocol NBAAPIClientProtocol: Sendable {
    func todaysScoreboard() async throws -> NBAScoreboardResponse
    func scoreboard(on date: Date) async throws -> [NBAValue]
    func boxScore(gameID: String) async throws -> NBABoxScoreResponse
    func playByPlay(gameID: String) async throws -> NBAPlayByPlayResponse
    func scheduleLeagueV2(season: String) async throws -> NBAScheduleResponse
    func leagueStandingsV3(season: String, seasonType: String) async throws -> NBAStandingsResponse
    func scoreboardV3(date: Date) async throws -> NBAScoreboardV3Response
    func playByPlayV3(gameID: String) async throws -> NBAPlayByPlayV3Response
    func commonPlayerInfo(playerID: String) async throws -> NBAPlayerInfoResponse
    func playerCareerStats(playerID: String) async throws -> NBAPlayerCareerStatsResponse
    func commonTeamRoster(teamID: String, season: String) async throws -> NBARosterResponse
}

actor NBAAPIClient {
    static let shared = NBAAPIClient()
    private let live: any NBALiveCDNClientProtocol
    private let stats: any NBAStatsClientProtocol

    init(live: any NBALiveCDNClientProtocol = NBALiveCDNClient.shared, stats: any NBAStatsClientProtocol = NBAStatsClient.shared) {
        self.live = live; self.stats = stats
    }

    /// Only a host-level failure (blocked/rate-limited/HTTP) falls back — a decode
    /// failure means the response shape changed and must surface, not be masked
    /// by trying a different host.
    private func isFallbackEligible(_ error: Error) -> Bool {
        guard let apiError = error as? NBAAPIError else { return false }
        switch apiError {
        case .blocked, .http, .rateLimited: return true
        case .invalidURL, .invalidResponse, .decoding: return false
        }
    }

    func todaysScoreboard() async throws -> NBAScoreboardResponse {
        do { return try await live.todaysScoreboard() }
        catch {
            guard isFallbackEligible(error) else { throw error }
            // Both DTOs wrap the identical "scoreboard.games" envelope, so the
            // fallback payload can be handed straight to the CDN's response type.
            let fallback = try await stats.scoreboardV3(date: Date())
            return NBAScoreboardResponse(raw: fallback.raw)
        }
    }

    /// Raw per-game values (the shared currency `NBAGameMapper.game(_:)` consumes),
    /// since no single DTO type spans "today via CDN", "this season via the CDN
    /// static schedule filtered to a day", and "any date via stats.nba.com".
    func scoreboard(on date: Date) async throws -> [NBAValue] {
        if NBASeason.day(date) == NBASeason.day(Date()) {
            return try await todaysScoreboard().games
        }
        if NBASeason.current(on: date) == NBASeason.current() {
            do {
                let schedule = try await live.scheduleLeagueV2()
                let day = NBASeason.day(date)
                let filtered = schedule.games.filter { game in
                    guard let start = NBASeason.parse(game["gameDateTimeUTC"].string ?? game["gameDateUTC"].string) else { return false }
                    return NBASeason.day(start) == day
                }
                return filtered
            } catch {
                guard isFallbackEligible(error) else { throw error }
            }
        }
        return try await stats.scoreboardV3(date: date).games
    }

    func boxScore(gameID: String) async throws -> NBABoxScoreResponse { try await live.boxScore(gameID: gameID) }
    func playByPlay(gameID: String) async throws -> NBAPlayByPlayResponse { try await live.playByPlay(gameID: gameID) }

    /// The CDN's static schedule only ever holds the current season, so historical
    /// seasons go straight to stats.nba.com; the current season prefers the CDN and
    /// falls back to stats on a host-level failure.
    func scheduleLeagueV2(season: String) async throws -> NBAScheduleResponse {
        guard season == NBASeason.current() else { return try await stats.scheduleLeagueV2(season: season) }
        do { return try await live.scheduleLeagueV2() }
        catch {
            guard isFallbackEligible(error) else { throw error }
            return try await stats.scheduleLeagueV2(season: season)
        }
    }

    func leagueStandingsV3(season: String, seasonType: String) async throws -> NBAStandingsResponse { try await stats.leagueStandingsV3(season: season, seasonType: seasonType) }
    func scoreboardV3(date: Date) async throws -> NBAScoreboardV3Response { try await stats.scoreboardV3(date: date) }
    func playByPlayV3(gameID: String) async throws -> NBAPlayByPlayV3Response { try await stats.playByPlayV3(gameID: gameID) }
    func commonPlayerInfo(playerID: String) async throws -> NBAPlayerInfoResponse { try await stats.commonPlayerInfo(playerID: playerID) }
    func playerCareerStats(playerID: String) async throws -> NBAPlayerCareerStatsResponse { try await stats.playerCareerStats(playerID: playerID) }
    func commonTeamRoster(teamID: String, season: String) async throws -> NBARosterResponse { try await stats.commonTeamRoster(teamID: teamID, season: season) }
}
extension NBAAPIClient: NBAAPIClientProtocol {}
