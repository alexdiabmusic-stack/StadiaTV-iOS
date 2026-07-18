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
        // Basketball
        League(name: "NBA", shortName: "NBA", path: "basketball/nba", group: .basketball,
               keywords: ["nba", "basketball"]),
        League(name: "WNBA", shortName: "WNBA", path: "basketball/wnba", group: .basketball,
               keywords: ["wnba", "basketball"]),
        League(name: "Men's College Basketball", shortName: "NCAAM", path: "basketball/mens-college-basketball", group: .basketball,
               keywords: ["ncaam", "college basketball", "cbb", "basketball"]),
        League(name: "Women's College Basketball", shortName: "NCAAW", path: "basketball/womens-college-basketball", group: .basketball,
               keywords: ["ncaaw", "college basketball", "basketball"]),
        // Baseball
        League(name: "MLB", shortName: "MLB", path: "baseball/mlb", group: .baseball,
               keywords: ["mlb", "baseball"]),
        League(name: "College Baseball", shortName: "NCAA BSB", path: "baseball/college-baseball", group: .baseball,
               keywords: ["college baseball", "baseball"]),
        // Hockey
        League(name: "NHL", shortName: "NHL", path: "hockey/nhl", group: .hockey,
               keywords: ["nhl", "hockey"]),
        // Soccer
        League(name: "Premier League", shortName: "EPL", path: "soccer/eng.1", group: .soccer,
               keywords: ["premier league", "epl", "english", "soccer", "football"]),
        League(name: "MLS", shortName: "MLS", path: "soccer/usa.1", group: .soccer,
               keywords: ["mls", "major league soccer", "soccer"]),
        League(name: "La Liga", shortName: "La Liga", path: "soccer/esp.1", group: .soccer,
               keywords: ["la liga", "spanish", "soccer", "laliga"]),
        League(name: "Serie A", shortName: "Serie A", path: "soccer/ita.1", group: .soccer,
               keywords: ["serie a", "italian", "soccer"]),
        League(name: "Bundesliga", shortName: "Bundesliga", path: "soccer/ger.1", group: .soccer,
               keywords: ["bundesliga", "german", "soccer"]),
        League(name: "Ligue 1", shortName: "Ligue 1", path: "soccer/fra.1", group: .soccer,
               keywords: ["ligue 1", "french", "soccer"]),
        League(name: "Champions League", shortName: "UCL", path: "soccer/uefa.champions", group: .soccer,
               keywords: ["champions league", "ucl", "uefa", "soccer"]),
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

/// Persisted playlist configuration (credentials / URL).
struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var kind: PlaylistKind

    // M3U
    var m3uURL: String?

    // Xtream
    var host: String?      // e.g. http://example.com:8080
    var username: String?
    var password: String?

    init(id: UUID = UUID(), name: String, kind: PlaylistKind,
         m3uURL: String? = nil, host: String? = nil,
         username: String? = nil, password: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.m3uURL = m3uURL
        self.host = host
        self.username = username
        self.password = password
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
