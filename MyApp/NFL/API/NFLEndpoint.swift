import Foundation

nonisolated enum NFLSeasonType: String, Codable, Sendable { case preseason = "PRE", regular = "REG", postseason = "POST" }
nonisolated struct NFLWeek: Codable, Hashable, Sendable {
    let season: Int
    let seasonType: NFLSeasonType
    let week: Int
}
nonisolated struct NFLEndpoint: Hashable, Sendable {
    let path: String
    var query: [String: String] = [:]
    func url(host: String = "https://api.nfl.com") throws -> URL {
        guard var parts = URLComponents(string: host) else { throw NFLAPIError.invalidURL }
        parts.path = path
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url else { throw NFLAPIError.invalidURL }
        return url
    }
    static func week(date: Date) -> Self {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "yyyy-MM-dd"
        return Self(path: "/football/v2/weeks/date/\(f.string(from: date))")
    }
    static func weeks(season: Int, type: NFLSeasonType) -> Self { Self(path: "/football/v2/weeks/season/\(season)/seasonType/\(type.rawValue)") }
    static func weekly(_ week: NFLWeek, drives: Bool = true, replays: Bool = false, standings: Bool = false, videos: Bool = false) -> Self {
        Self(path: "/football/v2/experience/weekly-game-details", query: ["season": String(week.season), "type": week.seasonType.rawValue,
             "week": String(week.week), "includeDriveChart": String(drives), "includeReplays": String(replays),
             "includeStandings": String(standings), "includeTaggedVideos": String(videos)])
    }
    static func resource(_ name: String, week: NFLWeek) -> Self {
        Self(path: "/football/v2/\(name)", query: ["season": String(week.season), "seasonType": week.seasonType.rawValue, "week": String(week.week), "limit": "1000"])
    }
    static func seasonResource(_ name: String, season: Int) -> Self {
        Self(path: "/football/v2/\(name)", query: ["season": String(season), "limit": "1000"])
    }
    static func team(_ id: String) throws -> Self {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { throw NFLAPIError.invalidURL }
        return Self(path: "/football/v2/teams/\(id)")
    }
}
