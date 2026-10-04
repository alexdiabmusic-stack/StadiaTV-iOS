import Foundation

@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    static let enabledDefaultsKey = "bannertv.cloudsync.enabled"
    private let lastSyncDateKey = "bannertv.cloudsync.lastSyncDate"

    private let store = NSUbiquitousKeyValueStore.default
    private var isStarted = false

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    var lastSyncDate: Date? {
        let interval = UserDefaults.standard.double(forKey: lastSyncDateKey)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    private init() {}

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        store.synchronize()
        recordSync()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled {
            store.synchronize()
            recordSync()
        }
        NotificationCenter.default.post(name: .bannertvCloudSyncDidChange, object: nil)
    }

    func save<T: Encodable>(_ value: T, for key: CloudSyncKey) {
        guard isEnabled, let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key.rawValue)
        store.synchronize()
        recordSync()
    }

    func load<T: Decodable>(_ type: T.Type, for key: CloudSyncKey) -> T? {
        guard let data = store.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Deletes a synced value regardless of whether sync is currently enabled.
    func removeValue(for key: CloudSyncKey) {
        guard store.object(forKey: key.rawValue) != nil else { return }
        store.removeObject(forKey: key.rawValue)
        store.synchronize()
    }

    /// Older builds synced favourites and watch history as channel snapshots that embedded
    /// each stream's URL — which, for Xtream providers, carries the account's username and
    /// password. Deletes any such blob still in iCloud so credentials don't linger there;
    /// callers re-save their sanitized value when sync is on. Returns the keys removed.
    @discardableResult
    func purgeLegacyStreamURLBlobs() -> Set<CloudSyncKey> {
        let marker = Data("streamURLString".utf8)
        var purged: Set<CloudSyncKey> = []
        for key in [CloudSyncKey.favoriteChannels, .watchHistory] {
            guard let data = store.data(forKey: key.rawValue), data.range(of: marker) != nil else { continue }
            store.removeObject(forKey: key.rawValue)
            purged.insert(key)
        }
        if !purged.isEmpty { store.synchronize() }
        return purged
    }

    private func recordSync() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncDateKey)
    }

    @objc private func handleExternalChange() {
        recordSync()
        NotificationCenter.default.post(name: .bannertvCloudSyncDidChange, object: nil)
    }
}

enum CloudSyncKey: String {
    case preferences = "bannertv.preferences.v1"
    /// Legacy: `[SavedChannel]` snapshots written by older builds. Read once to migrate, then removed.
    case favoriteChannels = "bannertv.favoritechannels.v1"
    /// Ordered IDs of favourite channels (no stream URLs).
    case favoriteChannelIDs = "bannertv.favoritechannelids.v1"
    case watchHistory = "bannertv.watchhistory.v1"
}

extension Notification.Name {
    static let bannertvCloudSyncDidChange = Notification.Name("bannertv.cloudSyncDidChange")
}
