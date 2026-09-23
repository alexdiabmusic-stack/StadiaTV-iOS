import Foundation

actor F1SessionCache {
    static let shared = F1SessionCache()
    private let directory: URL
    init(directory: URL? = nil) { self.directory = directory ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appendingPathComponent("BannerTV/F1/v1") }
    func load(_ id: String) -> F1SessionState? {
        guard let data = try? Data(contentsOf: file(id)), let state = try? JSONDecoder().decode(F1SessionState.self, from: data), state.identity == id else { return nil }
        return state
    }
    func save(_ value: F1SessionState) {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try JSONEncoder().encode(value).write(to: file(value.identity), options: .atomic) }
        catch {
            #if DEBUG
            print("F1 cache: \(error)")
            #endif
        }
    }
    private func file(_ id: String) -> URL { directory.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json") }
}
