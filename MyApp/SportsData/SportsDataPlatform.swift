import Foundation

extension SportGroup: Codable, Sendable {}

// MARK: - Provider metadata

enum SportsDataProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case nhl
    case mlb
    case nba
    case nfl
    case cbsSports
    case yahooSports
    case foxSports
    case appleSports
    case espn
    // News-only providers (RSS + structured feeds)
    case foxBifrostNews
    case cbsRSS
    case bbcSport
    case skySports
    case nbcSports
    case foxRSS
    case bleacherReport
}

enum SportsDataProviderSupportLevel: String, Codable, Hashable, Sendable {
    case official
    case firstPartyWeb
    case undocumented
    case experimental
    case legacy
}

enum SportsDataAuthenticationType: String, Codable, Hashable, Sendable {
    case none
    case publicWebHeaders
    case anonymousBearerToken
    case apiKey
    case oauth
    case cookies
}

enum SportsDataCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case liveScores
    case schedule
    case gameStatus
    case gameDetails
    case playByPlay
    case boxScore
    case standings
    case teams
    case players
    case rosters
    case playerStats
    case teamStats
    case injuries
    case leagueLeaders
    case golfTournament
    case newsMetadata
    case odds
    case fantasyRelevantData
}

struct SportsDataProviderMetadata: Identifiable, Hashable, Sendable {
    let id: SportsDataProviderID
    let name: String
    let supportLevel: SportsDataProviderSupportLevel
    let supportedSports: Set<SportGroup>
    let supportedLeagues: Set<String>
    let capabilities: Set<SportsDataCapability>
    let authenticationType: SportsDataAuthenticationType
    var isEnabled: Bool
    var requestTimeout: TimeInterval
}

// MARK: - Banner normalized domain

struct BannerEntityID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    nonisolated init(rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct ProviderEntityAlias: Codable, Hashable, Sendable {
    let provider: SportsDataProviderID
    let id: String
}

struct DataProvenance: Codable, Hashable, Sendable {
    let provider: SportsDataProviderID
    let fetchedAt: Date
    let providerEntityID: String?
    let confidence: Double
}

struct BannerSeason: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let leagueID: BannerEntityID
    let year: Int?
    let displayName: String
    let type: String?
}

struct BannerLeague: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let sport: SportGroup
    let name: String
    let shortName: String
    let aliases: [ProviderEntityAlias]

    init(id: BannerEntityID, sport: SportGroup, name: String, shortName: String, aliases: [ProviderEntityAlias] = []) {
        self.id = id
        self.sport = sport
        self.name = name
        self.shortName = shortName
        self.aliases = aliases
    }

    init(league: League, provider: SportsDataProviderID = .espn) {
        self.init(
            id: SportsIdentityResolver.canonicalLeagueID(for: league),
            sport: league.group,
            name: league.name,
            shortName: league.shortName,
            aliases: [ProviderEntityAlias(provider: provider, id: league.path)]
        )
    }
}

struct BannerVenue: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID?
    let name: String
    let city: String?
    let state: String?
    let country: String?
    let aliases: [ProviderEntityAlias]
}

struct BannerTeam: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let leagueID: BannerEntityID
    let displayName: String
    let shortName: String
    let abbreviation: String
    let logoURL: URL?
    let aliases: [ProviderEntityAlias]
    let provenance: DataProvenance?
}

struct BannerPlayer: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let leagueID: BannerEntityID
    let fullName: String
    let displayName: String
    let teamID: BannerEntityID?
    let teamAbbreviation: String?
    let position: String?
    let jerseyNumber: String?
    let birthDate: Date?
    let headshotURL: URL?
    let aliases: [ProviderEntityAlias]
    let provenance: DataProvenance?
}

enum BannerGameStatus: String, Codable, Hashable, Sendable {
    case scheduled
    case pregame
    case live
    case delayed
    case postponed
    case suspended
    case final
    case cancelled
    case unknown

    init(gameState: GameState) {
        switch gameState {
        case .pre: self = .scheduled
        case .live: self = .live
        case .final: self = .final
        }
    }

    var legacyGameState: GameState {
        switch self {
        case .live: return .live
        case .final: return .final
        default: return .pre
        }
    }
}

struct BannerScore: Codable, Hashable, Sendable {
    let home: String?
    let away: String?
}

struct BannerGameClock: Codable, Hashable, Sendable {
    let displayValue: String?
    let remainingSeconds: Int?
    let isRunning: Bool?
}

struct BannerPeriod: Codable, Hashable, Sendable {
    let number: Int?
    let displayName: String?
}

struct BannerBroadcast: Identifiable, Codable, Hashable, Sendable {
    var id: String { [network, type].compactMap { $0 }.joined(separator: ":") }
    let network: String?
    let type: String?
    let countryCode: String?
}

struct BannerGame: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let leagueID: BannerEntityID
    let scheduledStart: Date
    let name: String
    let shortName: String
    let status: BannerGameStatus
    let statusDetail: String
    let homeTeam: BannerTeam
    let awayTeam: BannerTeam
    let score: BannerScore
    let clock: BannerGameClock?
    let period: BannerPeriod?
    let venue: BannerVenue?
    let broadcasts: [BannerBroadcast]
    let aliases: [ProviderEntityAlias]
    let provenance: DataProvenance
}

enum BannerTournamentStatus: String, Codable, Hashable, Sendable {
    case upcoming
    case live
    case suspended
    case complete
    case unknown

    init(gameStatus: BannerGameStatus) {
        switch gameStatus {
        case .scheduled, .pregame:
            self = .upcoming
        case .live, .delayed:
            self = .live
        case .suspended, .postponed:
            self = .suspended
        case .final:
            self = .complete
        case .cancelled, .unknown:
            self = .unknown
        }
    }
}

struct BannerGolfCourse: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID?
    let name: String
    let location: String?
    let par: Int?
    let yardage: Int?
    let holes: [BannerGolfCourseHole]
}

struct BannerGolfCourseHole: Identifiable, Codable, Hashable, Sendable {
    let number: Int
    let par: Int?
    let yardage: Int?
    let handicap: Int?

    var id: Int { number }
}

struct BannerGolfHoleScore: Identifiable, Codable, Hashable, Sendable {
    let hole: Int
    let par: Int?
    let strokes: Int?
    let scoreToPar: String?

    var id: Int { hole }
}

struct BannerGolfRound: Identifiable, Codable, Hashable, Sendable {
    let number: Int
    let displayName: String?
    let score: String?
    let strokes: Int?
    let scoreToPar: String?
    let holes: [BannerGolfHoleScore]

    var id: Int { number }
}

struct BannerGolfLeaderboardEntry: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let playerID: BannerEntityID?
    let playerName: String
    let position: String?
    let isTied: Bool
    let totalScore: String?
    let todayScore: String?
    let thru: String?
    let status: String?
    let rounds: [BannerGolfRound]
    let stats: [BannerStatValue]
    let aliases: [ProviderEntityAlias]
    let provenance: DataProvenance?
}

struct BannerGolfTournament: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let leagueID: BannerEntityID
    let gameID: BannerEntityID?
    let tournamentName: String
    let tourName: String?
    let status: BannerTournamentStatus
    let statusDetail: String?
    let currentRound: Int?
    let totalRounds: Int?
    let course: BannerGolfCourse?
    let cutLine: String?
    let leaderboard: [BannerGolfLeaderboardEntry]
    let broadcasts: [BannerBroadcast]
    let stats: [BannerStatValue]
    let provenance: DataProvenance
}

enum BannerGolfScoreFormatter {
    nonisolated static func format(raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != "-" else { return nil }
        let upper = cleaned.uppercased()
        if ["E", "WD", "CUT", "DQ", "DNS", "F"].contains(upper) { return upper }
        if cleaned == "0" { return "E" }
        if let value = Int(cleaned.replacingOccurrences(of: "+", with: "")) {
            if value == 0 { return "E" }
            return value > 0 ? "+\(value)" : "\(value)"
        }
        return cleaned
    }

    nonisolated static func sortValue(_ value: String?) -> Int {
        guard let value else { return Int.max - 1 }
        let cleaned = value.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == "E" { return 0 }
        if cleaned == "WD" || cleaned == "CUT" || cleaned == "DQ" || cleaned == "DNS" { return Int.max }
        return Int(cleaned.replacingOccurrences(of: "+", with: "")) ?? Int.max - 1
    }
}

enum BannerGolfLeaderboardNormalizer {
    nonisolated static func normalized(_ entries: [BannerGolfLeaderboardEntry]) -> [BannerGolfLeaderboardEntry] {
        let sorted = entries.sorted {
            BannerGolfScoreFormatter.sortValue($0.totalScore) < BannerGolfScoreFormatter.sortValue($1.totalScore)
        }
        let grouped = Dictionary(grouping: sorted) { $0.totalScore ?? "" }
        return sorted.enumerated().map { index, entry in
            guard entry.position == nil || entry.position?.isEmpty == true else { return entry }
            let scoreKey = entry.totalScore ?? ""
            let tied = (grouped[scoreKey]?.count ?? 1) > 1 && !scoreKey.isEmpty
            return BannerGolfLeaderboardEntry(
                id: entry.id,
                playerID: entry.playerID,
                playerName: entry.playerName,
                position: tied ? "T\(index + 1)" : "\(index + 1)",
                isTied: tied,
                totalScore: entry.totalScore,
                todayScore: entry.todayScore,
                thru: entry.thru,
                status: entry.status,
                rounds: entry.rounds,
                stats: entry.stats,
                aliases: entry.aliases,
                provenance: entry.provenance
            )
        }
    }
}

struct BannerStanding: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let teamID: BannerEntityID
    let teamDisplayName: String?
    let teamAbbreviation: String?
    let teamLogoURL: URL?
    let groupName: String?
    let rank: Int?
    let wins: String?
    let losses: String?
    let ties: String?
    let points: String?
    let gamesPlayed: String?
    let displayRecord: String
    let provenance: DataProvenance?

    init(
        id: BannerEntityID,
        teamID: BannerEntityID,
        teamDisplayName: String? = nil,
        teamAbbreviation: String? = nil,
        teamLogoURL: URL? = nil,
        groupName: String?,
        rank: Int?,
        wins: String?,
        losses: String?,
        ties: String?,
        points: String?,
        gamesPlayed: String?,
        displayRecord: String,
        provenance: DataProvenance?
    ) {
        self.id = id
        self.teamID = teamID
        self.teamDisplayName = teamDisplayName
        self.teamAbbreviation = teamAbbreviation
        self.teamLogoURL = teamLogoURL
        self.groupName = groupName
        self.rank = rank
        self.wins = wins
        self.losses = losses
        self.ties = ties
        self.points = points
        self.gamesPlayed = gamesPlayed
        self.displayRecord = displayRecord
        self.provenance = provenance
    }
}

struct BannerStandingGroup: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let name: String
    let standings: [BannerStanding]
}

struct BannerStatValue: Identifiable, Codable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let displayName: String
    let value: String
}

struct BannerPlayerStat: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let playerID: BannerEntityID
    let playerDisplayName: String?
    let teamAbbreviation: String?
    let headshotURL: URL?
    let teamID: BannerEntityID?
    let seasonID: BannerEntityID?
    let stats: [BannerStatValue]
    let provenance: DataProvenance?

    init(
        id: BannerEntityID,
        playerID: BannerEntityID,
        playerDisplayName: String? = nil,
        teamAbbreviation: String? = nil,
        headshotURL: URL? = nil,
        teamID: BannerEntityID?,
        seasonID: BannerEntityID?,
        stats: [BannerStatValue],
        provenance: DataProvenance?
    ) {
        self.id = id
        self.playerID = playerID
        self.playerDisplayName = playerDisplayName
        self.teamAbbreviation = teamAbbreviation
        self.headshotURL = headshotURL
        self.teamID = teamID
        self.seasonID = seasonID
        self.stats = stats
        self.provenance = provenance
    }
}

struct BannerTeamStat: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let teamID: BannerEntityID
    let seasonID: BannerEntityID?
    let stats: [BannerStatValue]
    let provenance: DataProvenance?
}

struct BannerBoxScore: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let gameID: BannerEntityID
    let teamStats: [BannerTeamStat]
    let playerStats: [BannerPlayerStat]
    let provenance: DataProvenance
}

struct BannerPlay: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let sequence: Int?
    let period: BannerPeriod?
    let clock: BannerGameClock?
    let text: String
    let teamID: BannerEntityID?
    let awayScore: String?
    let homeScore: String?
    let isScoringPlay: Bool
    let provenance: DataProvenance?
}

struct BannerPlayByPlay: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let gameID: BannerEntityID
    let plays: [BannerPlay]
    let provenance: DataProvenance
}

struct BannerRoster: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let teamID: BannerEntityID
    let leagueID: BannerEntityID
    let players: [BannerPlayer]
    let provenance: DataProvenance
}

struct BannerInjury: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let playerID: BannerEntityID?
    let playerName: String
    let teamID: BannerEntityID?
    let status: String
    let detail: String?
    let provenance: DataProvenance?
}

struct BannerLeader: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let statKey: String
    let displayName: String
    let players: [BannerPlayerStat]
    let provenance: DataProvenance?
}

struct BannerSchedule: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let leagueID: BannerEntityID
    let range: SportsDateRange
    let games: [BannerGame]
    let provenance: DataProvenance
}

struct BannerNewsArticle: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let headline: String
    let description: String
    let published: Date?
    let url: URL?
    let imageURL: URL?
    let leagueID: BannerEntityID?
    let teamIDs: [BannerEntityID]
    let playerIDs: [BannerEntityID]
    let sourceName: String?
    let provenance: DataProvenance?
    /// Display name of the publishing outlet (e.g. "CBS Sports", "BBC Sport").
    var publisher: String? = nil
    /// Content type such as "preview", "recap", "story", "breaking".
    var articleType: String? = nil
    /// Author byline when available; used in place of publisher in reader view.
    var authorByline: String? = nil
}

struct BannerOdds: Identifiable, Codable, Hashable, Sendable {
    let id: BannerEntityID
    let gameID: BannerEntityID
    let bookmakerName: String
    let homePrice: Int?
    let awayPrice: Int?
    let drawPrice: Int?
    let provenance: DataProvenance?
}

struct SportsDateRange: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case today
        case nextDays
        case previousDays
        case dateRange
    }

    let kind: Kind
    let start: Date
    let end: Date

    static func today(calendar: Calendar = .current, now: Date = Date()) -> SportsDateRange {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? now
        return SportsDateRange(kind: .today, start: start, end: end)
    }

    static func next(days: Int, calendar: Calendar = .current, now: Date = Date()) -> SportsDateRange {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: DateComponents(day: max(1, days), second: -1), to: start) ?? now
        return SportsDateRange(kind: .nextDays, start: start, end: end)
    }

    static func previous(days: Int, calendar: Calendar = .current, now: Date = Date()) -> SportsDateRange {
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: now)) ?? now
        let start = calendar.date(byAdding: .day, value: -max(1, days), to: calendar.startOfDay(for: now)) ?? now
        return SportsDateRange(kind: .previousDays, start: start, end: end)
    }

    static func dateRange(start: Date, end: Date) -> SportsDateRange {
        SportsDateRange(kind: .dateRange, start: start, end: end)
    }

    var dayCount: Int {
        max(1, (Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start), to: Calendar.current.startOfDay(for: end)).day ?? 0) + 1)
    }
}

// MARK: - Errors and capabilities

enum SportsDataError: LocalizedError, Equatable, Sendable {
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

protocol SportsProvider: Sendable {
    var metadata: SportsDataProviderMetadata { get }
}

protocol ScoreProvider: SportsProvider {
    func liveScores(for league: League) async throws -> [BannerGame]
}

protocol ScheduleProvider: SportsProvider {
    func schedule(for league: League, range: SportsDateRange) async throws -> BannerSchedule
}

protocol StandingsProvider: SportsProvider {
    func standings(for league: League) async throws -> [BannerStandingGroup]
}

protocol GameDetailsProvider: SportsProvider {
    func gameDetails(for league: League, gameID: BannerEntityID) async throws -> BannerGame
}

protocol BoxScoreProvider: SportsProvider {
    func boxScore(for league: League, gameID: BannerEntityID) async throws -> BannerBoxScore
}

protocol PlayByPlayProvider: SportsProvider {
    func playByPlay(for league: League, gameID: BannerEntityID) async throws -> BannerPlayByPlay
}

protocol TeamProvider: SportsProvider {
    func teams(for league: League) async throws -> [BannerTeam]
}

protocol PlayerProvider: SportsProvider {
    func players(for league: League, teamID: BannerEntityID?) async throws -> [BannerPlayer]
}

protocol RosterProvider: SportsProvider {
    func roster(for league: League, teamID: BannerEntityID) async throws -> BannerRoster
}

protocol PlayerStatsProvider: SportsProvider {
    func playerStats(for league: League, playerIDs: Set<BannerEntityID>, range: SportsDateRange?) async throws -> [BannerPlayerStat]
}

protocol TeamStatsProvider: SportsProvider {
    func teamStats(for league: League, teamIDs: Set<BannerEntityID>, range: SportsDateRange?) async throws -> [BannerTeamStat]
}

protocol InjuryProvider: SportsProvider {
    func injuries(for league: League) async throws -> [BannerInjury]
}

protocol LeagueLeaderProvider: SportsProvider {
    func leaders(for league: League) async throws -> [BannerLeader]
}

protocol GolfTournamentProvider: SportsProvider {
    func golfTournament(for league: League, gameID: BannerEntityID) async throws -> BannerGolfTournament
}

protocol SportsNewsProvider: SportsProvider {
    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle]
    /// Returns false for providers that ignore the page parameter (e.g. Yahoo). The repository
    /// skips these when page > 1 so they don't repeat page-1 content in response to pagination.
    var supportsPagination: Bool { get }
}

extension SportsNewsProvider {
    var supportsPagination: Bool { true }
}

// MARK: - Identity

struct SportsIdentityResolver: Sendable {
    func canonicalTeamID(league: League, provider: SportsDataProviderID, providerTeamID: String?, abbreviation: String, displayName: String) -> BannerEntityID {
        if provider == .espn, let providerTeamID, !providerTeamID.isEmpty {
            return BannerEntityID(rawValue: "team:\(league.bannerKey):espn:\(providerTeamID)")
        }
        let slug = Self.slug([league.bannerKey, abbreviation, displayName].joined(separator: ":"))
        return BannerEntityID(rawValue: "team:\(slug)")
    }

    func canonicalPlayerID(league: League, provider: SportsDataProviderID, providerPlayerID: String?, fullName: String, birthDate: Date? = nil, teamAbbreviation: String? = nil) -> BannerEntityID {
        if provider == .espn, let providerPlayerID, !providerPlayerID.isEmpty {
            return BannerEntityID(rawValue: "player:\(league.bannerKey):espn:\(providerPlayerID)")
        }
        let birth = birthDate.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        let slug = Self.slug([league.bannerKey, fullName, teamAbbreviation ?? "", birth].joined(separator: ":"))
        return BannerEntityID(rawValue: "player:\(slug)")
    }

    func canonicalGameID(league: League, provider: SportsDataProviderID, providerGameID: String?, home: BannerTeam, away: BannerTeam, scheduledStart: Date) -> BannerEntityID {
        if provider == .espn, let providerGameID, !providerGameID.isEmpty {
            return BannerEntityID(rawValue: "game:\(league.bannerKey):espn:\(providerGameID)")
        }
        let minute = Int(scheduledStart.timeIntervalSince1970 / 60)
        let slug = Self.slug([league.bannerKey, home.id.rawValue, away.id.rawValue, String(minute)].joined(separator: ":"))
        return BannerEntityID(rawValue: "game:\(slug)")
    }

    nonisolated static func canonicalLeagueID(for league: League) -> BannerEntityID {
        BannerEntityID(rawValue: "league:\(league.bannerKey)")
    }

    static func providerID(from canonicalID: BannerEntityID, provider: SportsDataProviderID) -> String? {
        let parts = canonicalID.rawValue.split(separator: ":").map(String.init)
        guard parts.count >= 4, parts[2] == provider.rawValue else { return nil }
        return parts[3]
    }

    static func slug(_ value: String) -> String {
        value
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - Health, cache, and request coalescing

enum SportsProviderHealthState: String, Codable, Equatable, Sendable {
    case healthy
    case degraded
    case rateLimited
    case unavailable
    case disabled
}

struct SportsProviderHealthSnapshot: Codable, Equatable, Sendable {
    var state: SportsProviderHealthState
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var recentFailures: Int
    var recentSuccesses: Int
    var averageLatency: TimeInterval?
    var cooldownUntil: Date?
    var lastErrorDescription: String?

    nonisolated static var healthySnapshot: SportsProviderHealthSnapshot {
        SportsProviderHealthSnapshot(
            state: .healthy,
            lastSuccessAt: nil,
            lastFailureAt: nil,
            recentFailures: 0,
            recentSuccesses: 0,
            averageLatency: nil,
            cooldownUntil: nil,
            lastErrorDescription: nil
        )
    }
}

actor ProviderHealthMonitor {
    private var snapshots: [SportsDataProviderID: SportsProviderHealthSnapshot] = [:]
    private let failureCooldownThreshold: Int
    private let cooldownDuration: TimeInterval

    init(failureCooldownThreshold: Int = 3, cooldownDuration: TimeInterval = 60) {
        self.failureCooldownThreshold = failureCooldownThreshold
        self.cooldownDuration = cooldownDuration
    }

    func snapshot(for providerID: SportsDataProviderID) -> SportsProviderHealthSnapshot {
        snapshots[providerID] ?? .healthySnapshot
    }

    func isAvailable(_ provider: SportsDataProviderMetadata, at now: Date = Date()) -> Bool {
        guard provider.isEnabled else { return false }
        let snapshot = snapshots[provider.id] ?? SportsProviderHealthSnapshot.healthySnapshot
        if snapshot.state == SportsProviderHealthState.disabled || snapshot.state == SportsProviderHealthState.unavailable { return false }
        if let cooldownUntil = snapshot.cooldownUntil, cooldownUntil > now { return false }
        return true
    }

    func recordSuccess(providerID: SportsDataProviderID, latency: TimeInterval, at now: Date = Date()) {
        var snapshot = snapshots[providerID] ?? SportsProviderHealthSnapshot.healthySnapshot
        snapshot.state = SportsProviderHealthState.healthy
        snapshot.lastSuccessAt = now
        snapshot.recentSuccesses += 1
        snapshot.recentFailures = 0
        snapshot.cooldownUntil = nil
        snapshot.lastErrorDescription = nil
        if let average = snapshot.averageLatency {
            snapshot.averageLatency = (average * 0.8) + (latency * 0.2)
        } else {
            snapshot.averageLatency = latency
        }
        snapshots[providerID] = snapshot
    }

    func recordFailure(providerID: SportsDataProviderID, error: Error, at now: Date = Date()) {
        var snapshot = snapshots[providerID] ?? SportsProviderHealthSnapshot.healthySnapshot
        snapshot.lastFailureAt = now
        snapshot.recentFailures += 1
        snapshot.lastErrorDescription = error.localizedDescription

        if case SportsDataError.rateLimited = error {
            snapshot.state = SportsProviderHealthState.rateLimited
            snapshot.cooldownUntil = now.addingTimeInterval(cooldownDuration)
        } else if snapshot.recentFailures >= failureCooldownThreshold {
            snapshot.state = SportsProviderHealthState.unavailable
            snapshot.cooldownUntil = now.addingTimeInterval(cooldownDuration)
        } else {
            snapshot.state = SportsProviderHealthState.degraded
        }
        snapshots[providerID] = snapshot
    }

    func setEnabled(_ enabled: Bool, providerID: SportsDataProviderID) {
        var snapshot = snapshots[providerID] ?? SportsProviderHealthSnapshot.healthySnapshot
        snapshot.state = enabled ? SportsProviderHealthState.healthy : SportsProviderHealthState.disabled
        snapshot.cooldownUntil = enabled ? nil : Date.distantFuture
        snapshots[providerID] = snapshot
    }
}

struct SportsCacheKey: Sendable {
    let providerID: SportsDataProviderID
    let leagueID: String
    let capability: SportsDataCapability
    let scope: String

    nonisolated var rawValue: String {
        "\(providerID.rawValue)|\(leagueID)|\(capability.rawValue)|\(scope)"
    }
}

actor SportsDataCache {
    private struct Entry {
        let value: Any
        let fetchedAt: Date
        let ttl: TimeInterval
        var lastAccessedAt: Date
    }

    private let maxEntryCount = 400
    private var entries: [String: Entry] = [:]

    func value<T>(for key: SportsCacheKey, as type: T.Type = T.self, now: Date = Date()) -> T? {
        guard var entry = entries[key.rawValue] else { return nil }
        guard !isExpired(entry, now: now) else {
            entries.removeValue(forKey: key.rawValue)
            return nil
        }
        entry.lastAccessedAt = now
        entries[key.rawValue] = entry
        return entry.value as? T
    }

    func age(for key: SportsCacheKey, now: Date = Date()) -> TimeInterval? {
        guard let entry = entries[key.rawValue] else { return nil }
        guard !isExpired(entry, now: now) else {
            entries.removeValue(forKey: key.rawValue)
            return nil
        }
        return now.timeIntervalSince(entry.fetchedAt)
    }

    func store<T: Sendable>(_ value: T, for key: SportsCacheKey, ttl: TimeInterval, now: Date = Date()) {
        cleanupExpired(now: now)
        entries[key.rawValue] = Entry(value: value, fetchedAt: now, ttl: ttl, lastAccessedAt: now)
        enforceSizeLimit()
    }

    func removeAll() {
        entries.removeAll()
    }

    func remove(for key: SportsCacheKey) {
        entries.removeValue(forKey: key.rawValue)
    }

    private func isExpired(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.fetchedAt) >= entry.ttl
    }

    private func cleanupExpired(now: Date) {
        entries = entries.filter { !isExpired($0.value, now: now) }
    }

    private func enforceSizeLimit() {
        guard entries.count > maxEntryCount else { return }
        let overflowCount = entries.count - maxEntryCount
        let evictionKeys = entries
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
            .prefix(overflowCount)
            .map(\.key)
        evictionKeys.forEach { entries.removeValue(forKey: $0) }
    }

    static func defaultTTL(for capability: SportsDataCapability, containsLiveGames: Bool = false) -> TimeInterval {
        switch capability {
        case .liveScores:
            return containsLiveGames ? 15 : 45
        case .schedule:
            return containsLiveGames ? 30 : 60 * 60
        case .gameStatus, .gameDetails, .playByPlay, .boxScore:
            return containsLiveGames ? 20 : 5 * 60
        case .standings:
            return 45 * 60
        case .rosters, .players:
            return 12 * 60 * 60
        case .teams:
            return 7 * 24 * 60 * 60
        case .playerStats, .teamStats, .leagueLeaders:
            return 60 * 60
        case .golfTournament:
            return containsLiveGames ? 30 : 10 * 60
        case .injuries:
            return 15 * 60
        case .newsMetadata:
            return 10 * 60
        case .odds:
            return 60
        case .fantasyRelevantData:
            return 60
        }
    }
}

actor SportsRequestDeduplicator<Key: Hashable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Error>] = [:]

    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task { try await operation() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

// MARK: - Routing

struct ProviderRoute: Hashable, Sendable {
    let leagueID: String
    let capability: SportsDataCapability
    var providers: [SportsDataProviderID]
}

struct SportsProviderRouteConfiguration: Sendable {
    var routes: [ProviderRoute]

    func providers(for league: League, capability: SportsDataCapability) -> [SportsDataProviderID] {
        routes.first { $0.leagueID == league.bannerKey && $0.capability == capability }?.providers
            ?? routes.first { $0.leagueID == league.path && $0.capability == capability }?.providers
            ?? routes.first { $0.leagueID == "*" && $0.capability == capability }?.providers
            ?? [.espn]
    }

    static let firstPass = SportsProviderRouteConfiguration(routes: Self.defaultRoutes())

    private static func defaultRoutes() -> [ProviderRoute] {
        let firstPartyCore: [(String, [SportsDataProviderID])] = [
            (leagueKey(forLegacyPath: "hockey/nhl"), [.nhl, .appleSports, .foxSports, .cbsSports, .espn]),
            (leagueKey(forLegacyPath: "baseball/mlb"), [.mlb, .appleSports, .foxSports, .cbsSports, .espn]),
            (leagueKey(forLegacyPath: "basketball/nba"), [.nba, .appleSports, .foxSports, .cbsSports, .espn]),
            (leagueKey(forLegacyPath: "football/nfl"), [.nfl, .appleSports, .cbsSports, .espn])
        ]
        let cfbLeagueID = leagueKey(forLegacyPath: "football/college-football")
        let foxBasketballFallbackLeaguePaths = [
            "basketball/mens-college-basketball",
            "basketball/womens-college-basketball",
            "basketball/wnba"
        ]
        let applePrimaryLeaguePaths: [String] = [
            "football/college-football",
            "basketball/mens-college-basketball",
            "basketball/womens-college-basketball",
            "basketball/wnba",
            "soccer/eng.1",
            "soccer/eng.2",
            "soccer/usa.1",
            "soccer/usa.nwsl",
            "soccer/esp.1",
            "soccer/ita.1",
            "soccer/ger.1",
            "soccer/fra.1",
            "soccer/mex.1",
            "soccer/ned.1",
            "soccer/por.1",
            "soccer/ksa.1",
            "soccer/uefa.champions",
            "soccer/uefa.europa",
            "soccer/fifa.world",
            "soccer/fifa.wwc",
            "tennis/atp",
            "tennis/wta",
            "golf/pga",
            "golf/lpga",
            "golf/champions-tour",
            "golf/eur",
            "racing/f1",
            "racing/nascar-premier",
            "racing/nascar-truck",
            "racing/irl"
        ]
        let applePrimaryLeagues = applePrimaryLeaguePaths.map(leagueKey(forLegacyPath:))
        let defaultCapabilities: [SportsDataCapability] = [.liveScores, .schedule, .gameStatus, .gameDetails, .playByPlay, .boxScore, .standings, .teams, .players, .rosters, .playerStats, .teamStats, .injuries, .leagueLeaders, .fantasyRelevantData]
        let appleBaselineCapabilities: [SportsDataCapability] = [.liveScores, .schedule, .gameStatus, .gameDetails, .boxScore, .standings, .teams, .playerStats, .teamStats, .leagueLeaders, .golfTournament]
        var routes = firstPartyCore.flatMap { leagueID, providers in
            defaultCapabilities.map { ProviderRoute(leagueID: leagueID, capability: $0, providers: providers) }
        }
        routes += applePrimaryLeagues.flatMap { leagueID in
            let providers: [SportsDataProviderID]
            if leagueID == cfbLeagueID {
                providers = [.appleSports, .foxSports, .yahooSports, .cbsSports, .espn]
            } else if foxBasketballFallbackLeaguePaths.map(leagueKey(forLegacyPath:)).contains(leagueID) {
                providers = [.appleSports, .foxSports, .cbsSports, .espn]
            } else {
                providers = [.appleSports, .espn]
            }
            return appleBaselineCapabilities.map { ProviderRoute(leagueID: leagueID, capability: $0, providers: providers) }
        }
        routes.append(ProviderRoute(leagueID: "*", capability: .liveScores, providers: [.appleSports, .espn]))
        routes.append(ProviderRoute(leagueID: "*", capability: .schedule, providers: [.appleSports, .espn]))
        routes.append(ProviderRoute(leagueID: "*", capability: .golfTournament, providers: [.appleSports, .espn]))
        // News: ESPN primary + all multi-source providers for parallel aggregation.
        routes.append(ProviderRoute(leagueID: "*", capability: .newsMetadata, providers: [
            .espn, .yahooSports, .foxBifrostNews,
            .cbsRSS, .bbcSport, .skySports, .nbcSports, .foxRSS
        ]))
        routes.append(ProviderRoute(leagueID: "*", capability: .odds, providers: [.espn]))
        return routes
    }

    nonisolated static func leagueKey(forLegacyPath path: String) -> String {
        let slug = path
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "league.\(slug)"
    }
}

struct SportsProviderRouteOverride: Identifiable, Codable, Hashable, Sendable {
    nonisolated var id: String { "\(leagueID)|\(capability.rawValue)|\(providerID.rawValue)" }
    let leagueID: String
    let capability: SportsDataCapability
    let providerID: SportsDataProviderID
    var isEnabled: Bool
}

actor SportsProviderRouteOverrideStore {
    static let shared = SportsProviderRouteOverrideStore()

    private let storageKey: String
    private var overrides: [String: SportsProviderRouteOverride]

    init(storageKey: String = "sportsData.routeOverrides.v1") {
        self.storageKey = storageKey
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SportsProviderRouteOverride].self, from: data) {
            overrides = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            overrides = [:]
        }
    }

    func isProviderEnabled(_ providerID: SportsDataProviderID, leagueID: String, capability: SportsDataCapability) -> Bool {
        let exact = key(leagueID: leagueID, capability: capability, providerID: providerID)
        let global = key(leagueID: "*", capability: capability, providerID: providerID)
        return overrides[exact]?.isEnabled ?? overrides[global]?.isEnabled ?? true
    }

    func setProvider(_ providerID: SportsDataProviderID, enabled: Bool, leagueID: String, capability: SportsDataCapability) {
        let override = SportsProviderRouteOverride(leagueID: leagueID, capability: capability, providerID: providerID, isEnabled: enabled)
        overrides[override.id] = override
        persist()
    }

    func removeOverride(providerID: SportsDataProviderID, leagueID: String, capability: SportsDataCapability) {
        overrides[key(leagueID: leagueID, capability: capability, providerID: providerID)] = nil
        persist()
    }

    func all() -> [SportsProviderRouteOverride] {
        overrides.values.sorted { lhs, rhs in
            [lhs.leagueID, lhs.capability.rawValue, lhs.providerID.rawValue].joined(separator: "|") < [rhs.leagueID, rhs.capability.rawValue, rhs.providerID.rawValue].joined(separator: "|")
        }
    }

    func removeAll() {
        overrides.removeAll()
        persist()
    }

    private func key(leagueID: String, capability: SportsDataCapability, providerID: SportsDataProviderID) -> String {
        "\(leagueID)|\(capability.rawValue)|\(providerID.rawValue)"
    }

    private func persist() {
        let values = Array(overrides.values)
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

struct SportsProviderRegistry: Sendable {
    private let providers: [SportsDataProviderID: any SportsProvider]

    init(providers: [any SportsProvider]) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.metadata.id, $0) })
    }

    func provider(id: SportsDataProviderID) -> (any SportsProvider)? {
        providers[id]
    }

    func metadata() -> [SportsDataProviderMetadata] {
        providers.values.map(\.metadata).sorted { $0.name < $1.name }
    }

    static func production() -> SportsProviderRegistry {
        var providers: [any SportsProvider] = [ESPNProvider()]
        if AppConfiguration.isAppleSportsProviderEnabled {
            providers.insert(AppleSportsProvider(), at: 0)
        }
        if AppConfiguration.isMLBProviderEnabled {
            providers.insert(MLBProvider(), at: 0)
        }
        if AppConfiguration.isNBAProviderEnabled {
            providers.insert(NBAProvider(), at: 0)
        }
        if AppConfiguration.isNFLProviderEnabled {
            providers.insert(NFLProvider(), at: 0)
        }
        if AppConfiguration.isCBSSportsProviderEnabled {
            providers.insert(CBSSportsProvider(), at: 0)
        }
        if AppConfiguration.isYahooSportsProviderEnabled {
            providers.insert(YahooSportsProvider(), at: 0)
        }
        if AppConfiguration.isFoxSportsProviderEnabled {
            providers.insert(FoxSportsProvider(), at: 0)
        }
        if AppConfiguration.isNHLProviderEnabled {
            providers.insert(NHLProvider(), at: 0)
        }
        // Multi-source news providers — always registered; health monitor gates individual usage.
        providers.append(FOXBifrostNewsProvider())
        providers.append(CBSRSSNewsProvider())
        providers.append(BBCSportNewsProvider())
        providers.append(SkySportsNewsProvider())
        providers.append(NBCSportsNewsProvider())
        providers.append(FOXRSSNewsProvider())
        providers.append(BleacherReportNewsProvider())
        return SportsProviderRegistry(providers: providers)
    }
}

struct SportsProviderRouter: Sendable {
    let registry: SportsProviderRegistry
    let routeConfiguration: SportsProviderRouteConfiguration
    let healthMonitor: ProviderHealthMonitor
    let routeOverrides: SportsProviderRouteOverrideStore

    init(
        registry: SportsProviderRegistry = .production(),
        routeConfiguration: SportsProviderRouteConfiguration = .firstPass,
        healthMonitor: ProviderHealthMonitor = ProviderHealthMonitor(),
        routeOverrides: SportsProviderRouteOverrideStore = .shared
    ) {
        self.registry = registry
        self.routeConfiguration = routeConfiguration
        self.healthMonitor = healthMonitor
        self.routeOverrides = routeOverrides
    }

    func providers<T>(for league: League, capability: SportsDataCapability, as type: T.Type) async -> [T] {
        var output: [T] = []
        for providerID in routeConfiguration.providers(for: league, capability: capability) {
            guard let provider = registry.provider(id: providerID),
                  provider.metadata.isEnabled,
                  provider.metadata.capabilities.contains(capability),
                  provider.metadata.supportedLeagues.contains(league.bannerKey) || provider.metadata.supportedLeagues.contains(league.path) || provider.metadata.supportedLeagues.contains("*"),
                  await routeOverrides.isProviderEnabled(providerID, leagueID: league.bannerKey, capability: capability),
                  await healthMonitor.isAvailable(provider.metadata),
                  let typed = provider as? T else {
                continue
            }
            output.append(typed)
        }
        return output
    }

    func providerMetadata() -> [SportsDataProviderMetadata] {
        registry.metadata()
    }

    func routeProviderIDs(for league: League, capability: SportsDataCapability) -> [SportsDataProviderID] {
        routeConfiguration.providers(for: league, capability: capability)
    }
}

struct SportsProviderDiagnostics: Sendable {
    let capability: SportsDataCapability
    let league: League
    let primaryProvider: SportsDataProviderID?
    let currentProvider: SportsDataProviderID?
    let latency: TimeInterval?
    let cacheHit: Bool
    let cacheAge: TimeInterval?
    let fallbacksAttempted: [SportsDataProviderID]
    let providerHealth: SportsProviderHealthSnapshot?
    let failureDescriptions: [String]
}

actor SportsDiagnosticsStore {
    static let shared = SportsDiagnosticsStore()
    private var entries: [String: SportsProviderDiagnostics] = [:]

    func record(_ diagnostics: SportsProviderDiagnostics) {
        entries["\(diagnostics.league.bannerKey)-\(diagnostics.capability.rawValue)"] = diagnostics
    }

    func all() -> [SportsProviderDiagnostics] {
        Array(entries.values)
    }
}

// MARK: - Repository facade

struct SportsLiveMatchSnapshot {
    let live: [Match]
    let startingSoon: [Match]
    let next: [Match]
    let failures: [String]
    /// Games that started today (date <= now) but still have state == .pre — may be live
    /// but the provider hasn't reported it yet. Included so callers can surface them.
    let pastStartToday: [Match]
}

private struct SportsLiveLeagueLoadResult {
    let leagueID: String
    let live: [Match]
    let scheduled: [Match]
    let failures: [String]
}

struct SportsRepository: Sendable {
    static let shared = SportsRepository()

    private let router: SportsProviderRouter
    private let cache: SportsDataCache
    private let scoreDeduplicator = SportsRequestDeduplicator<String, [BannerGame]>()
    private let scheduleDeduplicator = SportsRequestDeduplicator<String, BannerSchedule>()
    private let gameDetailsDeduplicator = SportsRequestDeduplicator<String, BannerGame>()
    private let boxScoreDeduplicator = SportsRequestDeduplicator<String, BannerBoxScore>()
    private let playByPlayDeduplicator = SportsRequestDeduplicator<String, BannerPlayByPlay>()
    private let golfTournamentDeduplicator = SportsRequestDeduplicator<String, BannerGolfTournament>()

    init(router: SportsProviderRouter = SportsProviderRouter(), cache: SportsDataCache = SportsDataCache()) {
        self.router = router
        self.cache = cache
    }

    func providerMetadata() -> [SportsDataProviderMetadata] {
        router.providerMetadata()
    }

    func routeProviderIDs(for league: League, capability: SportsDataCapability) -> [SportsDataProviderID] {
        router.routeProviderIDs(for: league, capability: capability)
    }

    func providerHealthSnapshot(for providerID: SportsDataProviderID) async -> SportsProviderHealthSnapshot {
        await router.healthMonitor.snapshot(for: providerID)
    }

    func routeOverrides() async -> [SportsProviderRouteOverride] {
        await router.routeOverrides.all()
    }

    func setProvider(_ providerID: SportsDataProviderID, enabled: Bool, league: League, capability: SportsDataCapability) async {
        await router.routeOverrides.setProvider(providerID, enabled: enabled, leagueID: league.bannerKey, capability: capability)
    }

    func clearRouteOverrides() async {
        await router.routeOverrides.removeAll()
    }

    func clearCache() async {
        await cache.removeAll()
    }

    func liveScores(for league: League) async throws -> [BannerGame] {
        let key = cacheKey(league: league, capability: .liveScores, scope: "today")
        if let cached: [BannerGame] = await cache.value(for: key) {
            // Bypass stale cache: if any game started >10 min ago but still shows as scheduled,
            // the cached state is outdated and we must fetch fresh data.
            let now = Date()
            let hasStaleScheduled = cached.contains { game in
                game.status == .scheduled &&
                now.timeIntervalSince(game.scheduledStart) > 600 &&
                Calendar.current.isDate(game.scheduledStart, inSameDayAs: now)
            }
            if !hasStaleScheduled {
                await recordDiagnostics(league: league, capability: .liveScores, currentProvider: cached.first?.provenance.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
                return cached
            }
            // Remove stale entry so the deduplicator will issue a fresh request
            await cache.remove(for: key)
#if DEBUG
            print("[LiveScores] Bypassing stale cache for \(league.shortName) — games past start still showing scheduled")
#endif
        }
        return try await scoreDeduplicator.value(for: key.rawValue) {
            try await requestScores(for: league, key: key)
        }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> BannerSchedule {
        let cacheRange = scheduleCacheRange(for: range)
        let key = cacheKey(league: league, capability: .schedule, scope: scheduleCacheScope(for: cacheRange))
        if let cached: BannerSchedule = await cache.value(for: key) {
            // Bypass stale cache: schedule TTL for non-live data is 60 minutes. If a game
            // started >10 min ago but the cached schedule still shows it as scheduled, the
            // 60-minute cache is serving obsolete state and must be discarded.
            let now = Date()
            let exactSchedule = filterSchedule(cached, to: range, league: league)
            let hasStaleScheduled = exactSchedule.games.contains { game in
                game.status == .scheduled &&
                now.timeIntervalSince(game.scheduledStart) > 600 &&
                Calendar.current.isDate(game.scheduledStart, inSameDayAs: now)
            }
            if !hasStaleScheduled {
                await recordDiagnostics(league: league, capability: .schedule, currentProvider: cached.provenance.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
                return exactSchedule
            }
            await cache.remove(for: key)
#if DEBUG
            print("[Schedule] Bypassing stale cache for \(league.shortName) - past-start game still scheduled")
#endif
        }
        let schedule = try await scheduleDeduplicator.value(for: key.rawValue) {
            try await requestSchedule(for: league, range: cacheRange, key: key)
        }
        return filterSchedule(schedule, to: range, league: league)
    }

    func gameDetails(for league: League, gameID: BannerEntityID) async throws -> BannerGame {
        let key = cacheKey(league: league, capability: .gameDetails, scope: gameID.rawValue)
        if let cached: BannerGame = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .gameDetails, currentProvider: cached.provenance.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        return try await gameDetailsDeduplicator.value(for: key.rawValue) {
            try await requestGameDetails(for: league, gameID: gameID, key: key)
        }
    }

    func boxScore(for league: League, gameID: BannerEntityID) async throws -> BannerBoxScore {
        let key = cacheKey(league: league, capability: .boxScore, scope: gameID.rawValue)
        if let cached: BannerBoxScore = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .boxScore, currentProvider: cached.provenance.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        return try await boxScoreDeduplicator.value(for: key.rawValue) {
            try await requestBoxScore(for: league, gameID: gameID, key: key)
        }
    }

    func playByPlay(for league: League, gameID: BannerEntityID) async throws -> BannerPlayByPlay {
        let key = cacheKey(league: league, capability: .playByPlay, scope: gameID.rawValue)
        if let cached: BannerPlayByPlay = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .playByPlay, currentProvider: cached.provenance.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        return try await playByPlayDeduplicator.value(for: key.rawValue) {
            try await requestPlayByPlay(for: league, gameID: gameID, key: key)
        }
    }

    func golfTournament(for league: League, gameID: BannerEntityID) async throws -> BannerGolfTournament {
        let key = cacheKey(league: league, capability: .golfTournament, scope: gameID.rawValue)
        if let cached: BannerGolfTournament = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .golfTournament, currentProvider: cached.provenance.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        return try await golfTournamentDeduplicator.value(for: key.rawValue) {
            try await requestGolfTournament(for: league, gameID: gameID, key: key)
        }
    }

    private func loadLiveSnapshot(league: League, scheduleRange: SportsDateRange) async -> SportsLiveLeagueLoadResult {
        async let liveFetch = liveScores(for: league)
        async let scheduleFetch = schedule(for: league, range: scheduleRange)

        var leagueFailures: [String] = []

        let rawLive: [BannerGame]
        do {
            rawLive = try await liveFetch
        } catch {
            leagueFailures.append("\(league.shortName) live: \(error.localizedDescription)")
            rawLive = []
        }

        let rawScheduled: [BannerGame]
        do {
            rawScheduled = try await scheduleFetch.games
        } catch {
            leagueFailures.append("\(league.shortName) schedule: \(error.localizedDescription)")
            rawScheduled = []
        }

        let (leagueLive, leagueScheduled) = await MainActor.run {
            (rawLive.map { $0.toLegacyMatch(league: league) },
             rawScheduled.map { $0.toLegacyMatch(league: league) })
        }

        return SportsLiveLeagueLoadResult(
            leagueID: league.bannerKey,
            live: leagueLive,
            scheduled: leagueScheduled,
            failures: leagueFailures
        )
    }

    func liveMatchSnapshot(leagues: [League], startingSoonWindow: TimeInterval = 4 * 3600, nextLimit: Int = 12) async -> SportsLiveMatchSnapshot {
        var seenLeagueIDs: Set<String> = []
        let uniqueLeagues = leagues.filter { seenLeagueIDs.insert($0.bannerKey).inserted }
        let now = Date()
        let soonEnd = now.addingTimeInterval(max(60, startingSoonWindow))
        let scheduleRange = SportsDateRange.dateRange(start: Calendar.current.startOfDay(for: now), end: soonEnd)
        var live: [Match] = []
        var scheduled: [Match] = []
        var failures: [String] = []

        await withTaskGroup(of: SportsLiveLeagueLoadResult.self) { group in
            let maxConcurrentLoads = 4
            var nextLeagueIndex = 0

            func enqueueNextLeague() {
                guard nextLeagueIndex < uniqueLeagues.count else { return }
                let league = uniqueLeagues[nextLeagueIndex]
                nextLeagueIndex += 1
                group.addTask {
                    await loadLiveSnapshot(league: league, scheduleRange: scheduleRange)
                }
            }

            for _ in 0..<min(maxConcurrentLoads, uniqueLeagues.count) {
                enqueueNextLeague()
            }

            while let result = await group.next() {
                live.append(contentsOf: result.live)
                scheduled.append(contentsOf: result.scheduled)
                failures.append(contentsOf: result.failures)
                enqueueNextLeague()
            }
        }

        let merged = mergeLiveAggregationMatches(live + scheduled)
        let liveMatches = merged
            .filter { isLiveAggregationMatch($0, now: now) }
            .sorted { liveAggregationSortKey($0, now: now) > liveAggregationSortKey($1, now: now) }
        let startingSoon = merged
            .filter { $0.state == .pre && $0.date > now && $0.date <= soonEnd }
            .sorted { $0.date < $1.date }
        let next = merged
            .filter { $0.state == .pre && $0.date > now }
            .sorted { $0.date < $1.date }
            .prefix(nextLimit)
            .map { $0 }
        // Games that started today but provider still reports as scheduled — the stale-cache
        // bypass above should cause a fresh fetch that corrects this, but include them here
        // so callers can surface them (e.g. featured event matching) even before the next fetch.
        let liveIDs = Set(liveMatches.map(\.id))
        let dayStart = Calendar.current.startOfDay(for: now)
        let pastStartToday = merged.filter {
            !liveIDs.contains($0.id) &&
            $0.state == .pre &&
            $0.date > dayStart &&
            $0.date <= now
        }

        return SportsLiveMatchSnapshot(
            live: liveMatches,
            startingSoon: startingSoon,
            next: next,
            failures: failures,
            pastStartToday: pastStartToday
        )
    }

    func legacyGameSummary(for match: Match) async throws -> GameSummary {
        if let summary = try? await normalizedGameSummary(for: match), !summary.isEmpty {
            return summary
        }
        let espn = ESPNService()
        if let summary = try? await espn.gameSummary(for: match.league, eventID: match.id) {
            return summary
        }
        if let espnEventID = try? await resolveESPNSummaryEventID(for: match, service: espn), espnEventID != match.id {
            return try await espn.gameSummary(for: match.league, eventID: espnEventID)
        }
        return try await espn.gameSummary(for: match.league, eventID: match.id)
    }

    func teams(for league: League) async throws -> [BannerTeam] {
        let key = cacheKey(league: league, capability: .teams, scope: "all")
        if let cached: [BannerTeam] = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .teams, currentProvider: cached.first?.provenance?.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        let providers = await router.providers(for: league, capability: .teams, as: (any TeamProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.teams, league.path) }
        var fallbacks: [SportsDataProviderID] = []
        var failures: [String] = []
        for provider in providers {
            let start = Date()
            do {
                let teams = try await provider.teams(for: league)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(teams, for: key, ttl: SportsDataCache.defaultTTL(for: .teams))
                await recordDiagnostics(league: league, capability: .teams, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return teams
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    func newsMetadata(for league: League, limit: Int = 10, page: Int = 1) async throws -> [BannerNewsArticle] {
        let key = cacheKey(league: league, capability: .newsMetadata, scope: "limit-\(limit)-page-\(page)")
        if let cached: [BannerNewsArticle] = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .newsMetadata, currentProvider: cached.first?.provenance?.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        let allProviders = await router.providers(for: league, capability: .newsMetadata, as: (any SportsNewsProvider).self)
        let providers = page > 1 ? allProviders.filter(\.supportsPagination) : allProviders
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.newsMetadata, league.path) }

        // Run all providers concurrently; aggregate, deduplicate, and rank results.
        let start = Date()
        var collected: [(SportsDataProviderID, [BannerNewsArticle])] = []
        var failures: [String] = []
        await withTaskGroup(of: (SportsDataProviderID, [BannerNewsArticle], Error?).self) { group in
            for provider in providers {
                group.addTask {
                    let t = Date()
                    do {
                        let articles = try await provider.newsMetadata(for: league, limit: limit, page: page)
                        await self.router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: Date().timeIntervalSince(t))
                        return (provider.metadata.id, articles, nil)
                    } catch {
                        await self.router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                        return (provider.metadata.id, [], error)
                    }
                }
            }
            for await (providerID, articles, error) in group {
                if let error {
                    failures.append("\(providerID.rawValue): \(error.localizedDescription)")
                } else if !articles.isEmpty {
                    collected.append((providerID, articles))
                }
            }
        }

        guard !collected.isEmpty else { throw SportsDataError.unavailable }

        let merged = BannerNewsDeduplicator.mergeAndRank(collected, league: league, limit: limit * 3)
        let latency = Date().timeIntervalSince(start)
        await cache.store(merged, for: key, ttl: SportsDataCache.defaultTTL(for: .newsMetadata))
        await recordDiagnostics(league: league, capability: .newsMetadata, currentProvider: collected.first?.0, latency: latency, cacheHit: false, fallbacks: [], failures: failures)
        return merged
    }

    func roster(for league: League, teamID: BannerEntityID) async throws -> BannerRoster {
        let key = cacheKey(league: league, capability: .rosters, scope: teamID.rawValue)
        if let cached: BannerRoster = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .rosters, currentProvider: cached.provenance.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        let providers = await router.providers(for: league, capability: .rosters, as: (any RosterProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.rosters, league.path) }
        var fallbacks: [SportsDataProviderID] = []
        var failures: [String] = []
        for provider in providers {
            let start = Date()
            do {
                let roster = try await provider.roster(for: league, teamID: teamID)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(roster, for: key, ttl: SportsDataCache.defaultTTL(for: .rosters))
                await recordDiagnostics(league: league, capability: .rosters, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return roster
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    func standings(for league: League) async throws -> [BannerStandingGroup] {
        let key = cacheKey(league: league, capability: .standings, scope: "current")
        if let cached: [BannerStandingGroup] = await cache.value(for: key) {
            let provider = cached.first?.standings.first?.provenance?.provider
            await recordDiagnostics(league: league, capability: .standings, currentProvider: provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        let providers = await router.providers(for: league, capability: .standings, as: (any StandingsProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.standings, league.path) }
        var fallbacks: [SportsDataProviderID] = []
        var failures: [String] = []
        for provider in providers {
            let start = Date()
            do {
                let groups = try await provider.standings(for: league)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(groups, for: key, ttl: SportsDataCache.defaultTTL(for: .standings))
                await recordDiagnostics(league: league, capability: .standings, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return groups
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    func injuries(for league: League) async throws -> [BannerInjury] {
        let key = cacheKey(league: league, capability: .injuries, scope: "current")
        if let cached: [BannerInjury] = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .injuries, currentProvider: cached.first?.provenance?.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        let providers = await router.providers(for: league, capability: .injuries, as: (any InjuryProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.injuries, league.path) }
        var fallbacks: [SportsDataProviderID] = []
        var failures: [String] = []
        for provider in providers {
            let start = Date()
            do {
                let injuries = try await provider.injuries(for: league)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(injuries, for: key, ttl: SportsDataCache.defaultTTL(for: .injuries))
                await recordDiagnostics(league: league, capability: .injuries, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return injuries
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    func leaders(for league: League) async throws -> [BannerLeader] {
        let key = cacheKey(league: league, capability: .leagueLeaders, scope: "current")
        if let cached: [BannerLeader] = await cache.value(for: key) {
            await recordDiagnostics(league: league, capability: .leagueLeaders, currentProvider: cached.first?.provenance?.provider, latency: nil, cacheHit: true, cacheAge: await cache.age(for: key), fallbacks: [], failures: [])
            return cached
        }
        let providers = await router.providers(for: league, capability: .leagueLeaders, as: (any LeagueLeaderProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.leagueLeaders, league.path) }
        var fallbacks: [SportsDataProviderID] = []
        var failures: [String] = []
        for provider in providers {
            let start = Date()
            do {
                let boards = try await provider.leaders(for: league)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(boards, for: key, ttl: SportsDataCache.defaultTTL(for: .leagueLeaders))
                await recordDiagnostics(league: league, capability: .leagueLeaders, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return boards
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    func legacyTeams(for league: League) async throws -> [Team] {
        try await teams(for: league).map { $0.toLegacyTeam() }
    }

    func legacyStandings(for league: League) async throws -> [StandingsGroup] {
        try await standings(for: league).map { $0.toLegacyStandingsGroup() }
    }

    func legacyLeaders(for league: League) async throws -> [LeaderBoard] {
        try await leaders(for: league).map { $0.toLegacyLeaderBoard() }
    }

    func legacyInjuries(for league: League) async throws -> [LeagueInjury] {
        try await injuries(for: league).map { $0.toLegacyLeagueInjury() }
    }

    func legacyAthleteOverview(for league: League, athleteID: String) async throws -> AthleteOverview {
        try await ESPNService().athleteOverview(for: league, athleteID: athleteID)
    }

    func playerStats(for league: League, playerIDs: Set<BannerEntityID>, range: SportsDateRange?) async throws -> [BannerPlayerStat] {
        let scopeKey = playerIDs.map(\.rawValue).sorted().joined(separator: ",")
        let key = cacheKey(league: league, capability: .playerStats, scope: scopeKey)
        if let cached: [BannerPlayerStat] = await cache.value(for: key) { return cached }
        let providers = await router.providers(for: league, capability: .playerStats, as: (any PlayerStatsProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.playerStats, league.path) }
        var fallbacks: [SportsDataProviderID] = []
        var failures: [String] = []
        for provider in providers {
            let start = Date()
            do {
                let stats = try await provider.playerStats(for: league, playerIDs: playerIDs, range: range)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(stats, for: key, ttl: SportsDataCache.defaultTTL(for: .playerStats))
                await recordDiagnostics(league: league, capability: .playerStats, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return stats
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    func legacyRacers(for league: League) async throws -> [Racer] {
        try await ESPNService().racers(for: league)
    }

    func legacyArticleBody(from url: URL) async throws -> [String] {
        try await ESPNService().articleBodyFromURL(url)
    }

    func legacyRoster(for league: League, teamID: String) async throws -> [RosterGroup] {
        let canonicalTeamID = legacyCanonicalTeamID(league: league, teamID: teamID)
        let roster = try await roster(for: league, teamID: canonicalTeamID)
        let grouped = Dictionary(grouping: roster.players) { $0.position ?? "Roster" }
        return grouped.keys.sorted().map { key in
            RosterGroup(
                id: key,
                title: key,
                athletes: (grouped[key] ?? []).map { $0.toLegacyRosterAthlete() }.sorted { $0.displayName < $1.displayName }
            )
        }
    }

    func legacyNews(for league: League, limit: Int = 10, page: Int = 1) async throws -> [ESPNArticle] {
        try await newsMetadata(for: league, limit: limit, page: page).map { $0.toLegacyArticle(league: league) }
    }

    func legacyScoreboard(for league: League, on date: Date? = nil) async throws -> [Match] {
        if let date {
            let start = Calendar.current.startOfDay(for: date)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) ?? date
            let range = SportsDateRange.dateRange(start: start, end: end)
            return try await schedule(for: league, range: range).games.map { $0.toLegacyMatch(league: league) }
        }
        return try await liveScores(for: league).map { $0.toLegacyMatch(league: league) }
    }

    func legacyScoreboards(for league: League, starting startDate: Date, days: Int) async throws -> [Match] {
        try await schedule(for: league, range: .next(days: days, now: startDate)).games.map { $0.toLegacyMatch(league: league) }
    }

    func enrichedLegacyMatch(_ match: Match) async -> Match {
        let gameID = canonicalGameID(for: match)
        let shouldLoadLiveSupplements = match.state == .live || match.state == .final

        async let detailResult: BannerGame? = try? gameDetails(for: match.league, gameID: gameID)
        async let boxScoreResult: BannerBoxScore? = shouldLoadLiveSupplements ? (try? boxScore(for: match.league, gameID: gameID)) : nil
        async let playByPlayResult: BannerPlayByPlay? = shouldLoadLiveSupplements ? (try? playByPlay(for: match.league, gameID: gameID)) : nil

        let detail = await detailResult
        let boxScore = await boxScoreResult
        let playByPlay = await playByPlayResult

        let base = detail?.toLegacyMatch(league: match.league) ?? match
        return base.withLiveContext(
            MatchLiveContext(
                clock: detail?.clock.map(MatchClock.init),
                period: detail?.period.map(MatchPeriod.init),
                baseball: MatchLiveContextMapper.baseball(from: detail, match: base),
                hockey: MatchLiveContextMapper.hockey(from: detail, match: base),
                football: MatchLiveContextMapper.football(from: detail, match: base),
                soccer: MatchLiveContextMapper.soccer(from: detail, match: base, plays: playByPlay?.plays ?? []),
                basketball: MatchLiveContextMapper.basketball(from: detail, match: base),
                teamStats: boxScore?.teamStats.map { MatchTeamStats(banner: $0, match: base) } ?? [],
                leaders: MatchLiveContextMapper.gameLeaders(from: boxScore, match: base),
                playByPlay: playByPlay?.plays.map(MatchPlay.init) ?? [],
                boxScore: boxScore.map(MatchBoxScore.init),
                formations: [],
                drives: MatchLiveContextMapper.drives(from: playByPlay?.plays ?? [], match: base),
                sportsDataDelay: nil
            )
        )
    }

    private func legacyCanonicalTeamID(league: League, teamID: String) -> BannerEntityID {
        if teamID.hasPrefix("team:") { return BannerEntityID(rawValue: teamID) }
        if teamID.hasPrefix("umc.") {
            return BannerEntityID(rawValue: "team:\(league.bannerKey):appleSports:\(teamID)")
        }
        if league.path == "hockey/nhl", teamID.rangeOfCharacter(from: .decimalDigits) == nil {
            return BannerEntityID(rawValue: "team:\(league.bannerKey):nhl:\(teamID)")
        }
        return BannerEntityID(rawValue: "team:\(league.bannerKey):espn:\(teamID)")
    }

    private func canonicalGameID(for match: Match) -> BannerEntityID {
        if let canonical = match.canonicalID {
            return BannerEntityID(rawValue: canonical)
        }
        if match.id.hasPrefix("game:") {
            return BannerEntityID(rawValue: match.id)
        }
        let provider = providerID(for: match.league)
        if provider != .espn {
            return BannerEntityID(rawValue: "game:\(match.league.bannerKey):\(provider.rawValue):\(match.id)")
        }
        guard let homeID = match.home.canonicalIDString.map(BannerEntityID.init(rawValue:)),
              let awayID = match.away.canonicalIDString.map(BannerEntityID.init(rawValue:)) else {
            return BannerEntityID(rawValue: match.id)
        }
        return SportsIdentityResolver().canonicalGameID(
            league: match.league,
            provider: provider,
            providerGameID: match.id,
            home: BannerTeam(id: homeID, leagueID: SportsIdentityResolver.canonicalLeagueID(for: match.league), displayName: match.home.displayName, shortName: match.home.shortName, abbreviation: match.home.abbreviation, logoURL: match.home.logoURL, aliases: [], provenance: nil),
            away: BannerTeam(id: awayID, leagueID: SportsIdentityResolver.canonicalLeagueID(for: match.league), displayName: match.away.displayName, shortName: match.away.shortName, abbreviation: match.away.abbreviation, logoURL: match.away.logoURL, aliases: [], provenance: nil),
            scheduledStart: match.date
        )
    }

    private func providerID(for league: League) -> SportsDataProviderID {
        switch league.path {
        case "baseball/mlb": return .mlb
        case "hockey/nhl": return .nhl
        case "basketball/nba": return .nba
        case "football/nfl": return .nfl
        default: return .espn
        }
    }

    private func mergeLiveAggregationMatches(_ matches: [Match]) -> [Match] {
        let now = Date()
        var byKey: [String: Match] = [:]
        // Track all broadcasts seen per key so the winning entry never silently loses them.
        var broadcastsByKey: [String: [String]] = [:]
        for match in matches {
            let key = liveAggregationKey(for: match)
            // Accumulate broadcasts from every provider for this game.
            if !match.broadcasts.isEmpty {
                var existing = broadcastsByKey[key, default: []]
                for b in match.broadcasts where !existing.contains(b) { existing.append(b) }
                broadcastsByKey[key] = existing
            }
            if let current = byKey[key] {
                if liveAggregationSortKey(match, now: now) > liveAggregationSortKey(current, now: now) {
                    byKey[key] = match
                }
            } else {
                byKey[key] = match
            }
        }
        // Hydrate broadcasts onto the winner if it came from a source that omits them.
        return byKey.map { key, match in
            guard let allBroadcasts = broadcastsByKey[key], !allBroadcasts.isEmpty, match.broadcasts.isEmpty else {
                return match
            }
            return match.withBroadcasts(allBroadcasts)
        }
    }

    private func isLiveAggregationMatch(_ match: Match, now: Date) -> Bool {
        guard match.state != .final else { return false }
        if match.state == .live { return true }
        guard Calendar.current.isDate(match.date, inSameDayAs: now), match.hasDisplayScore else { return false }
        let detail = match.statusDetail.lowercased()
        return detail.contains("live")
            || detail.contains("in progress")
            || detail.contains("halftime")
            || detail == "ht"
            || detail.contains("quarter")
            || detail.contains("period")
            || detail.contains("inning")
            || detail.contains("top ")
            || detail.contains("bot ")
            || detail.contains("bottom")
            || detail.contains("round")
            || detail.contains("set")
            || detail.contains("deuce")
            || detail.contains("game")
    }

    private func liveAggregationKey(for match: Match) -> String {
        let calendar = Calendar.current
        let day = Int(calendar.startOfDay(for: match.date).timeIntervalSince1970)
        switch match.league.group {
        case .golf, .racing:
            let eventName = SportsIdentityResolver.slug(match.name.isEmpty ? match.league.name : match.name)
            return "\(match.league.bannerKey):\(day):\(eventName)"
        default:
            let participants = [match.away, match.home]
                .map { side in
                    if let canonicalID = side.canonicalIDString { return canonicalID }
                    if let teamID = side.teamID { return teamID }
                    if !side.abbreviation.isEmpty { return side.abbreviation }
                    return side.shortName
                }
                .map { SportsIdentityResolver.slug($0) }
                .filter { !$0.isEmpty && $0 != "tbd" && $0 != "field" }
                .sorted()
                .joined(separator: ":")
            if !participants.isEmpty {
                let halfHourBucket = Int(match.date.timeIntervalSince1970 / 1800)
                return "\(match.league.bannerKey):\(halfHourBucket):\(participants)"
            }
            return "\(match.league.bannerKey):\(day):\(SportsIdentityResolver.slug(match.name)):\(match.id)"
        }
    }

    private func liveAggregationSortKey(_ match: Match, now: Date) -> Int {
        var score = 0
        if match.state == .live { score += 10_000 }
        if match.hasDisplayScore { score += 1_000 }
        if !match.broadcasts.isEmpty { score += 500 }
        if match.away.displayName != "TBD" && match.home.displayName != "TBD" { score += 100 }
        score -= max(0, Int(abs(match.date.timeIntervalSince(now)) / 60))
        return score
    }

    private func scheduleCacheRange(for range: SportsDateRange, calendar: Calendar = .current) -> SportsDateRange {
        let start = calendar.startOfDay(for: range.start)
        let endDayStart = calendar.startOfDay(for: range.end)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endDayStart) ?? range.end
        return SportsDateRange.dateRange(start: start, end: end)
    }

    private func scheduleCacheScope(for range: SportsDateRange) -> String {
        "days-\(Int(range.start.timeIntervalSince1970))-\(Int(range.end.timeIntervalSince1970))"
    }

    private func filterSchedule(_ schedule: BannerSchedule, to range: SportsDateRange, league: League) -> BannerSchedule {
        let games = schedule.games.filter { game in
            game.scheduledStart >= range.start && game.scheduledStart <= range.end
        }
        return BannerSchedule(
            id: BannerEntityID(rawValue: "schedule:\(league.bannerKey):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
            leagueID: schedule.leagueID,
            range: range,
            games: games,
            provenance: schedule.provenance
        )
    }

    private func cacheKey(league: League, capability: SportsDataCapability, scope: String) -> SportsCacheKey {
        SportsCacheKey(providerID: router.routeConfiguration.providers(for: league, capability: capability).first ?? .espn, leagueID: league.bannerKey, capability: capability, scope: scope)
    }

    private func requestScores(for league: League, key: SportsCacheKey) async throws -> [BannerGame] {
        let providers = await router.providers(for: league, capability: .liveScores, as: (any ScoreProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.liveScores, league.path) }
        var failures: [String] = []
        var fallbacks: [SportsDataProviderID] = []
        for provider in providers {
            let start = Date()
            do {
                let games = try await provider.liveScores(for: league)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(games, for: key, ttl: SportsDataCache.defaultTTL(for: .liveScores, containsLiveGames: games.contains { $0.status == .live }))
                await recordDiagnostics(league: league, capability: .liveScores, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return games
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    private func requestGameDetails(for league: League, gameID: BannerEntityID, key: SportsCacheKey) async throws -> BannerGame {
        let providers = await router.providers(for: league, capability: .gameDetails, as: (any GameDetailsProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.gameDetails, league.path) }
        var failures: [String] = []
        var fallbacks: [SportsDataProviderID] = []
        for provider in providers {
            let start = Date()
            do {
                let game = try await provider.gameDetails(for: league, gameID: gameID)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(game, for: key, ttl: SportsDataCache.defaultTTL(for: .gameDetails, containsLiveGames: game.status == .live))
                await recordDiagnostics(league: league, capability: .gameDetails, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return game
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    private func requestBoxScore(for league: League, gameID: BannerEntityID, key: SportsCacheKey) async throws -> BannerBoxScore {
        let providers = await router.providers(for: league, capability: .boxScore, as: (any BoxScoreProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.boxScore, league.path) }
        var failures: [String] = []
        var fallbacks: [SportsDataProviderID] = []
        for provider in providers {
            let start = Date()
            do {
                let boxScore = try await provider.boxScore(for: league, gameID: gameID)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(boxScore, for: key, ttl: SportsDataCache.defaultTTL(for: .boxScore))
                await recordDiagnostics(league: league, capability: .boxScore, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return boxScore
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    private func requestPlayByPlay(for league: League, gameID: BannerEntityID, key: SportsCacheKey) async throws -> BannerPlayByPlay {
        let providers = await router.providers(for: league, capability: .playByPlay, as: (any PlayByPlayProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.playByPlay, league.path) }
        var failures: [String] = []
        var fallbacks: [SportsDataProviderID] = []
        for provider in providers {
            let start = Date()
            do {
                let playByPlay = try await provider.playByPlay(for: league, gameID: gameID)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(playByPlay, for: key, ttl: SportsDataCache.defaultTTL(for: .playByPlay))
                await recordDiagnostics(league: league, capability: .playByPlay, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return playByPlay
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    private func requestGolfTournament(for league: League, gameID: BannerEntityID, key: SportsCacheKey) async throws -> BannerGolfTournament {
        guard league.group == .golf else { throw SportsDataError.unsupportedCapability(.golfTournament) }
        let providers = await router.providers(for: league, capability: .golfTournament, as: (any GolfTournamentProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.golfTournament, league.path) }
        var failures: [String] = []
        var fallbacks: [SportsDataProviderID] = []
        for provider in providers {
            let start = Date()
            do {
                let tournament = try await provider.golfTournament(for: league, gameID: gameID)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(tournament, for: key, ttl: SportsDataCache.defaultTTL(for: .golfTournament, containsLiveGames: tournament.status == .live))
                await recordDiagnostics(league: league, capability: .golfTournament, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return tournament
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    private func normalizedGameSummary(for match: Match) async throws -> GameSummary {
        let gameID = BannerEntityID(rawValue: match.id)
        async let boxScoreResult = optionalBoxScore(for: match.league, gameID: gameID)
        async let playByPlayResult = optionalPlayByPlay(for: match.league, gameID: gameID)
        let boxScore = await boxScoreResult
        let playByPlay = await playByPlayResult
        let teams = boxScore?.teamStats.map { teamBox(stat: $0, match: match) } ?? []
        let plays = playByPlay?.plays.map { play in
            PlayByPlayEntry(
                id: play.id.rawValue,
                clock: play.clock?.displayValue,
                period: play.period?.displayName,
                periodNumber: play.period?.number,
                text: play.text,
                teamAbbreviation: nil,
                awayScore: play.awayScore,
                homeScore: play.homeScore,
                isScoringPlay: play.isScoringPlay
            )
        } ?? []
        return GameSummary(teams: teams, leaders: [], plays: plays, headToHead: nil, highlights: [])
    }

    private func optionalBoxScore(for league: League, gameID: BannerEntityID) async -> BannerBoxScore? {
        try? await boxScore(for: league, gameID: gameID)
    }

    private func optionalPlayByPlay(for league: League, gameID: BannerEntityID) async -> BannerPlayByPlay? {
        try? await playByPlay(for: league, gameID: gameID)
    }

    private func resolveESPNSummaryEventID(for match: Match, service: ESPNService) async throws -> String? {
        let sameDayMatches = try await service.scoreboard(for: match.league, on: match.date)
        let calendar = Calendar.current
        let awayTokens = legacyMatchTokens(match.away)
        let homeTokens = legacyMatchTokens(match.home)
        return sameDayMatches.first { candidate in
            guard calendar.isDate(candidate.date, inSameDayAs: match.date) else { return false }
            let candidateAway = legacyMatchTokens(candidate.away)
            let candidateHome = legacyMatchTokens(candidate.home)
            let direct = !awayTokens.isDisjoint(with: candidateAway) && !homeTokens.isDisjoint(with: candidateHome)
            let reversed = !awayTokens.isDisjoint(with: candidateHome) && !homeTokens.isDisjoint(with: candidateAway)
            return direct || reversed || candidate.name.localizedCaseInsensitiveContains(match.name) || match.name.localizedCaseInsensitiveContains(candidate.name)
        }?.id
    }

    private func legacyMatchTokens(_ side: TeamSide) -> Set<String> {
        [side.teamID, side.abbreviation, side.shortName, side.displayName]
            .compactMap { $0 }
            .map { SportsIdentityResolver.slug($0) }
            .filter { !$0.isEmpty && $0 != "tbd" && $0 != "field" }
            .reduce(into: Set<String>()) { tokens, token in
                tokens.insert(token)
                token.split(separator: "-").filter { $0.count > 2 }.forEach { tokens.insert(String($0)) }
            }
    }

    private func teamBox(stat: BannerTeamStat, match: Match) -> GameSummary.TeamBox {
        let providerTeamID = SportsIdentityResolver.providerID(from: stat.teamID, provider: .appleSports)
            ?? SportsIdentityResolver.providerID(from: stat.teamID, provider: .nhl)
            ?? SportsIdentityResolver.providerID(from: stat.teamID, provider: .espn)
            ?? SportsIdentityResolver.providerID(from: stat.teamID, provider: .mlb)
            ?? stat.teamID.rawValue
        let canonicalRaw = stat.teamID.rawValue
        let side = [match.away, match.home].first {
            $0.teamID == providerTeamID || $0.canonicalIDString == canonicalRaw
        }
        return GameSummary.TeamBox(
            id: providerTeamID,
            name: side?.displayName ?? stat.teamID.rawValue,
            abbreviation: side?.abbreviation ?? stat.teamID.rawValue,
            stats: stat.stats.map { GameSummary.GameStat(label: $0.displayName, displayValue: $0.value) }
        )
    }

    private func requestSchedule(for league: League, range: SportsDateRange, key: SportsCacheKey) async throws -> BannerSchedule {
        let providers = await router.providers(for: league, capability: .schedule, as: (any ScheduleProvider).self)
        guard !providers.isEmpty else { throw SportsDataError.noProviderAvailable(.schedule, league.path) }
        var failures: [String] = []
        var fallbacks: [SportsDataProviderID] = []
        for provider in providers {
            let start = Date()
            do {
                let schedule = try await provider.schedule(for: league, range: range)
                let latency = Date().timeIntervalSince(start)
                await router.healthMonitor.recordSuccess(providerID: provider.metadata.id, latency: latency)
                await cache.store(schedule, for: key, ttl: SportsDataCache.defaultTTL(for: .schedule, containsLiveGames: schedule.games.contains { $0.status == .live }))
                await recordDiagnostics(league: league, capability: .schedule, currentProvider: provider.metadata.id, latency: latency, cacheHit: false, fallbacks: fallbacks, failures: failures)
                return schedule
            } catch {
                failures.append("\(provider.metadata.name): \(error.localizedDescription)")
                await router.healthMonitor.recordFailure(providerID: provider.metadata.id, error: error)
                fallbacks.append(provider.metadata.id)
            }
        }
        throw SportsDataError.unavailable
    }

    private func recordDiagnostics(league: League, capability: SportsDataCapability, currentProvider: SportsDataProviderID?, latency: TimeInterval?, cacheHit: Bool, cacheAge: TimeInterval? = nil, fallbacks: [SportsDataProviderID], failures: [String]) async {
        let primary = router.routeConfiguration.providers(for: league, capability: capability).first
        let health = currentProvider == nil ? nil : await router.healthMonitor.snapshot(for: currentProvider!)
        await SportsDiagnosticsStore.shared.record(SportsProviderDiagnostics(
            capability: capability,
            league: league,
            primaryProvider: primary,
            currentProvider: currentProvider,
            latency: latency,
            cacheHit: cacheHit,
            cacheAge: cacheAge,
            fallbacksAttempted: fallbacks,
            providerHealth: health,
            failureDescriptions: failures
        ))
    }
}

// MARK: - ESPN adapter

struct ESPNProvider: ScoreProvider, ScheduleProvider, TeamProvider, StandingsProvider, RosterProvider, InjuryProvider, LeagueLeaderProvider, GolfTournamentProvider, SportsNewsProvider {
    let metadata: SportsDataProviderMetadata
    private let service: ESPNService
    private let identityResolver: SportsIdentityResolver

    init(service: ESPNService = ESPNService(), identityResolver: SportsIdentityResolver = SportsIdentityResolver()) {
        self.service = service
        self.identityResolver = identityResolver
        self.metadata = SportsDataProviderMetadata(
            id: .espn,
            name: "ESPN",
            supportLevel: .legacy,
            supportedSports: Set(SportGroup.allCases.filter { $0.hasEspnLeagues }),
            supportedLeagues: Set(League.all.flatMap { [$0.path, $0.bannerKey] }),
            capabilities: [.liveScores, .schedule, .gameStatus, .teams, .standings, .rosters, .injuries, .leagueLeaders, .golfTournament, .newsMetadata],
            authenticationType: .publicWebHeaders,
            isEnabled: true,
            requestTimeout: 10
        )
    }

    func liveScores(for league: League) async throws -> [BannerGame] {
        do {
            return try await service.scoreboard(for: league).map { map(match: $0) }
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    func schedule(for league: League, range: SportsDateRange) async throws -> BannerSchedule {
        do {
            let matches = try await service.scoreboards(for: league, starting: range.start, days: range.dayCount)
            let games = matches.map { map(match: $0) }
            return BannerSchedule(
                id: BannerEntityID(rawValue: "schedule:\(league.bannerKey):\(Int(range.start.timeIntervalSince1970)):\(Int(range.end.timeIntervalSince1970))"),
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                range: range,
                games: games,
                provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: nil, confidence: 0.85)
            )
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    func teams(for league: League) async throws -> [BannerTeam] {
        do {
            return try await service.teams(for: league).map { team in
                BannerTeam(
                    id: identityResolver.canonicalTeamID(league: league, provider: .espn, providerTeamID: team.id, abbreviation: team.abbreviation, displayName: team.displayName),
                    leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                    displayName: team.displayName,
                    shortName: team.shortDisplayName,
                    abbreviation: team.abbreviation,
                    logoURL: team.logoURL,
                    aliases: [ProviderEntityAlias(provider: .espn, id: team.id)],
                    provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: team.id, confidence: 0.9)
                )
            }
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    func standings(for league: League) async throws -> [BannerStandingGroup] {
        do {
            let groups = try await service.standings(for: league)
            return groups.map { group in
                BannerStandingGroup(
                    id: BannerEntityID(rawValue: "standings:\(league.bannerKey):\(SportsIdentityResolver.slug(group.id))"),
                    name: group.name,
                    standings: group.rows.enumerated().map { index, row in
                        let teamID = identityResolver.canonicalTeamID(league: league, provider: .espn, providerTeamID: row.teamID, abbreviation: row.abbreviation, displayName: row.displayName)
                        return BannerStanding(
                            id: BannerEntityID(rawValue: "standing:\(teamID.rawValue)"),
                            teamID: teamID,
                            teamDisplayName: row.displayName,
                            teamAbbreviation: row.abbreviation,
                            teamLogoURL: row.logoURL,
                            groupName: group.name,
                            rank: index + 1,
                            wins: row.wins,
                            losses: row.losses,
                            ties: row.ties,
                            points: row.leaguePoints,
                            gamesPlayed: row.gamesPlayed,
                            displayRecord: row.record,
                            provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: row.teamID, confidence: 0.85)
                        )
                    }
                )
            }
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    func roster(for league: League, teamID: BannerEntityID) async throws -> BannerRoster {
        guard let espnTeamID = SportsIdentityResolver.providerID(from: teamID, provider: .espn) else {
            throw SportsDataError.invalidResponse
        }
        do {
            let groups = try await service.roster(for: league, teamID: espnTeamID)
            let players = groups.flatMap(\.athletes).map { athlete in
                let id = identityResolver.canonicalPlayerID(league: league, provider: .espn, providerPlayerID: athlete.id, fullName: athlete.displayName)
                return BannerPlayer(
                    id: id,
                    leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                    fullName: athlete.displayName,
                    displayName: athlete.displayName,
                    teamID: teamID,
                    teamAbbreviation: nil,
                    position: athlete.position,
                    jerseyNumber: athlete.jersey,
                    birthDate: nil,
                    headshotURL: athlete.headshotURL,
                    aliases: [ProviderEntityAlias(provider: .espn, id: athlete.id)],
                    provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: athlete.id, confidence: 0.85)
                )
            }
            return BannerRoster(
                id: BannerEntityID(rawValue: "roster:\(teamID.rawValue)"),
                teamID: teamID,
                leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                players: players,
                provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: espnTeamID, confidence: 0.85)
            )
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    func injuries(for league: League) async throws -> [BannerInjury] {
        do {
            return try await service.injuries(for: league).map { injury in
                BannerInjury(
                    id: BannerEntityID(rawValue: "injury:\(league.bannerKey):\(SportsIdentityResolver.slug(injury.id))"),
                    playerID: nil,
                    playerName: injury.athleteName,
                    teamID: nil,
                    status: injury.status,
                    detail: injury.detail,
                    provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: injury.id, confidence: 0.75)
                )
            }
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    func leaders(for league: League) async throws -> [BannerLeader] {
        do {
            return try await service.leaders(for: league).map { board in
                BannerLeader(
                    id: BannerEntityID(rawValue: "leader:\(league.bannerKey):\(SportsIdentityResolver.slug(board.id))"),
                    statKey: board.statName,
                    displayName: board.displayName,
                    players: board.rows.map { row in
                        let playerID = identityResolver.canonicalPlayerID(league: league, provider: .espn, providerPlayerID: row.athleteID, fullName: row.displayName, teamAbbreviation: row.teamAbbreviation)
                        return BannerPlayerStat(
                            id: BannerEntityID(rawValue: "leader-row:\(playerID.rawValue):\(SportsIdentityResolver.slug(board.statName))"),
                            playerID: playerID,
                            playerDisplayName: row.displayName,
                            teamAbbreviation: row.teamAbbreviation,
                            headshotURL: row.headshotURL,
                            teamID: nil,
                            seasonID: nil,
                            stats: [BannerStatValue(key: board.statName, displayName: board.displayName, value: row.value)],
                            provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: row.athleteID, confidence: 0.8)
                        )
                    },
                    provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: board.id, confidence: 0.8)
                )
            }
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    func newsMetadata(for league: League, limit: Int, page: Int) async throws -> [BannerNewsArticle] {
        do {
            return try await service.news(for: league, limit: limit, page: page).map { article in
                BannerNewsArticle(
                    id: BannerEntityID(rawValue: "news:espn:\(article.id)"),
                    headline: article.headline,
                    description: article.description,
                    published: article.published,
                    url: article.url,
                    imageURL: article.imageURL,
                    leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
                    teamIDs: [],
                    playerIDs: [],
                    sourceName: article.byline,
                    provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: article.id, confidence: 0.75)
                )
            }
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    func golfTournament(for league: League, gameID: BannerEntityID) async throws -> BannerGolfTournament {
        guard league.group == .golf else { throw SportsDataError.unsupportedCapability(.golfTournament) }
        let providerEventID = SportsIdentityResolver.providerID(from: gameID, provider: .espn) ?? gameID.rawValue
        do {
            return try await service.golfTournament(for: league, eventID: providerEventID, gameID: gameID)
        } catch {
            throw SportsDataError.network(error.localizedDescription)
        }
    }

    private func map(match: Match) -> BannerGame {
        let home = map(side: match.home, league: match.league)
        let away = map(side: match.away, league: match.league)
        let providerEventID = match.id
        return BannerGame(
            id: identityResolver.canonicalGameID(league: match.league, provider: .espn, providerGameID: providerEventID, home: home, away: away, scheduledStart: match.date),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: match.league),
            scheduledStart: match.date,
            name: match.name,
            shortName: match.shortName,
            status: BannerGameStatus(gameState: match.state),
            statusDetail: match.statusDetail,
            homeTeam: home,
            awayTeam: away,
            score: BannerScore(home: match.home.score, away: match.away.score),
            clock: BannerGameClock(displayValue: match.statusDetail, remainingSeconds: nil, isRunning: nil),
            period: nil,
            venue: match.venue.map { BannerVenue(id: nil, name: $0, city: nil, state: nil, country: nil, aliases: []) },
            broadcasts: match.broadcasts.map { BannerBroadcast(network: $0, type: nil, countryCode: nil) },
            aliases: [ProviderEntityAlias(provider: .espn, id: providerEventID)],
            provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: providerEventID, confidence: 0.85)
        )
    }

    private func map(side: TeamSide, league: League) -> BannerTeam {
        BannerTeam(
            id: identityResolver.canonicalTeamID(league: league, provider: .espn, providerTeamID: side.teamID, abbreviation: side.abbreviation, displayName: side.displayName),
            leagueID: SportsIdentityResolver.canonicalLeagueID(for: league),
            displayName: side.displayName,
            shortName: side.shortName,
            abbreviation: side.abbreviation,
            logoURL: side.logoURL,
            aliases: side.teamID.map { [ProviderEntityAlias(provider: .espn, id: $0)] } ?? [],
            provenance: DataProvenance(provider: .espn, fetchedAt: Date(), providerEntityID: side.teamID, confidence: 0.85)
        )
    }
}

extension BannerPlayer {
    func toLegacyRosterAthlete() -> RosterAthlete {
        var athlete = RosterAthlete(
            id: aliases.first { $0.provider == .espn }?.id ?? aliases.first?.id ?? id.rawValue,
            displayName: displayName,
            jersey: jerseyNumber,
            position: position,
            positionName: position,
            headshotURL: headshotURL,
            age: nil,
            displayHeight: nil,
            displayWeight: nil,
            college: nil,
            experienceYears: nil,
            birthPlace: nil,
            isInjured: false
        )
        athlete.canonicalID = id.rawValue
        return athlete
    }
}

extension BannerStandingGroup {
    func toLegacyStandingsGroup() -> StandingsGroup {
        StandingsGroup(id: id.rawValue, name: name, rows: standings.map { $0.toLegacyStandingRow() })
    }
}

extension BannerStanding {
    func toLegacyStandingRow() -> StandingRow {
        StandingRow(
            teamID: SportsIdentityResolver.providerID(from: teamID, provider: .espn)
                ?? SportsIdentityResolver.providerID(from: teamID, provider: .appleSports)
                ?? SportsIdentityResolver.providerID(from: teamID, provider: .nhl)
                ?? SportsIdentityResolver.providerID(from: teamID, provider: .mlb)
                ?? teamID.rawValue,
            displayName: teamDisplayName ?? teamID.rawValue,
            abbreviation: teamAbbreviation ?? "",
            logoURL: teamLogoURL,
            record: displayRecord,
            wins: wins,
            losses: losses,
            ties: ties,
            winPercent: nil,
            gamesBack: nil,
            streak: nil,
            pointsFor: nil,
            pointsAgainst: nil,
            leaguePoints: points,
            gamesPlayed: gamesPlayed,
            goalDiff: nil
        )
    }
}

extension BannerLeader {
    func toLegacyLeaderBoard() -> LeaderBoard {
        LeaderBoard(
            id: id.rawValue,
            statName: statKey,
            displayName: displayName,
            rows: players.enumerated().map { index, row in
                let value = row.stats.first { $0.key == statKey }?.value ?? row.stats.first?.value ?? "--"
                return LeaderRow(
                    rank: index + 1,
                    athleteID: SportsIdentityResolver.providerID(from: row.playerID, provider: .espn)
                        ?? SportsIdentityResolver.providerID(from: row.playerID, provider: .appleSports)
                        ?? SportsIdentityResolver.providerID(from: row.playerID, provider: .mlb)
                        ?? row.playerID.rawValue,
                    displayName: row.playerDisplayName ?? row.playerID.rawValue,
                    teamAbbreviation: row.teamAbbreviation,
                    headshotURL: row.headshotURL,
                    value: value
                )
            }
        )
    }
}

extension BannerInjury {
    func toLegacyLeagueInjury() -> LeagueInjury {
        LeagueInjury(
            id: id.rawValue,
            athleteName: playerName,
            teamAbbreviation: nil,
            position: nil,
            status: status,
            detail: detail,
            headshotURL: nil
        )
    }
}

extension BannerNewsArticle {
    func toLegacyArticle(league: League) -> ESPNArticle {
        // Prefer author byline; fall back to publisher name for attribution.
        let displayByline = authorByline ?? publisher ?? sourceName
        return ESPNArticle(
            id: id.rawValue,
            headline: headline,
            description: description,
            published: published,
            url: url,
            imageURL: imageURL,
            league: league,
            byline: displayByline,
            type: articleType,
            isPremium: false,
            categories: []
        )
    }
}

extension BannerGame {
    func toLegacyMatch(league: League) -> Match {
        var match = Match(
            id: aliases.first { $0.provider == .espn }?.id ?? aliases.first?.id ?? id.rawValue,
            league: league,
            date: scheduledStart,
            name: name,
            shortName: shortName,
            state: status.legacyGameState,
            statusDetail: statusDetail,
            home: homeTeam.toLegacyTeamSide(score: score.home),
            away: awayTeam.toLegacyTeamSide(score: score.away),
            broadcasts: broadcasts.compactMap(\.network),
            venue: venue?.name,
            liveContext: MatchLiveContextMapper.context(from: self, league: league)
        )
        match.canonicalID = id.rawValue
        match.broadcastDetails = broadcasts
        return match
    }
}

private enum MatchLiveContextMapper {
    static func context(from game: BannerGame, league: League) -> MatchLiveContext {
        let match = game.toLegacyMatchWithoutContext(league: league)
        return MatchLiveContext(
            clock: game.clock.map(MatchClock.init),
            period: game.period.map(MatchPeriod.init),
            baseball: baseball(from: game, match: match),
            hockey: hockey(from: game, match: match),
            football: football(from: game, match: match),
            soccer: soccer(from: game, match: match, plays: []),
            basketball: basketball(from: game, match: match)
        )
    }

    static func baseball(from game: BannerGame?, match: Match) -> BaseballSituation? {
        guard match.league.group == .baseball else { return nil }
        let period = game?.period?.displayName ?? match.statusDetail
        return BaseballSituation(inning: clean(period), inningHalf: nil, outs: nil, balls: nil, strikes: nil, runnerOnFirst: nil, runnerOnSecond: nil, runnerOnThird: nil, batterName: nil, pitcherName: nil)
    }

    static func hockey(from game: BannerGame?, match: Match) -> HockeySituation? {
        guard match.league.group == .hockey else { return nil }
        return HockeySituation(
            period: clean(game?.period?.displayName),
            clock: clean(game?.clock?.displayValue) ?? clean(match.statusDetail),
            powerPlayTeamID: nil,
            powerPlayTeamAbbreviation: nil,
            powerPlayTimeRemaining: nil,
            strengthState: nil,
            delayedPenaltyTeamID: nil,
            emptyNetTeamID: nil
        )
    }

    static func football(from game: BannerGame?, match: Match) -> FootballSituation? {
        guard match.league.group == .football else { return nil }
        return FootballSituation(
            quarter: clean(game?.period?.displayName),
            clock: clean(game?.clock?.displayValue) ?? clean(match.statusDetail),
            possessionTeamID: nil,
            possessionTeamAbbreviation: nil,
            down: nil,
            distance: nil,
            ballPosition: nil,
            yardLine: nil,
            isRedZone: nil,
            homeTimeoutsRemaining: nil,
            awayTimeoutsRemaining: nil
        )
    }

    static func soccer(from game: BannerGame?, match: Match, plays: [BannerPlay]) -> SoccerSituation? {
        guard match.league.group == .soccer else { return nil }
        return SoccerSituation(
            minute: clean(game?.clock?.displayValue) ?? clean(match.statusDetail),
            stoppageTime: nil,
            aggregateScore: nil,
            homeRedCards: nil,
            awayRedCards: nil,
            latestEvent: plays.last.map(MatchPlay.init)
        )
    }

    static func basketball(from game: BannerGame?, match: Match) -> BasketballSituation? {
        guard match.league.group == .basketball else { return nil }
        return BasketballSituation(
            quarter: clean(game?.period?.displayName),
            clock: clean(game?.clock?.displayValue) ?? clean(match.statusDetail),
            possessionTeamID: nil,
            possessionTeamAbbreviation: nil,
            homeTimeoutsRemaining: nil,
            awayTimeoutsRemaining: nil,
            homeBonus: nil,
            awayBonus: nil,
            scoringByPeriod: []
        )
    }

    static func drives(from plays: [BannerPlay], match: Match) -> [FootballDrive] {
        guard match.league.group == .football, !plays.isEmpty else { return [] }
        let mapped = plays.map(MatchPlay.init)
        return [FootballDrive(id: "drive:\(match.id):current", teamID: nil, teamAbbreviation: nil, result: nil, summary: nil, isCurrent: match.state == .live, plays: mapped)]
    }

    static func gameLeaders(from boxScore: BannerBoxScore?, match: Match) -> [MatchLeader] {
        guard let playerStats = boxScore?.playerStats, !playerStats.isEmpty else { return [] }
        let leaderSpecs: [(key: String, title: String, aliases: Set<String>)]
        switch match.league.group {
        case .basketball:
            leaderSpecs = [
                ("points", "Points", ["points", "pts"]),
                ("rebounds", "Rebounds", ["rebounds", "reb", "rebs"]),
                ("assists", "Assists", ["assists", "ast"])
            ]
        case .hockey:
            leaderSpecs = [
                ("goals", "Goals", ["goals", "g"]),
                ("assists", "Assists", ["assists", "a"]),
                ("shots", "Shots", ["shots", "sog"])
            ]
        case .baseball:
            leaderSpecs = [
                ("hits", "Hits", ["hits", "h"]),
                ("rbi", "RBI", ["rbi", "runs batted in"]),
                ("strikeouts", "Strikeouts", ["strikeouts", "so", "k"])
            ]
        case .football:
            leaderSpecs = [
                ("passingYards", "Passing", ["passing yards", "pass yds", "yds"]),
                ("rushingYards", "Rushing", ["rushing yards", "rush yds"]),
                ("receivingYards", "Receiving", ["receiving yards", "rec yds"])
            ]
        default:
            return []
        }

        return leaderSpecs.compactMap { spec in
            let ranked = playerStats.compactMap { player -> (player: BannerPlayerStat, stat: BannerStatValue, value: Double)? in
                guard let stat = player.stats.first(where: { matchesStat($0, aliases: spec.aliases) }),
                      let value = numericValue(from: stat.value) else { return nil }
                return (player, stat, value)
            }
            .sorted { $0.value > $1.value }
            .prefix(2)

            let players = ranked.map { item in
                MatchPlayerStat(
                    id: item.player.playerID.rawValue,
                    displayName: item.player.playerDisplayName ?? item.player.playerID.rawValue,
                    teamAbbreviation: item.player.teamAbbreviation,
                    headshotURL: item.player.headshotURL,
                    stats: [MatchStat(key: item.stat.key, displayName: item.stat.displayName, value: item.stat.value)]
                )
            }
            guard !players.isEmpty else { return nil }
            return MatchLeader(key: spec.key, displayName: spec.title, players: players)
        }
    }

    private static func matchesStat(_ stat: BannerStatValue, aliases: Set<String>) -> Bool {
        aliases.contains(stat.key.lowercased()) || aliases.contains(stat.displayName.lowercased())
    }

    private static func numericValue(from value: String) -> Double? {
        let filtered = value.filter { $0.isNumber || $0 == "." }
        guard !filtered.isEmpty else { return nil }
        return Double(filtered)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private extension BannerGame {
    func toLegacyMatchWithoutContext(league: League) -> Match {
        Match(
            id: aliases.first { $0.provider == .espn }?.id ?? aliases.first?.id ?? id.rawValue,
            league: league,
            date: scheduledStart,
            name: name,
            shortName: shortName,
            state: status.legacyGameState,
            statusDetail: statusDetail,
            home: homeTeam.toLegacyTeamSide(score: score.home),
            away: awayTeam.toLegacyTeamSide(score: score.away),
            broadcasts: broadcasts.compactMap(\.network),
            venue: venue?.name
        )
    }
}

private extension MatchClock {
    nonisolated init(banner: BannerGameClock) {
        self.init(displayValue: banner.displayValue, remainingSeconds: banner.remainingSeconds, isRunning: banner.isRunning)
    }
}

private extension MatchPeriod {
    nonisolated init(banner: BannerPeriod) {
        self.init(number: banner.number, displayName: banner.displayName)
    }
}

private extension MatchTeamStats {
    nonisolated init(banner: BannerTeamStat, match: Match) {
        let rawID = banner.teamID.rawValue
        let side: MatchTeamSide = rawID == match.home.canonicalIDString ? .home : .away
        self.init(
            side: side,
            teamID: rawID,
            teamAbbreviation: side == .home ? match.home.abbreviation : match.away.abbreviation,
            stats: banner.stats.map(MatchStat.init)
        )
    }
}

private extension MatchStat {
    nonisolated init(banner: BannerStatValue) {
        self.init(key: banner.key, displayName: banner.displayName, value: banner.value)
    }
}

private extension MatchLeader {
    nonisolated init(banner: BannerLeader) {
        self.init(
            key: banner.statKey,
            displayName: banner.displayName,
            players: banner.players.map(MatchPlayerStat.init)
        )
    }
}

private extension MatchPlayerStat {
    nonisolated init(banner: BannerPlayerStat) {
        self.init(
            id: banner.playerID.rawValue,
            displayName: banner.playerDisplayName ?? banner.playerID.rawValue,
            teamAbbreviation: banner.teamAbbreviation,
            headshotURL: banner.headshotURL,
            stats: banner.stats.map(MatchStat.init)
        )
    }
}

private extension MatchPlay {
    nonisolated init(banner: BannerPlay) {
        self.init(
            id: banner.id.rawValue,
            sequence: banner.sequence,
            period: banner.period.map(MatchPeriod.init),
            clock: banner.clock.map(MatchClock.init),
            text: banner.text,
            teamID: banner.teamID?.rawValue,
            teamAbbreviation: nil,
            awayScore: banner.awayScore,
            homeScore: banner.homeScore,
            isScoringPlay: banner.isScoringPlay,
            eventType: Self.eventType(from: banner),
            providerTimestamp: nil
        )
    }

    nonisolated static func eventType(from play: BannerPlay) -> MatchEventType? {
        let text = play.text.lowercased()
        if text.contains("touchdown") { return .touchdown }
        if text.contains("field goal") { return .fieldGoal }
        if text.contains("interception") || text.contains("fumble") || text.contains("turnover") { return .turnover }
        if text.contains("home run") { return .homeRun }
        if text.contains("goal") { return .goal }
        if text.contains("penalty") { return .penalty }
        if text.contains("substitution") { return .substitution }
        if text.contains("yellow card") { return .yellowCard }
        if text.contains("red card") { return .redCard }
        if play.isScoringPlay { return .basket }
        return nil
    }
}

private extension MatchBoxScore {
    nonisolated init(banner: BannerBoxScore) {
        self.init(
            teamStats: banner.teamStats.map {
                MatchTeamStats(side: .away, teamID: $0.teamID.rawValue, teamAbbreviation: nil, stats: $0.stats.map(MatchStat.init))
            },
            playerStats: banner.playerStats.map(MatchPlayerStat.init)
        )
    }
}

extension BannerTeam {
    func toLegacyTeamSide(score: String?) -> TeamSide {
        TeamSide(
            displayName: displayName,
            shortName: shortName,
            abbreviation: abbreviation,
            logoURL: logoURL,
            score: score,
            record: nil,
            isWinner: false,
            teamID: aliases.first { $0.provider == .espn }?.id ?? aliases.first?.id,
            canonicalIDString: id.rawValue
        )
    }

    func toLegacyTeam() -> Team {
        Team(
            id: aliases.first { $0.provider == .espn }?.id ?? aliases.first?.id ?? id.rawValue,
            displayName: displayName,
            shortDisplayName: shortName,
            abbreviation: abbreviation,
            logoURL: logoURL,
            canonicalIDString: id.rawValue
        )
    }
}
