import Foundation

nonisolated struct MLBEndpoint: Sendable {
    let path: String
    var query: [String: String] = [:]
    func url(base: String = "https://statsapi.mlb.com") throws -> URL {
        guard var components = URLComponents(string: base) else { throw MLBAPIError.invalidURL }
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw MLBAPIError.invalidURL }
        return url
    }
    static func schedule(start: Date, end: Date? = nil, teamID: Int? = nil, season: Int? = nil, gameTypes: String? = nil) -> Self {
        var query = ["sportId": "1", "hydrate": "team,linescore,probablePitcher,broadcasts"]
        if let end { query["startDate"] = MLBDate.day(start); query["endDate"] = MLBDate.day(end) }
        else { query["date"] = MLBDate.day(start) }
        query["teamId"] = teamID.map(String.init); query["season"] = season.map(String.init); query["gameTypes"] = gameTypes
        return Self(path: "/api/v1/schedule", query: query)
    }
    static func game(_ id: Int, resource: String) -> Self { Self(path: "/api/v1/game/\(id)/\(resource)") }
    static func feed(_ id: Int, statusOnly: Bool = false) -> Self {
        Self(path: "/api/v1.1/game/\(id)/feed/live", query: statusOnly ? ["fields": "gamePk,metaData,timeStamp,gameData,status,abstractGameState,codedGameState,detailedState,statusCode,abstractGameCode"] : [:])
    }
}
nonisolated enum MLBDate {
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "America/New_York"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let f = ISO8601DateFormatter()
        if let date = f.date(from: value) { return date }
        f.formatOptions.insert(.withFractionalSeconds); return f.date(from: value)
    }
}
