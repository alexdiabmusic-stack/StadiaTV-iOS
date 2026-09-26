import Foundation

nonisolated protocol CFLGameCenterServing: Sendable {
    func load(gameID: String, date: Date, previous: CFLGameState?, details: Bool) async throws -> CFLGameState
}
actor CFLGameCenterService: CFLGameCenterServing {
    private let client: any CFLClientProtocol
    private let seasonIdentity: CFLSeasonIdentity
    private let livePlayProvider: (any CFLLivePlayProvider)?
    init(client: any CFLClientProtocol = CFLClient.shared, seasonIdentity: CFLSeasonIdentity = .shared, livePlayProvider: (any CFLLivePlayProvider)? = nil) {
        self.client = client
        self.seasonIdentity = seasonIdentity
        self.livePlayProvider = livePlayProvider
    }
    func load(gameID: String, date: Date, previous: CFLGameState?, details: Bool) async throws -> CFLGameState {
        let year: Int
        let seasonID: Int
        if let previous { year = previous.year; seasonID = previous.seasonID }
        else {
            year = Calendar.current.component(.year, from: date)
            seasonID = try await seasonIdentity.seasonID(for: year)
        }
        let fixture = try await client.get(.fixture(id: gameID), as: CFLValue.self, maxAge: 0)
        let teamsList = try await client.get(.teams, as: [CFLValue].self, maxAge: 3600)
        let teams = Dictionary(teamsList.compactMap { team in team["ID"].string.map { ($0, team) } }, uniquingKeysWith: { _, new in new })
        let venuesList = try await client.get(.venues, as: [CFLValue].self, maxAge: 86400)
        let venues = Dictionary(venuesList.compactMap { venue in venue["ID"].string.map { ($0, venue) } }, uniquingKeysWith: { _, new in new })
        guard var game = CFLFixtureMapper.game(fixture, teams: teams, venues: venues, seasonID: seasonID, year: year) else { throw CFLAPIError.invalidResponse }
        if details, let livePlayProvider {
            // A missing/failing PBP provider must never take down score/status — degrade
            // to empty drives/plays rather than throwing (Step 42).
            async let drivesRequest: [FootballGameDrive]? = try? livePlayProvider.drives(fixtureID: gameID)
            async let playsRequest: [FootballPlay]? = try? livePlayProvider.plays(fixtureID: gameID)
            if let drives = await drivesRequest { game.drives = drives }
            if let plays = await playsRequest { game.plays = plays }
        } else if let previous {
            game.drives = previous.drives
            game.plays = previous.plays
        }
        return game
    }
}
actor CFLGameCache {
    static let shared = CFLGameCache()
    private var memory: [String: CFLGameState] = [:]
    private func url(_ id: String) -> URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = root.appendingPathComponent("BannerTV/CFL/v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(name + ".json")
    }
    func load(_ id: String) -> CFLGameState? {
        if let game = memory[id] { return game }
        guard let url = url(id), let data = try? Data(contentsOf: url), let game = try? JSONDecoder().decode(CFLGameState.self, from: data), game.id == id else { return nil }
        memory[id] = game; return game
    }
    func save(_ game: CFLGameState) {
        memory[game.id] = game
        if memory.count > 40 { memory = [game.id: game] }
        if let url = url(game.id), let data = try? JSONEncoder().encode(game) { try? data.write(to: url, options: .atomic) }
    }
}
