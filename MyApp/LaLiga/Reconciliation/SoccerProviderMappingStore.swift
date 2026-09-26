import Foundation

/// Persists confirmed cross-provider identity mappings so the app never has to
/// re-resolve the same fixture/team/player identity on every launch (Step 36).
/// Mirrors `SoccerGameCentreCache`'s per-provider JSON-on-disk convention, but
/// namespaced separately (`.../LaLiga/idmap/v1/`) since this stores identity
/// mappings, not Game Centre snapshots. A mapping is only ever removed by
/// `invalidateMatch` — called when re-confirmation fails structurally (e.g. the
/// cached FotMob id now points at a different fixture) — never silently dropped
/// on a single transient fetch failure (Step 36).
actor SoccerProviderMappingStore {
    static let shared = SoccerProviderMappingStore()

    private struct Snapshot: Codable {
        var matches: [String: String] = [:]  // official match ID -> FotMob match ID
        var teams: [String: String] = [:]    // official team numeric ID -> FotMob team ID
        var players: [String: String] = [:]  // official player optaID -> FotMob player ID
    }

    private var snapshot: Snapshot
    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BannerTV/Soccer/LaLiga/idmap/v1", isDirectory: true)
        fileURL = dir.appendingPathComponent("mappings.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = Snapshot()
        }
    }

    func fotmobMatchID(forOfficialMatchID id: String) -> String? { snapshot.matches[id] }
    func confirmMatch(officialID: String, fotmobID: String) { snapshot.matches[officialID] = fotmobID; save() }
    func invalidateMatch(officialID: String) { snapshot.matches.removeValue(forKey: officialID); save() }

    func fotmobTeamID(forOfficialTeamID id: String) -> String? { snapshot.teams[id] }
    func confirmTeam(officialID: String, fotmobID: String) { snapshot.teams[officialID] = fotmobID; save() }

    func fotmobPlayerID(forOptaID id: String) -> String? { snapshot.players[id] }
    func confirmPlayer(optaID: String, fotmobID: String) { snapshot.players[optaID] = fotmobID; save() }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            #if DEBUG
            print("LaLiga provider-mapping store write failed: \(error)")
            #endif
        }
    }
}
