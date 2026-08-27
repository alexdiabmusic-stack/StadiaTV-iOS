import Foundation

extension GameState: Codable, Sendable {}

// MARK: - Provider-independent Fantasy domain

enum FantasyProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case stadia
    case sleeper
    case espn

    var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .stadia: return "Stadia Fantasy"
        case .sleeper: return "Sleeper"
        case .espn: return "ESPN Fantasy"
        }
    }
}

enum FantasySport: String, Codable, CaseIterable, Identifiable, Sendable {
    case nfl
    case nhl
    case nba
    case mlb

    nonisolated var id: String { rawValue }

    nonisolated var stadiaLeague: League? {
        League.all.first { $0.path == stadiaLeaguePath }
    }

    nonisolated var stadiaLeaguePath: String {
        switch self {
        case .nfl: return "football/nfl"
        case .nhl: return "hockey/nhl"
        case .nba: return "basketball/nba"
        case .mlb: return "baseball/mlb"
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .nfl: return "NFL"
        case .nhl: return "NHL"
        case .nba: return "NBA"
        case .mlb: return "MLB"
        }
    }

    nonisolated var longDisplayName: String {
        switch self {
        case .nfl: return "Football"
        case .nhl: return "Hockey"
        case .nba: return "Basketball"
        case .mlb: return "Baseball"
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .nfl: return "football.fill"
        case .nhl: return "hockey.puck.fill"
        case .nba: return "basketball.fill"
        case .mlb: return "baseball.fill"
        }
    }
}

enum FantasyLeagueStatus: String, Codable, Sendable {
    case preDraft
    case drafting
    case inSeason
    case complete
    case offSeason
    case unknown
}

enum FantasyRosterSlotKind: String, Codable, Sendable {
    case starter
    case bench
    case reserve
}

enum FantasyGameLinkState: String, Codable, Sendable {
    case noGame
    case upcoming
    case live
    case final
}

enum FantasyConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(FantasyConnection)
    case providerUnavailable(String)
    case offlineWithCachedData(FantasyConnection)
}

enum FantasyContentState: Equatable, Sendable {
    case disconnected
    case loading
    case noLeagues
    case preDraft
    case inSeason
    case seasonComplete
    case offSeason
    case noCurrentMatchup
    case noFantasyPlayersToday
    case playersScheduled
    case playersLive
    case partialData(String)
    case providerUnavailable(String)
    case offlineWithCachedData
}

struct FantasyConnection: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(provider.rawValue)-\(providerUserID)" }
    let provider: FantasyProvider
    let providerUserID: String
    let username: String?
    let displayName: String?
    let avatarID: String?
    let connectedAt: Date
    let refreshedAt: Date?

    var avatarURL: URL? {
        guard provider == .sleeper, let avatarID, !avatarID.isEmpty else { return nil }
        return URL(string: "https://sleepercdn.com/avatars/\(avatarID)")
    }

    var avatarThumbnailURL: URL? {
        guard provider == .sleeper, let avatarID, !avatarID.isEmpty else { return nil }
        return URL(string: "https://sleepercdn.com/avatars/thumbs/\(avatarID)")
    }
}

struct FantasySeasonState: Codable, Equatable, Sendable {
    let sport: FantasySport
    let season: String
    let leagueSeason: String?
    let week: Int?
    let displayWeek: Int?
    let seasonType: String?
    let seasonStartDate: Date?

    var activeWeek: Int? { displayWeek ?? week }
    var seasonForLeagueLookup: String { leagueSeason ?? season }
}

struct FantasyLeague: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: FantasyProvider
    let sport: FantasySport
    let name: String
    let season: String
    let status: FantasyLeagueStatus
    let totalRosters: Int?
    let avatarID: String?
    let rosterPositions: [String]
    let scoringSettings: FantasyScoringSettings
    let providerMetadata: [String: String]
}

struct FantasyTeam: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let providerUserID: String?
    let rosterID: Int?
    let displayName: String
    let username: String?
    let avatarID: String?
    let isOwner: Bool
}

struct FantasyRoster: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let rosterID: Int
    let ownerUserID: String?
    let team: FantasyTeam?
    let slots: [FantasyRosterSlot]
    let record: FantasyRecord?
    let waiverPosition: Int?
    let waiverBudgetUsed: Int?
    let totalMoves: Int?

    var starters: [FantasyRosterSlot] { slots.filter { $0.kind == .starter } }
    var bench: [FantasyRosterSlot] { slots.filter { $0.kind == .bench } }
}

struct FantasyRosterSlot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let playerID: String
    let kind: FantasyRosterSlotKind
    let lineupPosition: String?
    let fantasyPoints: Double?
    let projectedPoints: Double?
}

struct FantasyPlayer: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let provider: FantasyProvider
    let sport: FantasySport
    let firstName: String?
    let lastName: String?
    let fullName: String
    let teamAbbreviation: String?
    let position: String?
    let fantasyPositions: [String]
    let status: String?
    let injuryStatus: String?
    let jerseyNumber: String?
    let externalIDs: FantasyPlayerExternalIDs

    var normalizedName: String { FantasyStringNormalizer.normalize(fullName) }
}

struct FantasyPlayerExternalIDs: Codable, Hashable, Sendable {
    let espnID: String?
    let sportradarID: String?
    let yahooID: String?
    let fantasyDataID: String?
    let statsID: String?
    let rotowireID: String?
}

struct FantasyMatchup: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let week: Int
    let matchupID: Int?
    let userTeam: FantasyMatchupTeam
    let opponentTeam: FantasyMatchupTeam?
}

struct FantasyMatchupTeam: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let rosterID: Int
    let team: FantasyTeam?
    let starters: [String]
    let players: [String]
    let points: Double?
    let customPoints: Double?

    var effectivePoints: Double? { customPoints ?? points }
    var benchPlayerIDs: [String] { players.filter { !starters.contains($0) } }
}

struct FantasyStanding: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let rosterID: Int
    let team: FantasyTeam?
    let record: FantasyRecord
    let rank: Int?
}

struct FantasyRecord: Codable, Hashable, Sendable {
    let wins: Int?
    let losses: Int?
    let ties: Int?
    let pointsFor: Double?
    let pointsAgainst: Double?

    var displayRecord: String {
        "\(wins ?? 0)-\(losses ?? 0)" + ((ties ?? 0) > 0 ? "-\(ties ?? 0)" : "")
    }
}

struct FantasyScoringSettings: Codable, Hashable, Sendable {
    let values: [String: Double]
}

struct StadiaPlayerIdentity: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let leaguePath: String
    let displayName: String
    let teamAbbreviation: String?
    let position: String?
    let espnAthleteID: String?
    let source: String
}

enum FantasyPlayerResolution: Codable, Hashable, Sendable {
    case resolved(StadiaPlayerIdentity)
    case ambiguous([StadiaPlayerIdentity])
    case unresolved(String)

    var identity: StadiaPlayerIdentity? {
        if case .resolved(let identity) = self { return identity }
        return nil
    }
}

struct FantasyPlayerGame: Identifiable, Hashable, Sendable {
    let id: String
    let fantasyPlayer: FantasyPlayer
    let stadiaPlayer: StadiaPlayerIdentity?
    let event: Match?
    let opponent: TeamSide?
    let gameState: FantasyGameLinkState
    let fantasyPoints: Double?
    let projectedPoints: Double?
    let matchedChannel: RankedSource?
    let rosterSlotKind: FantasyRosterSlotKind?
    let lineupPosition: String?

    init(
        id: String,
        fantasyPlayer: FantasyPlayer,
        stadiaPlayer: StadiaPlayerIdentity?,
        event: Match?,
        opponent: TeamSide?,
        gameState: FantasyGameLinkState,
        fantasyPoints: Double?,
        projectedPoints: Double?,
        matchedChannel: RankedSource?,
        rosterSlotKind: FantasyRosterSlotKind? = nil,
        lineupPosition: String? = nil
    ) {
        self.id = id
        self.fantasyPlayer = fantasyPlayer
        self.stadiaPlayer = stadiaPlayer
        self.event = event
        self.opponent = opponent
        self.gameState = gameState
        self.fantasyPoints = fantasyPoints
        self.projectedPoints = projectedPoints
        self.matchedChannel = matchedChannel
        self.rosterSlotKind = rosterSlotKind
        self.lineupPosition = lineupPosition
    }

    var watchAvailable: Bool { matchedChannel != nil }
    var isFantasyStarter: Bool { rosterSlotKind == .starter }
    var isFantasyBench: Bool { rosterSlotKind == .bench }
}

struct FantasyEventContext: Identifiable, Hashable, Sendable {
    let event: Match
    let playerGames: [FantasyPlayerGame]
    let matchedChannel: RankedSource?

    var id: String { event.id }
    var starterCount: Int { playerGames.filter { $0.isFantasyStarter }.count }
    var benchCount: Int { playerGames.filter { $0.isFantasyBench }.count }
    var watchAvailable: Bool { matchedChannel != nil }
    var isLive: Bool { event.state == .live }
    var isUpcoming: Bool { event.state == .pre }
}

struct CachedFantasyPlayerGame: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let fantasyPlayer: FantasyPlayer
    let stadiaPlayer: StadiaPlayerIdentity?
    let event: CachedFantasyMatch?
    let opponent: CachedFantasyTeamSide?
    let gameState: FantasyGameLinkState
    let fantasyPoints: Double?
    let projectedPoints: Double?
    let matchedChannelID: String?
    let matchedChannelScore: Int?
    let rosterSlotKind: FantasyRosterSlotKind?
    let lineupPosition: String?

    nonisolated init(game: FantasyPlayerGame) {
        self.id = game.id
        self.fantasyPlayer = game.fantasyPlayer
        self.stadiaPlayer = game.stadiaPlayer
        self.event = game.event.map(CachedFantasyMatch.init(match:))
        self.opponent = game.opponent.map(CachedFantasyTeamSide.init(side:))
        self.gameState = game.gameState
        self.fantasyPoints = game.fantasyPoints
        self.projectedPoints = game.projectedPoints
        self.matchedChannelID = game.matchedChannel?.channel.id
        self.matchedChannelScore = game.matchedChannel?.score
        self.rosterSlotKind = game.rosterSlotKind
        self.lineupPosition = game.lineupPosition
    }

    func toDomain(channels: [Channel] = []) -> FantasyPlayerGame {
        let channel = matchedChannelID.flatMap { id in channels.first { $0.id == id } }
        return FantasyPlayerGame(
            id: id,
            fantasyPlayer: fantasyPlayer,
            stadiaPlayer: stadiaPlayer,
            event: event.flatMap { $0.toDomain() },
            opponent: opponent?.toDomain(),
            gameState: gameState,
            fantasyPoints: fantasyPoints,
            projectedPoints: projectedPoints,
            matchedChannel: channel.map { RankedSource(channel: $0, score: matchedChannelScore ?? 0) },
            rosterSlotKind: rosterSlotKind,
            lineupPosition: lineupPosition
        )
    }
}

struct CachedFantasyMatch: Codable, Hashable, Sendable {
    let id: String
    let leaguePath: String
    let date: Date
    let name: String
    let shortName: String
    let state: GameState
    let statusDetail: String
    let home: CachedFantasyTeamSide
    let away: CachedFantasyTeamSide
    let broadcasts: [String]
    let venue: String?

    nonisolated init(match: Match) {
        self.id = match.id
        self.leaguePath = match.league.path
        self.date = match.date
        self.name = match.name
        self.shortName = match.shortName
        self.state = match.state
        self.statusDetail = match.statusDetail
        self.home = CachedFantasyTeamSide(side: match.home)
        self.away = CachedFantasyTeamSide(side: match.away)
        self.broadcasts = match.broadcasts
        self.venue = match.venue
    }

    @MainActor
    func toDomain() -> Match? {
        guard let league = League.all.first(where: { $0.path == leaguePath }) else { return nil }
        return Match(
            id: id,
            league: league,
            date: date,
            name: name,
            shortName: shortName,
            state: state,
            statusDetail: statusDetail,
            home: home.toDomain(),
            away: away.toDomain(),
            broadcasts: broadcasts,
            venue: venue
        )
    }
}

struct CachedFantasyTeamSide: Codable, Hashable, Sendable {
    let displayName: String
    let shortName: String
    let abbreviation: String
    let logoURL: URL?
    let score: String?
    let record: String?
    let isWinner: Bool
    let teamID: String?

    nonisolated init(side: TeamSide) {
        self.displayName = side.displayName
        self.shortName = side.shortName
        self.abbreviation = side.abbreviation
        self.logoURL = side.logoURL
        self.score = side.score
        self.record = side.record
        self.isWinner = side.isWinner
        self.teamID = side.teamID
    }

    nonisolated func toDomain() -> TeamSide {
        TeamSide(displayName: displayName, shortName: shortName, abbreviation: abbreviation, logoURL: logoURL, score: score, record: record, isWinner: isWinner, teamID: teamID)
    }
}

struct FantasyDiagnostics: Sendable {
    let provider: FantasyProvider?
    let connectionState: FantasyConnectionState
    let contentState: FantasyContentState
    let selectedLeagueID: String?
    let leagueCount: Int
    let rosterPlayerCount: Int
    let linkedGameCount: Int
    let unresolvedPlayerCount: Int
    let watchableGameCount: Int
    let refreshedAt: Date?
    let isStale: Bool
}

struct FantasyLiveContext: Hashable, Sendable {
    let connection: FantasyConnection?
    let selectedLeague: FantasyLeague?
    let userRoster: FantasyRoster?
    let matchup: FantasyMatchup?
    let standings: [FantasyStanding]
    let players: [FantasyPlayer]
    let playerResolutions: [String: FantasyPlayerResolution]
    let playerGames: [FantasyPlayerGame]
    let gamesByEventID: [String: [FantasyPlayerGame]]
    let eventContextsByEventID: [String: FantasyEventContext]
    let refreshedAt: Date?
    let stale: Bool
    let unresolvedPlayerIDs: [String]
}

enum FantasyScoringFormat: String, Sendable {
    case headToHeadPoints
    case headToHeadCategories
    case rotisserie
    case unknown
}

extension FantasyLeague {
    var scoringFormat: FantasyScoringFormat {
        let value = (providerMetadata["scoringType"] ?? "").lowercased()
        if value.contains("roto") { return .rotisserie }
        if value.contains("category") || value.contains("categories") { return .headToHeadCategories }
        if value.contains("points") || value.contains("h2h_points") { return .headToHeadPoints }
        return .unknown
    }

    var matchupPeriodLabel: String {
        sport == .nfl ? "Week" : "Matchup Period"
    }

    var currentScoringPeriodLabel: String? {
        providerMetadata["latestScoringPeriod"].map { "Scoring Period \($0)" }
    }
}

struct FantasySettings: Codable, Equatable, Sendable {
    var selectedLeagueID: String?
    var showFantasyOnHome: Bool
    var showFantasyIndicatorsInLive: Bool
    var showFantasyIndicatorsInGuide: Bool
    var showFantasyPlayerOverlay: Bool

    nonisolated init(
        selectedLeagueID: String? = nil,
        showFantasyOnHome: Bool = true,
        showFantasyIndicatorsInLive: Bool = true,
        showFantasyIndicatorsInGuide: Bool = true,
        showFantasyPlayerOverlay: Bool = true
    ) {
        self.selectedLeagueID = selectedLeagueID
        self.showFantasyOnHome = showFantasyOnHome
        self.showFantasyIndicatorsInLive = showFantasyIndicatorsInLive
        self.showFantasyIndicatorsInGuide = showFantasyIndicatorsInGuide
        self.showFantasyPlayerOverlay = showFantasyPlayerOverlay
    }

    enum CodingKeys: String, CodingKey {
        case selectedLeagueID, showFantasyOnHome, showFantasyIndicatorsInLive, showFantasyIndicatorsInGuide, showFantasyPlayerOverlay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedLeagueID = try container.decodeIfPresent(String.self, forKey: .selectedLeagueID)
        showFantasyOnHome = try container.decodeIfPresent(Bool.self, forKey: .showFantasyOnHome) ?? true
        showFantasyIndicatorsInLive = try container.decodeIfPresent(Bool.self, forKey: .showFantasyIndicatorsInLive) ?? true
        showFantasyIndicatorsInGuide = try container.decodeIfPresent(Bool.self, forKey: .showFantasyIndicatorsInGuide) ?? true
        showFantasyPlayerOverlay = try container.decodeIfPresent(Bool.self, forKey: .showFantasyPlayerOverlay) ?? true
    }
}

nonisolated enum FantasyStringNormalizer {
    static func normalize(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let alphanumeric = String(folded.map { character in
            character.isLetter || character.isNumber ? character : " "
        })
        return alphanumeric
            .split(separator: " ")
            .map(String.init)
            .joined(separator: " ")
    }
}
