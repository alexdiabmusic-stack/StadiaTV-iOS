import Foundation

/// Same atomic JSON cache convention as the NHL/MLB providers, namespaced per
/// league (`Caches/BannerTV/Basketball/{NBA,WNBA}/v1/`) so the two leagues'
/// snapshots can never collide on disk or in memory, even for a numerically
/// identical `providerID`.
actor BasketballGameCenterCache {
    private var memory: [BasketballGameID: BasketballGameSnapshot] = [:]
    private let directory: URL

    init(league: BasketballLeagueConfiguration, directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BannerTV/Basketball/\(league.displayName)/v1", isDirectory: true)
    }

    func load(_ id: BasketballGameID) -> BasketballGameSnapshot? {
        if let value = memory[id] { return value }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id.providerID).json")),
              let value = try? JSONDecoder().decode(BasketballGameSnapshot.self, from: data), value.gameID == id else { return nil }
        memory[id] = value; return value
    }
    func save(_ value: BasketballGameSnapshot) {
        memory[value.gameID] = value
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("\(value.gameID.providerID).json"), options: .atomic)
        } catch {
            #if DEBUG
            print("Basketball cache write failed: \(error)")
            #endif
        }
    }
}

extension BasketballGameCenterCache {
    static let nba = BasketballGameCenterCache(league: .nba)
    static let wnba = BasketballGameCenterCache(league: .wnba)
}
