import Foundation

@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    static let enabledDefaultsKey = "stadiatv.cloudsync.enabled"
    private let lastSyncDateKey = "stadiatv.cloudsync.lastSyncDate"

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
        NotificationCenter.default.post(name: .stadiatvCloudSyncDidChange, object: nil)
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

    private func recordSync() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncDateKey)
    }

    @objc private func handleExternalChange() {
        recordSync()
        NotificationCenter.default.post(name: .stadiatvCloudSyncDidChange, object: nil)
    }
}

enum CloudSyncKey: String {
    case preferences = "stadiatv.preferences.v1"
    case favoriteChannels = "stadiatv.favoritechannels.v1"
    case watchHistory = "stadiatv.watchhistory.v1"
}

extension Notification.Name {
    static let stadiatvCloudSyncDidChange = Notification.Name("stadiatv.cloudSyncDidChange")
}
