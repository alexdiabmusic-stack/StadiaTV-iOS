import Foundation

extension URL {
    nonisolated static func bannerImageAsset(named assetName: String) -> URL? {
        URL(string: "banner-asset:/\(assetName)")
    }

    nonisolated var bannerImageAssetName: String? {
        guard scheme == "banner-asset" else { return nil }
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedPath.isEmpty ? host : trimmedPath
    }
}

// MARK: - Leagues / Sports catalog

/// A sport grouping used to organize the league picker.
enum SportGroup: String, CaseIterable, Identifiable {
    case football = "Football"
    case basketball = "Basketball"
    case baseball = "Baseball"
    case hockey = "Hockey"
    case soccer = "Soccer"
    case tennis = "Tennis"
    case golf = "Golf"
    case racing = "Racing"
    // Non-ESPN sports — used for featured event icons only, not shown in league pickers
    case cycling = "Cycling"
    case wrestling = "Wrestling"
    case esports = "Esports"

    var id: String { rawValue }

    /// ESPN-backed sports that have followable leagues. Non-ESPN sports are excluded from league/sport pickers.
    var hasEspnLeagues: Bool {
        switch self {
        case .cycling, .wrestling, .esports: return false
        default: return true
        }
    }

    var systemImage: String {
        switch self {
        case .football: return "football.fill"
        case .basketball: return "basketball.fill"
        case .baseball: return "baseball.fill"
        case .hockey: return "hockey.puck.fill"
        case .soccer: return "soccerball"
        case .tennis: return "figure.tennis"
        case .golf: return "figure.golf"
        case .racing: return "flag.checkered"
        case .cycling: return "figure.outdoor.cycle"
        case .wrestling: return "figure.wrestling"
        case .esports: return "gamecontroller.fill"
        }
    }
}

/// A single Banner league / competition.
/// `path` remains the legacy ESPN URL segment during migration. Use `bannerKey` for Banner-owned identity and routing.
struct League: Identifiable, Hashable {
    let id: String        // migration-compatible identifier == path
    let name: String      // display name
    let shortName: String // compact label
    let path: String      // legacy ESPN api path segment
    let bannerKey: String // Banner-owned league key, independent of provider URL paths
    let group: SportGroup
    /// Keywords used by the source-matching algorithm (broadcast/league aliases).
    let keywords: [String]

    init(name: String, shortName: String, path: String, bannerKey: String? = nil, group: SportGroup, keywords: [String] = []) {
        self.id = path
        self.name = name
        self.shortName = shortName
        self.path = path
        self.bannerKey = bannerKey ?? "league.\(SportsIdentityResolver.slug(path))"
        self.group = group
        self.keywords = keywords
    }

    nonisolated static let all: [League] = [
        League(name: "NFL", shortName: "NFL", path: "football/nfl", group: .football,
               keywords: ["nfl", "football", "sunday", "monday night", "thursday night"]),
        League(name: "CFL", shortName: "CFL", path: "football/cfl", group: .football,
               keywords: ["cfl", "canadian football"]),
        League(name: "NBA", shortName: "NBA", path: "basketball/nba", group: .basketball,
               keywords: ["nba", "basketball"]),
        League(name: "WNBA", shortName: "WNBA", path: "basketball/wnba", group: .basketball,
               keywords: ["wnba", "basketball"]),
        League(name: "MLB", shortName: "MLB", path: "baseball/mlb", group: .baseball,
               keywords: ["mlb", "baseball"]),
        League(name: "NHL", shortName: "NHL", path: "hockey/nhl", group: .hockey,
               keywords: ["nhl", "hockey"]),
        League(name: "Liga MX", shortName: "Liga MX", path: "soccer/mex.1", group: .soccer,
               keywords: ["liga mx", "mexican", "soccer"]),
        League(name: "Premier League", shortName: "EPL", path: "soccer/eng.1", group: .soccer,
               keywords: ["premier league", "epl", "english", "soccer", "football"]),
        League(name: "MLS", shortName: "MLS", path: "soccer/usa.1", group: .soccer,
               keywords: ["mls", "major league soccer", "soccer"]),
        League(name: "Formula 1", shortName: "F1", path: "racing/f1", group: .racing,
               keywords: ["f1", "formula 1", "formula one", "grand prix"]),
        League(name: "PGA Tour", shortName: "PGA", path: "golf/pga", group: .golf,
               keywords: ["pga", "golf", "tour"]),
    ]

    static func leagues(in group: SportGroup) -> [League] {
        all.filter { $0.group == group }
    }
}

// MARK: - Match model (app-level, decoded from ESPN scoreboard)

enum GameState: String {
    case pre, live, final

    var label: String {
        switch self {
        case .pre: return "Upcoming"
        case .live: return "LIVE"
        case .final: return "Final"
        }
    }
}

struct TeamSide: Hashable {
    let displayName: String
    let shortName: String
    let abbreviation: String
    let logoURL: URL?
    let score: String?
    let record: String?
    let isWinner: Bool
    /// Legacy/provider team id, used by older UI until all surfaces consume canonical team IDs directly.
    var teamID: String? = nil
    var canonicalIDString: String? = nil

    init(
        displayName: String,
        shortName: String,
        abbreviation: String,
        logoURL: URL?,
        score: String?,
        record: String?,
        isWinner: Bool,
        teamID: String? = nil,
        canonicalIDString: String? = nil
    ) {
        self.displayName = displayName
        self.shortName = shortName
        self.abbreviation = abbreviation
        self.logoURL = logoURL
        self.score = score
        self.record = record
        self.isWinner = isWinner
        self.teamID = teamID
        self.canonicalIDString = canonicalIDString
    }
}

struct MatchLiveContext: Hashable, Sendable {
    var clock: MatchClock?
    var period: MatchPeriod?
    var baseball: BaseballSituation?
    var hockey: HockeySituation?
    var football: FootballSituation?
    var soccer: SoccerSituation?
    var basketball: BasketballSituation?
    var teamStats: [MatchTeamStats]
    var leaders: [MatchLeader]
    var playByPlay: [MatchPlay]
    var boxScore: MatchBoxScore?
    var formations: [TeamFormation]
    var drives: [FootballDrive]
    /// Future stream-delay support: consumers should compare provider event timestamps
    /// through this offset before triggering major-event animations.
    var sportsDataDelay: TimeInterval?

    static let empty = MatchLiveContext()

    init(
        clock: MatchClock? = nil,
        period: MatchPeriod? = nil,
        baseball: BaseballSituation? = nil,
        hockey: HockeySituation? = nil,
        football: FootballSituation? = nil,
        soccer: SoccerSituation? = nil,
        basketball: BasketballSituation? = nil,
        teamStats: [MatchTeamStats] = [],
        leaders: [MatchLeader] = [],
        playByPlay: [MatchPlay] = [],
        boxScore: MatchBoxScore? = nil,
        formations: [TeamFormation] = [],
        drives: [FootballDrive] = [],
        sportsDataDelay: TimeInterval? = nil
    ) {
        self.clock = clock
        self.period = period
        self.baseball = baseball
        self.hockey = hockey
        self.football = football
        self.soccer = soccer
        self.basketball = basketball
        self.teamStats = teamStats
        self.leaders = leaders
        self.playByPlay = playByPlay
        self.boxScore = boxScore
        self.formations = formations
        self.drives = drives
        self.sportsDataDelay = sportsDataDelay
    }
}

struct MatchClock: Hashable, Sendable {
    var displayValue: String?
    var remainingSeconds: Int?
    var isRunning: Bool?
}

struct MatchPeriod: Hashable, Sendable {
    var number: Int?
    var displayName: String?
}

struct BaseballSituation: Hashable, Sendable {
    var inning: String?
    var inningHalf: String?
    var outs: Int?
    var balls: Int?
    var strikes: Int?
    var runnerOnFirst: Bool?
    var runnerOnSecond: Bool?
    var runnerOnThird: Bool?
    var batterName: String?
    var pitcherName: String?
}

struct HockeySituation: Hashable, Sendable {
    var period: String?
    var clock: String?
    var powerPlayTeamID: String?
    var powerPlayTeamAbbreviation: String?
    var powerPlayTimeRemaining: String?
    var strengthState: String?
    var delayedPenaltyTeamID: String?
    var emptyNetTeamID: String?
}

struct FootballSituation: Hashable, Sendable {
    var quarter: String?
    var clock: String?
    var possessionTeamID: String?
    var possessionTeamAbbreviation: String?
    var down: Int?
    var distance: Int?
    var ballPosition: String?
    var yardLine: Int?
    var isRedZone: Bool?
    var homeTimeoutsRemaining: Int?
    var awayTimeoutsRemaining: Int?
}

struct SoccerSituation: Hashable, Sendable {
    var minute: String?
    var stoppageTime: String?
    var aggregateScore: String?
    var homeRedCards: Int?
    var awayRedCards: Int?
    var latestEvent: MatchPlay?
}

struct BasketballSituation: Hashable, Sendable {
    var quarter: String?
    var clock: String?
    var possessionTeamID: String?
    var possessionTeamAbbreviation: String?
    var homeTimeoutsRemaining: Int?
    var awayTimeoutsRemaining: Int?
    var homeBonus: Bool?
    var awayBonus: Bool?
    var scoringByPeriod: [LineScorePeriod]
}

struct LineScorePeriod: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let awayScore: String?
    let homeScore: String?
}

struct MatchTeamStats: Identifiable, Hashable, Sendable {
    var id: String { teamID ?? side.rawValue }
    let side: MatchTeamSide
    let teamID: String?
    let teamAbbreviation: String?
    let stats: [MatchStat]
}

enum MatchTeamSide: String, Hashable, Sendable {
    case home
    case away
}

struct MatchStat: Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let displayName: String
    let value: String
}

struct MatchLeader: Identifiable, Hashable, Sendable {
    var id: String { key }
    let key: String
    let displayName: String
    let players: [MatchPlayerStat]
}

struct MatchPlayerStat: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let teamAbbreviation: String?
    let headshotURL: URL?
    let stats: [MatchStat]
}

struct MatchPlay: Identifiable, Hashable, Sendable {
    let id: String
    let sequence: Int?
    let period: MatchPeriod?
    let clock: MatchClock?
    let text: String
    let teamID: String?
    let teamAbbreviation: String?
    let awayScore: String?
    let homeScore: String?
    let isScoringPlay: Bool
    let eventType: MatchEventType?
    let providerTimestamp: Date?
}

enum MatchEventType: String, Hashable, Sendable {
    case goal
    case penalty
    case powerPlay
    case touchdown
    case fieldGoal
    case turnover
    case homeRun
    case run
    case basket
    case substitution
    case yellowCard
    case redCard
    case periodStart
    case periodEnd
    case other
}

struct MatchBoxScore: Hashable, Sendable {
    var teamStats: [MatchTeamStats]
    var playerStats: [MatchPlayerStat]
}

struct TeamFormation: Identifiable, Hashable, Sendable {
    var id: String { teamID ?? teamAbbreviation ?? formationName ?? "formation" }
    let teamID: String?
    let teamAbbreviation: String?
    let formationName: String?
    let groups: [LineupGroup]
}

struct LineupGroup: Identifiable, Hashable, Sendable {
    var id: String { title }
    let title: String
    let players: [LineupPlayer]
}

struct LineupPlayer: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let position: String?
    let jerseyNumber: String?
    let x: Double?
    let y: Double?
}

struct FootballDrive: Identifiable, Hashable, Sendable {
    let id: String
    let teamID: String?
    let teamAbbreviation: String?
    let result: String?
    let summary: String?
    let isCurrent: Bool
    let plays: [MatchPlay]
}

struct Match: Identifiable, Hashable {
    let id: String
    let league: League
    let date: Date
    let name: String
    let shortName: String
    let state: GameState
    let statusDetail: String   // e.g. "Q3 4:21" or "7:00 PM ET"
    let home: TeamSide
    let away: TeamSide
    let broadcasts: [String]
    let venue: String?
    let liveContext: MatchLiveContext
    /// Provider-qualified canonical game ID (e.g. "game:espn:nba:401234"). Preserved for routing.
    var canonicalID: String? = nil
    /// Full broadcast records with country/type metadata. Use for stream matching; use `broadcasts` for display.
    var broadcastDetails: [BannerBroadcast] = []

    static func == (lhs: Match, rhs: Match) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    init(
        id: String,
        league: League,
        date: Date,
        name: String,
        shortName: String,
        state: GameState,
        statusDetail: String,
        home: TeamSide,
        away: TeamSide,
        broadcasts: [String],
        venue: String?,
        liveContext: MatchLiveContext = .empty
    ) {
        self.id = id
        self.league = league
        self.date = date
        self.name = name
        self.shortName = shortName
        self.state = state
        self.statusDetail = statusDetail
        self.home = home
        self.away = away
        self.broadcasts = broadcasts
        self.venue = venue
        self.liveContext = liveContext
    }

    var hasDisplayScore: Bool {
        func isUsefulScore(_ value: String?) -> Bool {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return false }
            return value != "-" && value != "--" && value != "—"
        }
        return isUsefulScore(home.score) || isUsefulScore(away.score)
    }

    func withBroadcasts(_ newBroadcasts: [String]) -> Match {
        var m = Match(id: id, league: league, date: date, name: name, shortName: shortName,
                      state: state, statusDetail: statusDetail, home: home, away: away,
                      broadcasts: newBroadcasts, venue: venue, liveContext: liveContext)
        m.canonicalID = canonicalID
        m.broadcastDetails = broadcastDetails
        return m
    }

    func withLiveContext(_ newContext: MatchLiveContext) -> Match {
        var m = Match(id: id, league: league, date: date, name: name, shortName: shortName,
                      state: state, statusDetail: statusDetail, home: home, away: away,
                      broadcasts: broadcasts, venue: venue, liveContext: newContext)
        m.canonicalID = canonicalID
        m.broadcastDetails = broadcastDetails
        return m
    }
}

// MARK: - Racing

/// A single entrant in a racing event (e.g. an F1 driver) with constructor/team info,
/// synced from the ESPN scoreboard.
struct Racer: Identifiable, Hashable {
    let id: String
    let name: String
    let shortName: String
    let teamName: String
    let place: Int?
    let flagURL: URL?
    let isWinner: Bool
}

// MARK: - Stream languages

/// A language a stream can be tagged with in playlist channel names (e.g. "EN: Sky Sports").
struct StreamLanguage: Identifiable, Hashable {
    let code: String   // lowercase tag used in channel names, e.g. "en"
    let name: String

    var id: String { code }

    nonisolated static let all: [StreamLanguage] = [
        StreamLanguage(code: "en", name: "English"),
        StreamLanguage(code: "es", name: "Spanish"),
        StreamLanguage(code: "fr", name: "French"),
        StreamLanguage(code: "de", name: "German"),
        StreamLanguage(code: "it", name: "Italian"),
        StreamLanguage(code: "pt", name: "Portuguese"),
        StreamLanguage(code: "nl", name: "Dutch"),
        StreamLanguage(code: "ar", name: "Arabic"),
        StreamLanguage(code: "tr", name: "Turkish"),
        StreamLanguage(code: "pl", name: "Polish"),
        StreamLanguage(code: "ru", name: "Russian"),
        StreamLanguage(code: "el", name: "Greek"),
    ]

    /// Other whole-word tokens that identify this language in channel names,
    /// including common country prefixes ("US:", "UK|") used by playlists.
    nonisolated var aliases: [String] {
        switch code {
        case "en": return ["english", "eng", "uk", "us", "usa", "ca", "au"]
        case "es": return ["spanish", "espanol", "esp", "mx", "latino"]
        case "fr": return ["french", "francais", "fra"]
        case "de": return ["german", "deutsch", "ger"]
        case "it": return ["italian", "italiano", "ita"]
        case "pt": return ["portuguese", "portugues", "br", "brazil"]
        case "nl": return ["dutch", "nederlands"]
        case "ar": return ["arabic", "arab"]
        case "tr": return ["turkish", "turk"]
        case "pl": return ["polish", "polska"]
        case "ru": return ["russian"]
        case "el": return ["greek", "gr"]
        default: return []
        }
    }
}

// MARK: - Playlists

enum PlaylistKind: String, Codable {
    case m3u
    case xtream
}

/// Persisted playlist configuration. Xtream secrets are migrated to Keychain and excluded from new encodes.
struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: PlaylistKind

    // M3U
    var m3uURL: String?
    var epgURL: String?

    // Xtream
    var host: String?      // e.g. https://example.com:8080
    var credentialID: UUID

    // Legacy decode-only fields. New persistence never writes these values.
    var username: String?
    var password: String?

    init(id: UUID = UUID(), name: String, kind: PlaylistKind,
         m3uURL: String? = nil, epgURL: String? = nil, host: String? = nil,
         credentialID: UUID? = nil, username: String? = nil, password: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.m3uURL = m3uURL
        self.epgURL = epgURL
        self.host = host
        self.credentialID = credentialID ?? id
        self.username = username
        self.password = password
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, m3uURL, epgURL, host, credentialID, username, password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(PlaylistKind.self, forKey: .kind)
        m3uURL = try container.decodeIfPresent(String.self, forKey: .m3uURL)
        epgURL = try container.decodeIfPresent(String.self, forKey: .epgURL)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        credentialID = try container.decodeIfPresent(UUID.self, forKey: .credentialID) ?? id
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(m3uURL, forKey: .m3uURL)
        try container.encodeIfPresent(epgURL, forKey: .epgURL)
        try container.encodeIfPresent(host, forKey: .host)
        try container.encode(credentialID, forKey: .credentialID)
    }

    var sanitizedForPersistence: Playlist {
        Playlist(id: id, name: name, kind: kind, m3uURL: m3uURL, epgURL: epgURL, host: host, credentialID: credentialID)
    }
}

/// A single playable channel/stream parsed from a playlist.
struct Channel: Identifiable, Hashable {
    let id: String
    let name: String
    let streamURL: URL
    let logoURL: URL?
    let group: String?
    let playlistID: UUID
    let playlistName: String
    var tvgId: String? = nil    // Provider EPG ID (tvg-id), preserved from M3U for guide matching
}

/// Named evidence signals that explain why a stream was surfaced for an event.
/// Multiple categories can be active simultaneously; the highest-priority one drives the badge label.
enum StreamEvidenceCategory: String, Hashable, Sendable, CaseIterable {
    /// The channel's EPG guide lists a programme whose title matches this event at its scheduled time.
    case guideListsMatch
    /// The channel's curated network is a known broadcast rights holder for this league.
    case broadcastRightsMatch
    /// Both competing team names appear in the stream title.
    case teamNameMatch
    /// The event title (e.g. "Tour de France Stage 12") appears in the stream title.
    case eventTitleMatch
    /// A recognized sports network name is part of the channel identifier.
    case networkNameMatch
    /// A league or sport keyword matches the channel name or group.
    case leagueKeyword

    var displayLabel: String {
        switch self {
        case .guideListsMatch:      return "Guide Match"
        case .broadcastRightsMatch: return "Rights Holder"
        case .teamNameMatch:        return "Teams Listed"
        case .eventTitleMatch:      return "Event Listed"
        case .networkNameMatch:     return "Broadcaster"
        case .leagueKeyword:        return "League"
        }
    }

    /// Higher priority = stronger evidence. Used to select the badge label when multiple fire.
    var priority: Int {
        switch self {
        case .guideListsMatch:      return 6
        case .broadcastRightsMatch: return 5
        case .teamNameMatch:        return 4
        case .eventTitleMatch:      return 3
        case .networkNameMatch:     return 2
        case .leagueKeyword:        return 1
        }
    }
}

/// A channel paired with a relevance score and named evidence for a given match.
struct RankedSource: Identifiable, Hashable {
    let channel: Channel
    let score: Int
    /// Named signals that explain why this channel was surfaced.
    var evidenceCategories: Set<StreamEvidenceCategory> = []
    /// EPG programme confirmed to cover this event on this channel. Non-nil when the guide matches.
    var epgProgramme: EPGProgramme? = nil
    /// Canonical channel key from the curated lineup, populated by the match-page ranking pass.
    var canonicalChannelId: String? = nil
    var id: String { channel.id }

    /// The single strongest piece of evidence, used to drive the badge label.
    var strongestEvidence: StreamEvidenceCategory? {
        evidenceCategories.max { $0.priority < $1.priority }
    }

    /// True when event-specific evidence exists (EPG match, both team names, or event title).
    /// False when only broadcaster rights or league keywords matched — those are unconfirmed candidates.
    var isConfirmed: Bool {
        evidenceCategories.contains(.guideListsMatch) ||
        evidenceCategories.contains(.teamNameMatch) ||
        evidenceCategories.contains(.eventTitleMatch)
    }

    /// v3 precision status derived from evidence. CONFIRMED maps 1:1 with isConfirmed.
    var matchStatus: MatchStatus {
        isConfirmed ? .confirmed : .possible
    }
}

/// Carries the explicitly-selected event identity from match selection into the media player.
/// PlayerView must never independently discover or replace this event.
struct MatchPlaybackContext: Identifiable, Sendable {
    let match: Match
    let channel: Channel
    let rankedSources: [RankedSource]
    /// Unique ID for this playback request. Async operations should cancel themselves when
    /// this ID no longer matches the current context, preventing stale results from landing.
    let requestGenerationID: UUID

    var id: String { "\(match.id)-\(channel.id)" }

    init(match: Match, channel: Channel, rankedSources: [RankedSource] = [], requestGenerationID: UUID = UUID()) {
        self.match = match
        self.channel = channel
        self.rankedSources = rankedSources
        self.requestGenerationID = requestGenerationID
    }

    var selectedSource: RankedSource? {
        rankedSources.first { $0.channel.id == channel.id } ?? rankedSources.first
    }
}

// MARK: - v3 Precision Stream Matching Types

/// Confidence level for a stream's association with a selected event.
enum MatchStatus: String, Hashable, Sendable {
    /// Event-specific evidence confirmed: EPG match, both team names, or event title.
    case confirmed
    /// Discovery-only: broadcaster rights, league keyword, or feed family match.
    /// The stream may carry the event but cannot be proven to do so.
    case possible
    /// Hard conflict exists — wrong sport, wrong session, non-sports channel, etc.
    case rejected
}

/// Types of hard conflicts that reject a candidate before scoring.
/// A single hard conflict makes the result `.rejected` regardless of positive evidence.
enum HardConflictType: String, Hashable, Sendable {
    case wrongSport               // HC-001: feed family incompatible with event sport
    case wrongRacingSession       // HC-010: qualifying channel for race event (or vice versa)
    case nonSportsChannelFamily   // HC-015: news / weather / cooking channel
    case wrongEventInstance       // HC-016: EPG programme is a different game/leg/session
    case sourceDisagreement       // HC-018: EPG and dynamic title disagree on which event is airing
}

struct HardConflict: Hashable, Sendable {
    let type: HardConflictType
    let description: String
}

/// Relationship between a candidate stream and the selected event.
enum EventRelationship: String, Hashable, Sendable {
    /// The stream is carrying this specific event live — the only relationship eligible
    /// for primary stream selection.
    case exactEvent
    case pregame
    case postgame
    case replay
    case highlights
    case unknown
}

/// Current playability state of a stream, independent of event identity.
enum StreamAvailabilityState: String, Hashable, Sendable {
    case online
    case offline
    /// Channel confirmed for this event but stream has not yet started.
    case placeholder
    case drmBlocked
    case geoBlocked
    case authRequired
    case unknown
}

// MARK: - News

struct ESPNArticle: Identifiable, Hashable {
    let id: String
    let headline: String
    let description: String
    let published: Date?
    let url: URL?
    let imageURL: URL?
    let league: League
    /// Author / source credit (from the real-time Now feed).
    var byline: String? = nil
    /// Content type, e.g. "Story", "Recap", "Media".
    var type: String? = nil
    /// True for ESPN+ premium articles.
    var isPremium: Bool = false
    /// Topic tags surfaced by the Now feed.
    var categories: [String] = []
}
