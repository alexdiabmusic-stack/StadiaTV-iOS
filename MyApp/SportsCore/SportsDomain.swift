import Foundation
import Foundation

extension SportGroup: Codable, Sendable {}

// MARK: - Provider metadata

enum SportsDataProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case nhl
    case f1
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

extension BannerGameStatus {
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

