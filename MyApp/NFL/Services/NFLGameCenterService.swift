import Foundation

nonisolated protocol NFLGameCenterServing: Sendable {
    func load(gameID: String, date: Date, previous: NFLGameState?, details: Bool) async throws -> NFLGameState
}
actor NFLGameCenterService: NFLGameCenterServing {
    private let client: NFLShieldClient
    init(client: NFLShieldClient = .shared) { self.client = client }
    func load(gameID: String, date: Date, previous: NFLGameState?, details: Bool) async throws -> NFLGameState {
        let week: NFLWeek
        if let previous { week = previous.week } else { week = try await client.week(for: date) }
        if details || previous == nil {
            async let detailsRequest = client.weeklyGameDetails(week)
            async let rosterRequest = try? client.rosters(season: week.season)
            let response = try await detailsRequest
            let roster = await rosterRequest
            try Task.checkCancellation()
            let records = roster?["rosters"].array ?? []
            let metadata = Dictionary(records.compactMap { row in row["team"]["id"].string.map { ($0, row["team"]) } }, uniquingKeysWith: { _, new in new })
            let players = Dictionary(records.flatMap { $0["persons"].array }.compactMap { person -> (String, String)? in
                guard let id = person["id"].string, let name = person["displayName"].string else { return nil }; return (id, name)
            }, uniquingKeysWith: { _, new in new })
            guard let raw = response.games.first(where: { $0["id"].string == gameID }), let game = NFLGameMapper.game(raw, metadata: metadata, players: players) else { throw NFLAPIError.invalidResponse }
            if let previous, (game.offset ?? 0) < (previous.offset ?? 0) { return previous }
            return game
        }
        guard let previous else { throw NFLAPIError.invalidResponse }
        let response = try await client.liveGameSummaries(week)
        guard let summary = response["data"].array.first(where: { $0["gameId"].string == gameID }) else { throw NFLAPIError.invalidResponse }
        return NFLGameMapper.applySummary(summary, to: previous)
    }
}
actor NFLGameCache {
    static let shared = NFLGameCache()
    private var memory: [String: NFLGameState] = [:]
    private func url(_ id: String) -> URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = root.appendingPathComponent("BannerTV/NFL/v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(name + ".json")
    }
    func load(_ id: String) -> NFLGameState? {
        if let game = memory[id] { return game }
        guard let url = url(id), let data = try? Data(contentsOf: url), let game = try? JSONDecoder().decode(NFLGameState.self, from: data), game.id == id else { return nil }
        memory[id] = game; return game
    }
    func save(_ game: NFLGameState) {
        memory[game.id] = game
        if memory.count > 40 { memory = [game.id: game] }
        if let url = url(game.id), let data = try? JSONEncoder().encode(game) { try? data.write(to: url, options: .atomic) }
    }
}
