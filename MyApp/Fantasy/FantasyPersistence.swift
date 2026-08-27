import Foundation

nonisolated struct FantasyCachePolicy: Sendable {
    let playerDirectoryTTL: TimeInterval = 24 * 60 * 60
    let leagueMetadataTTL: TimeInterval = 6 * 60 * 60
    let rosterTTL: TimeInterval = 5 * 60
    let matchupTTL: TimeInterval = 60

    nonisolated func isFresh(_ date: Date?, lifetime: TimeInterval, now: Date = Date()) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < lifetime
    }
}

nonisolated struct FantasyPersistentSnapshot: Codable, Sendable {
    var connection: FantasyConnection?
    var settings = FantasySettings()
    var leagues: [FantasyLeague] = []
    var leagueUsersByLeagueID: [String: [FantasyTeam]] = [:]
    var rostersByLeagueID: [String: [FantasyRoster]] = [:]
    var matchupsByLeagueAndWeek: [String: FantasyMatchup] = [:]
    var standingsByLeagueID: [String: [FantasyStanding]] = [:]
    var lightweightPlayersByID: [String: FantasyPlayer] = [:]
    var cachedPlayerGamesByLeagueID: [String: [CachedFantasyPlayerGame]] = [:]
    var updatedAtByKey: [String: Date] = [:]

    init() {}

    enum CodingKeys: String, CodingKey {
        case connection, settings, leagues, leagueUsersByLeagueID, rostersByLeagueID
        case matchupsByLeagueAndWeek, standingsByLeagueID, lightweightPlayersByID
        case cachedPlayerGamesByLeagueID, updatedAtByKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connection = try container.decodeIfPresent(FantasyConnection.self, forKey: .connection)
        settings = try container.decodeIfPresent(FantasySettings.self, forKey: .settings) ?? FantasySettings()
        leagues = try container.decodeIfPresent([FantasyLeague].self, forKey: .leagues) ?? []
        leagueUsersByLeagueID = try container.decodeIfPresent([String: [FantasyTeam]].self, forKey: .leagueUsersByLeagueID) ?? [:]
        rostersByLeagueID = try container.decodeIfPresent([String: [FantasyRoster]].self, forKey: .rostersByLeagueID) ?? [:]
        matchupsByLeagueAndWeek = try container.decodeIfPresent([String: FantasyMatchup].self, forKey: .matchupsByLeagueAndWeek) ?? [:]
        standingsByLeagueID = try container.decodeIfPresent([String: [FantasyStanding]].self, forKey: .standingsByLeagueID) ?? [:]
        lightweightPlayersByID = try container.decodeIfPresent([String: FantasyPlayer].self, forKey: .lightweightPlayersByID) ?? [:]
        cachedPlayerGamesByLeagueID = try container.decodeIfPresent([String: [CachedFantasyPlayerGame]].self, forKey: .cachedPlayerGamesByLeagueID) ?? [:]
        updatedAtByKey = try container.decodeIfPresent([String: Date].self, forKey: .updatedAtByKey) ?? [:]
    }
}

actor FantasyPersistenceStore {
    static let shared = FantasyPersistenceStore()

    private let defaults: UserDefaults
    private let snapshotKey: String
    private let legacyPlayerDirectoryKey: String
    private let mappingsKey: String
    private let cacheDirectoryURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        defaults: UserDefaults = .standard,
        snapshotKey: String = "stadiatv.fantasy.snapshot.v1",
        playerDirectoryKey: String = "stadiatv.fantasy.sleeper.players.nfl.v1",
        mappingsKey: String = "stadiatv.fantasy.playerMappings.v1",
        cacheDirectoryURL: URL? = nil
    ) {
        self.defaults = defaults
        self.snapshotKey = snapshotKey
        self.legacyPlayerDirectoryKey = playerDirectoryKey
        self.mappingsKey = mappingsKey
        self.cacheDirectoryURL = cacheDirectoryURL ?? Self.defaultCacheDirectoryURL()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadSnapshot() -> FantasyPersistentSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let decoded = try? decoder.decode(FantasyPersistentSnapshot.self, from: data) else {
            return FantasyPersistentSnapshot()
        }
        return decoded
    }

    func saveSnapshot(_ snapshot: FantasyPersistentSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    func loadPlayerDirectory(provider: FantasyProvider, sport: FantasySport) -> CachedFantasyPlayerDirectory? {
        let fileURL = playerDirectoryFileURL(provider: provider, sport: sport)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode(CachedFantasyPlayerDirectory.self, from: data) {
            return decoded
        }

        guard provider == .sleeper, sport == .nfl,
              let legacyData = defaults.data(forKey: legacyPlayerDirectoryKey),
              let legacyDirectory = try? decoder.decode(CachedFantasyPlayerDirectory.self, from: legacyData) else { return nil }
        savePlayerDirectory(legacyDirectory, provider: provider, sport: sport)
        defaults.removeObject(forKey: legacyPlayerDirectoryKey)
        return legacyDirectory
    }

    func savePlayerDirectory(_ directory: CachedFantasyPlayerDirectory, provider: FantasyProvider, sport: FantasySport) {
        guard let data = try? encoder.encode(directory) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        try? data.write(to: playerDirectoryFileURL(provider: provider, sport: sport), options: [.atomic])
    }

    func loadMappings() -> [String: StadiaPlayerIdentity] {
        guard let data = defaults.data(forKey: mappingsKey) else { return [:] }
        return (try? decoder.decode([String: StadiaPlayerIdentity].self, from: data)) ?? [:]
    }

    func saveMappings(_ mappings: [String: StadiaPlayerIdentity]) {
        guard let data = try? encoder.encode(mappings) else { return }
        defaults.set(data, forKey: mappingsKey)
    }

    func removeConnectionAndCaches(provider: FantasyProvider) {
        var snapshot = loadSnapshot()
        if snapshot.connection?.provider == provider {
            snapshot.connection = nil
        }
        snapshot.settings.selectedLeagueID = nil
        snapshot.leagues.removeAll { $0.provider == provider }
        snapshot.leagueUsersByLeagueID.removeAll()
        snapshot.rostersByLeagueID.removeAll()
        snapshot.matchupsByLeagueAndWeek.removeAll()
        snapshot.standingsByLeagueID.removeAll()
        snapshot.lightweightPlayersByID = snapshot.lightweightPlayersByID.filter { $0.value.provider != provider }
        snapshot.cachedPlayerGamesByLeagueID.removeAll()
        snapshot.updatedAtByKey.removeAll()
        saveSnapshot(snapshot)
        if provider == .sleeper {
            defaults.removeObject(forKey: legacyPlayerDirectoryKey)
            try? FileManager.default.removeItem(at: playerDirectoryFileURL(provider: .sleeper, sport: .nfl))
        }
        if provider == .espn {
            try? FileManager.default.removeItem(at: playerDirectoryFileURL(provider: .espn, sport: .nhl))
        }
    }

    func removeSleeperConnectionAndCaches() {
        removeConnectionAndCaches(provider: .sleeper)
    }

    private func playerDirectoryFileURL(provider: FantasyProvider, sport: FantasySport) -> URL {
        cacheDirectoryURL.appendingPathComponent("\(provider.rawValue)-\(sport.rawValue)-players.json")
    }

    private nonisolated static func defaultCacheDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("StadiaTV/Fantasy", isDirectory: true)
    }
}

nonisolated struct CachedFantasyPlayerDirectory: Codable, Sendable {
    let provider: FantasyProvider
    let sport: FantasySport
    let fetchedAt: Date
    let playersByID: [String: FantasyPlayer]
}

actor SharedRequestDeduplicator<Key: Hashable & Sendable, Value: Sendable> {
    private var tasks: [Key: Task<Value, Error>] = [:]

    func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let task = tasks[key] { return try await task.value }
        let task = Task { try await operation() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}
