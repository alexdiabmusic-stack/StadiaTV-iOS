import Foundation

/// Every path here was hit live against the real host this session; see
/// CFL-INTEGRATION.md for the verification notes. `fixtures` deliberately always
/// carries an explicit `limit` — `/api/seasons/{id}/fixtures` and a bare
/// `/api/fixtures?season_id=` both silently default-paginate to 15 rows (verified:
/// a 95-game 2026 season returned only 15 without it), which would have quietly
/// dropped 80 games from the schedule.
nonisolated struct CFLEndpoint: Sendable {
    let path: String
    var query: [String: String] = [:]
    func url(base: String) throws -> URL {
        guard var components = URLComponents(string: base) else { throw CFLAPIError.invalidURL }
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw CFLAPIError.invalidURL }
        return url
    }
    // MARK: - echo.pims.cfl.ca
    static let seasons = Self(path: "/api/seasons")
    static let teams = Self(path: "/api/teams")
    static let venues = Self(path: "/api/venues")
    static func fixtures(seasonID: Int) -> Self { Self(path: "/api/fixtures", query: ["season_id": String(seasonID), "limit": "300"]) }
    static func fixture(id: String) -> Self { Self(path: "/api/fixtures/\(id)") }
    static func roster(teamID: String) -> Self { Self(path: "/api/teams/\(teamID)/roster") }
    static func teamRecords(seasonID: Int) -> Self { Self(path: "/api/stats/teamrecords", query: ["season_id": String(seasonID), "limit": "20"]) }
    static func playerRecords(seasonID: Int, teamID: String? = nil) -> Self {
        var query = ["season_id": String(seasonID), "limit": "100"]
        if let teamID { query["team_id"] = teamID }
        return Self(path: "/api/stats/playerrecords", query: query)
    }
    static func standings(year: Int) -> Self { Self(path: "/api/standings/\(year)") }
    // MARK: - api.stats.cfl.ca (leaders only — never polled during a live Game Centre)
    static func leaders(year: Int) -> Self { Self(path: "/stats/leaders/\(year)") }
}
