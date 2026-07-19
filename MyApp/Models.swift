import Foundation

// MARK: - Leagues / Sports catalog

/// A sport grouping used to organize the league picker.
enum SportGroup: String, CaseIterable, Identifiable {
    case football = "Football"
    case basketball = "Basketball"
    case baseball = "Baseball"
    case hockey = "Hockey"
    case soccer = "Soccer"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .football: return "football.fill"
        case .basketball: return "basketball.fill"
        case .baseball: return "baseball.fill"
        case .hockey: return "hockey.puck.fill"
        case .soccer: return "soccerball"
        }
    }
}

/// A single ESPN league / competition.
/// `path` is the ESPN URL segment, e.g. "football/nfl" or "soccer/eng.1".
struct League: Identifiable, Hashable {
    let id: String        // stable identifier == path
    let name: String      // display name
    let shortName: String // compact label
    let path: String      // ESPN api path segment
    let group: SportGroup
    /// Keywords used by the source-matching algorithm (broadcast/league aliases).
    let keywords: [String]

    init(name: String, shortName: String, path: String, group: SportGroup, keywords: [String] = []) {
        self.id = path
        self.name = name
        self.shortName = shortName
        self.path = path
        self.group = group
        self.keywords = keywords
    }

    static let all: [League] = [
        // Football
        League(name: "NFL", shortName: "NFL", path: "football/nfl", group: .football,
               keywords: ["nfl", "football", "sunday", "monday night", "thursday night"]),
        League(name: "College Football", shortName: "NCAAF", path: "football/college-football", group: .football,
               keywords: ["ncaaf", "college football", "cfb", "football"]),
        League(name: "CFL", shortName: "CFL", path: "football/cfl", group: .football,
               keywords: ["cfl", "canadian football", "football"]),
        League(name: "UFL", shortName: "UFL", path: "football/ufl", group: .football,
               keywords: ["ufl", "spring football", "football"]),
        // Basketball
        League(name: "NBA", shortName: "NBA", path: "basketball/nba", group: .basketball,
               keywords: ["nba", "basketball"]),
        League(name: "WNBA", shortName: "WNBA", path: "basketball/wnba", group: .basketball,
               keywords: ["wnba", "basketball"]),
        League(name: "NBA G League", shortName: "G League", path: "basketball/nba-development", group: .basketball,
               keywords: ["g league", "nba development", "basketball"]),
        League(name: "Men's College Basketball", shortName: "NCAAM", path: "basketball/mens-college-basketball", group: .basketball,
               keywords: ["ncaam", "college basketball", "cbb", "basketball"]),
        League(name: "Women's College Basketball", shortName: "NCAAW", path: "basketball/womens-college-basketball", group: .basketball,
               keywords: ["ncaaw", "college basketball", "basketball"]),
        League(name: "NBL", shortName: "NBL", path: "basketball/nbl", group: .basketball,
               keywords: ["nbl", "australian basketball", "basketball"]),
        // Baseball
        League(name: "MLB", shortName: "MLB", path: "baseball/mlb", group: .baseball,
               keywords: ["mlb", "baseball"]),
        League(name: "College Baseball", shortName: "NCAA BSB", path: "baseball/college-baseball", group: .baseball,
               keywords: ["college baseball", "baseball"]),
        League(name: "World Baseball Classic", shortName: "WBC", path: "baseball/world-baseball-classic", group: .baseball,
               keywords: ["world baseball classic", "wbc", "baseball"]),
        // Hockey
        League(name: "NHL", shortName: "NHL", path: "hockey/nhl", group: .hockey,
               keywords: ["nhl", "hockey"]),
        League(name: "Men's College Hockey", shortName: "NCAA-M", path: "hockey/mens-college-hockey", group: .hockey,
               keywords: ["college hockey", "ncaa hockey", "hockey"]),
        League(name: "Women's College Hockey", shortName: "NCAA-W", path: "hockey/womens-college-hockey", group: .hockey,
               keywords: ["college hockey", "ncaa hockey", "hockey"]),
        // Soccer
        League(name: "Premier League", shortName: "EPL", path: "soccer/eng.1", group: .soccer,
               keywords: ["premier league", "epl", "english", "soccer", "football"]),
        League(name: "EFL Championship", shortName: "EFL", path: "soccer/eng.2", group: .soccer,
               keywords: ["championship", "efl", "english", "soccer"]),
        League(name: "MLS", shortName: "MLS", path: "soccer/usa.1", group: .soccer,
               keywords: ["mls", "major league soccer", "soccer"]),
        League(name: "NWSL", shortName: "NWSL", path: "soccer/usa.nwsl", group: .soccer,
               keywords: ["nwsl", "women's soccer", "soccer"]),
        League(name: "La Liga", shortName: "La Liga", path: "soccer/esp.1", group: .soccer,
               keywords: ["la liga", "spanish", "soccer", "laliga"]),
        League(name: "Serie A", shortName: "Serie A", path: "soccer/ita.1", group: .soccer,
               keywords: ["serie a", "italian", "soccer"]),
        League(name: "Bundesliga", shortName: "Bundesliga", path: "soccer/ger.1", group: .soccer,
               keywords: ["bundesliga", "german", "soccer"]),
        League(name: "Ligue 1", shortName: "Ligue 1", path: "soccer/fra.1", group: .soccer,
               keywords: ["ligue 1", "french", "soccer"]),
        League(name: "Liga MX", shortName: "Liga MX", path: "soccer/mex.1", group: .soccer,
               keywords: ["liga mx", "mexican", "soccer"]),
        League(name: "Eredivisie", shortName: "Eredivisie", path: "soccer/ned.1", group: .soccer,
               keywords: ["eredivisie", "dutch", "soccer"]),
        League(name: "Primeira Liga", shortName: "Portugal", path: "soccer/por.1", group: .soccer,
               keywords: ["primeira liga", "portuguese", "soccer"]),
        League(name: "Saudi Pro League", shortName: "Saudi", path: "soccer/ksa.1", group: .soccer,
               keywords: ["saudi", "roshn", "soccer"]),
        League(name: "Champions League", shortName: "UCL", path: "soccer/uefa.champions", group: .soccer,
               keywords: ["champions league", "ucl", "uefa", "soccer"]),
        League(name: "Europa League", shortName: "UEL", path: "soccer/uefa.europa", group: .soccer,
               keywords: ["europa league", "uel", "uefa", "soccer"]),
        League(name: "FIFA World Cup", shortName: "World Cup", path: "soccer/fifa.world", group: .soccer,
               keywords: ["world cup", "fifa", "soccer"]),
        League(name: "Women's World Cup", shortName: "WWC", path: "soccer/fifa.wwc", group: .soccer,
               keywords: ["women's world cup", "fifa", "soccer"]),
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
    /// ESPN team id, used to load rosters and team detail. May be nil for some sports.
    var teamID: String? = nil
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

    static func == (lhs: Match, rhs: Match) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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

    // Xtream
    var host: String?      // e.g. https://example.com:8080
    var credentialID: UUID

    // Legacy decode-only fields. New persistence never writes these values.
    var username: String?
    var password: String?

    init(id: UUID = UUID(), name: String, kind: PlaylistKind,
         m3uURL: String? = nil, host: String? = nil,
         credentialID: UUID? = nil, username: String? = nil, password: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.m3uURL = m3uURL
        self.host = host
        self.credentialID = credentialID ?? id
        self.username = username
        self.password = password
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, m3uURL, host, credentialID, username, password
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(PlaylistKind.self, forKey: .kind)
        m3uURL = try container.decodeIfPresent(String.self, forKey: .m3uURL)
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
        try container.encodeIfPresent(host, forKey: .host)
        try container.encode(credentialID, forKey: .credentialID)
    }

    var sanitizedForPersistence: Playlist {
        Playlist(id: id, name: name, kind: kind, m3uURL: m3uURL, host: host, credentialID: credentialID)
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
}

/// A channel paired with a relevance score for a given match.
struct RankedSource: Identifiable, Hashable {
    let channel: Channel
    let score: Int
    var id: String { channel.id }
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
