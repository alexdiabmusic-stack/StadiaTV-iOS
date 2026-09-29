import Foundation
nonisolated enum SportsDataError: LocalizedError, Equatable, Sendable {
    case unavailable
    case rateLimited(retryAfter: TimeInterval?)
    case authenticationFailed
    case invalidResponse
    case decodingFailed
    case unsupportedCapability(SportsDataCapability)
    case providerDisabled(SportsDataProviderID)
    case network(String)
    case timedOut(SportsDataProviderID)
    case noProviderAvailable(SportsDataCapability, String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Sports data is temporarily unavailable."
        case .rateLimited:
            return "Sports data is temporarily rate limited."
        case .authenticationFailed:
            return "Sports data authentication failed."
        case .invalidResponse, .decodingFailed:
            return "Sports data returned an unexpected response."
        case .unsupportedCapability:
            return "This sports data capability is not supported."
        case .providerDisabled:
            return "This sports data provider is disabled."
        case .network:
            return "The network request failed."
        case .timedOut:
            return "The sports data request timed out."
        case .noProviderAvailable:
            return "No sports data provider is available for this request."
        }
    }
}

nonisolated protocol SportsProvider: Sendable {
    var metadata: SportsDataProviderMetadata { get }
}

nonisolated protocol ScoreProvider: SportsProvider {
    func liveScores(for league: League) async throws -> [BannerGame]
}

nonisolated protocol ScheduleProvider: SportsProvider {
    func schedule(for league: League, range: SportsDateRange) async throws -> BannerSchedule
}

nonisolated protocol StandingsProvider: SportsProvider {
    func standings(for league: League) async throws -> [BannerStandingGroup]
}

nonisolated protocol GameDetailsProvider: SportsProvider {
    func gameDetails(for league: League, gameID: BannerEntityID) async throws -> BannerGame
}

nonisolated protocol BoxScoreProvider: SportsProvider {
    func boxScore(for league: League, gameID: BannerEntityID) async throws -> BannerBoxScore
}

nonisolated protocol PlayByPlayProvider: SportsProvider {
    func playByPlay(for league: League, gameID: BannerEntityID) async throws -> BannerPlayByPlay
}

nonisolated protocol TeamProvider: SportsProvider {
    func teams(for league: League) async throws -> [BannerTeam]
}

nonisolated protocol PlayerProvider: SportsProvider {
    func players(for league: League, teamID: BannerEntityID?) async throws -> [BannerPlayer]
}

nonisolated protocol RosterProvider: SportsProvider {
    func roster(for league: League, teamID: BannerEntityID) async throws -> BannerRoster
}

nonisolated protocol PlayerStatsProvider: SportsProvider {
    func playerStats(for league: League, playerIDs: Set<BannerEntityID>, range: SportsDateRange?) async throws -> [BannerPlayerStat]
}

nonisolated protocol TeamStatsProvider: SportsProvider {
    func teamStats(for league: League, teamIDs: Set<BannerEntityID>, range: SportsDateRange?) async throws -> [BannerTeamStat]
}

nonisolated protocol InjuryProvider: SportsProvider {
    func injuries(for league: League) async throws -> [BannerInjury]
}

nonisolated protocol LeagueLeaderProvider: SportsProvider {
    func leaders(for league: League) async throws -> [BannerLeader]
}

nonisolated protocol GolfTournamentProvider: SportsProvider {
    func golfTournament(for league: League, gameID: BannerEntityID) async throws -> BannerGolfTournament
}

nonisolated protocol SportsNewsProvider: SportsProvider {
    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle]
    /// Returns false for providers that ignore the page parameter (e.g. Yahoo). The repository
    /// skips these when page > 1 so they don't repeat page-1 content in response to pagination.
    var supportsPagination: Bool { get }
}

extension SportsNewsProvider {
    var supportsPagination: Bool { true }
}

