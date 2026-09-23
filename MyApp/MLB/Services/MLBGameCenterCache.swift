import Foundation

/// Uses the same atomic JSON cache convention as the NHL provider, with a distinct
/// namespace and gamePk keys. No database or server is introduced.
actor MLBGameCenterCache {
    static let shared = MLBGameCenterCache()
    private var memory: [Int: BaseballGameSnapshot] = [:]
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BannerTV/MLB/v1", isDirectory: true)
    }
    func load(_ id: Int) -> BaseballGameSnapshot? {
        if let value = memory[id] { return value }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")),
              let value = try? JSONDecoder().decode(BaseballGameSnapshot.self, from: data), value.gamePk == id else { return nil }
        memory[id] = value; return value
    }
    func save(_ value: BaseballGameSnapshot) {
        memory[value.gamePk] = value
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("\(value.gamePk).json"), options: .atomic)
        } catch {
            #if DEBUG
            print("MLB cache write failed: \(error)")
            #endif
        }
    }
}
