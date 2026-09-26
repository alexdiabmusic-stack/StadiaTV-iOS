import Foundation

/// Same atomic JSON cache convention as NHL/MLB/NBA, namespaced per provider
/// (`Caches/BannerTV/Soccer/{provider}/v1/{matchId}.json`) so two soccer providers
/// (EPL, MLS, ...) sharing this one cache type can never collide on disk or in
/// memory. No database or server is introduced.
actor SoccerGameCentreCache {
    private var memory: [String: SoccerGameCentreSnapshot] = [:]
    private let directory: URL

    init(provider: String, directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BannerTV/Soccer/\(provider)/v1", isDirectory: true)
    }

    func load(_ matchID: String) -> SoccerGameCentreSnapshot? {
        if let value = memory[matchID] { return value }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(matchID).json")),
              let value = try? JSONDecoder().decode(SoccerGameCentreSnapshot.self, from: data), value.matchID == matchID else { return nil }
        memory[matchID] = value
        return value
    }

    func save(_ value: SoccerGameCentreSnapshot) {
        memory[value.matchID] = value
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("\(value.matchID).json"), options: .atomic)
        } catch {
            #if DEBUG
            print("Soccer Game Centre cache write failed: \(error)")
            #endif
        }
    }
}
