import Foundation

struct FantasyProviderCapabilities: Hashable, Sendable {
    let leagues: Bool
    let rosters: Bool
    let matchups: Bool
    let standings: Bool
    let liveScoring: Bool
    let projections: Bool
    let transactions: Bool
    let waiversWrite: Bool
    let tradesWrite: Bool
    let draftWrite: Bool

    static let readOnlyCore = FantasyProviderCapabilities(
        leagues: true,
        rosters: true,
        matchups: true,
        standings: true,
        liveScoring: false,
        projections: false,
        transactions: false,
        waiversWrite: false,
        tradesWrite: false,
        draftWrite: false
    )
}

protocol FantasyProviderService: Sendable {
    nonisolated var provider: FantasyProvider { get }
    nonisolated var capabilities: FantasyProviderCapabilities { get }

    func connect(usernameOrUserID: String) async throws -> FantasyConnection
    func currentSeasonState(for connection: FantasyConnection) async throws -> FantasySeasonState
    func leagues(for connection: FantasyConnection, season: String) async throws -> [FantasyLeague]
    func league(id: String) async throws -> FantasyLeague
    func leagueUsers(leagueID: String) async throws -> [FantasyTeam]
    func leagueRosters(leagueID: String, teams: [FantasyTeam]) async throws -> [FantasyRoster]
    func userRoster(in rosters: [FantasyRoster], connection: FantasyConnection) -> FantasyRoster?
    func matchup(leagueID: String, week: Int, userRosterID: Int, teams: [FantasyTeam]) async throws -> FantasyMatchup?
    func standings(leagueID: String, rosters: [FantasyRoster]) async throws -> [FantasyStanding]
    func players(ids: Set<String>, sport: FantasySport) async throws -> [String: FantasyPlayer]
    func disconnect(connection: FantasyConnection) async
    func refreshCachedData() async
}

struct FantasyProviderRegistry: Sendable {
    private let services: [FantasyProvider: any FantasyProviderService]

    nonisolated init(services: [any FantasyProviderService] = FantasyProviderRegistry.defaultServices()) {
        self.services = Dictionary(uniqueKeysWithValues: services.map { ($0.provider, $0) })
    }

    private nonisolated static func defaultServices() -> [any FantasyProviderService] {
        var services: [any FantasyProviderService] = []
        if AppConfiguration.isSleeperFantasyProviderEnabled {
            services.append(SleeperFantasyService())
        }
        if AppConfiguration.isESPNFantasyProviderEnabled {
            services.append(ESPNFantasyService())
        }
        return services
    }

    func service(for provider: FantasyProvider) throws -> any FantasyProviderService {
        guard let service = services[provider] else { throw FantasyProviderError.unsupportedProvider }
        return service
    }
}

protocol ESPNFantasyCredentialSaving: Sendable {
    func saveESPNFantasyCredentials(espnS2: String, swid: String, sport: FantasySport, leagueID: String, seasonID: Int) async throws
}

protocol FantasyEventLinking: Sendable {
    func linkPlayerGames(
        players: [FantasyPlayer],
        resolutions: [String: FantasyPlayerResolution],
        matchup: FantasyMatchup?,
        channels: [Channel],
        preferredLanguages: Set<String>,
        knownMatches: [Match]?
    ) async -> [FantasyPlayerGame]
}

enum FantasyProviderError: LocalizedError, Equatable, Sendable {
    case invalidIdentifier
    case userNotFound
    case badResponse
    case httpError(Int)
    case noConnectedUserRoster
    case unsupportedProvider
    case authenticationRequired
    case authenticationExpired
    case leagueNotFound
    case suspiciousResponse

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "Enter a valid Fantasy account identifier."
        case .userNotFound: return "No Fantasy user was found for that identifier."
        case .badResponse: return "The Fantasy provider returned data Stadia could not read."
        case .httpError(let status): return "The Fantasy provider returned HTTP \(status)."
        case .noConnectedUserRoster: return "No roster in this league belongs to the connected Fantasy account."
        case .unsupportedProvider: return "That Fantasy provider is not supported yet."
        case .authenticationRequired: return "This Fantasy league requires credentials."
        case .authenticationExpired: return "Fantasy credentials need to be refreshed."
        case .leagueNotFound: return "We couldn't find that Fantasy league for the selected season."
        case .suspiciousResponse: return "The Fantasy provider returned an incomplete response."
        }
    }
}
