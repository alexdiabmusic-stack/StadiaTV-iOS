import Foundation

/// Uses the same atomic JSON cache convention as the NHL/MLB providers, with a
/// distinct namespace and gameID keys. No database or server is introduced.
actor NBAGameCenterCache {
    static let shared = NBAGameCenterCache()
    private var memory: [String: BasketballGameSnapshot] = [:]
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BannerTV/NBA/v1", isDirectory: true)
    }
    func load(_ id: NBAProviderGameID) -> BasketballGameSnapshot? {
        if let value = memory[id.rawValue] { return value }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id.rawValue).json")),
              let value = try? JSONDecoder().decode(BasketballGameSnapshot.self, from: data), value.gameID == id else { return nil }
        memory[id.rawValue] = value; return value
    }
    func save(_ value: BasketballGameSnapshot) {
        memory[value.gameID.rawValue] = value
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("\(value.gameID.rawValue).json"), options: .atomic)
        } catch {
            #if DEBUG
            print("NBA cache write failed: \(error)")
            #endif
        }
    }
}
