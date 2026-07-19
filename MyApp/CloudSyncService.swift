import Foundation

@MainActor
final class CloudSyncService {
    static let shared = CloudSyncService()

    static let enabledDefaultsKey = "stadiatv.cloudsync.enabled"

    private let store = NSUbiquitousKeyValueStore.default
    private var isStarted = false

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
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
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { store.synchronize() }
        NotificationCenter.default.post(name: .stadiatvCloudSyncDidChange, object: nil)
    }

    func save<T: Encodable>(_ value: T, for key: CloudSyncKey) {
        guard isEnabled, let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key.rawValue)
    }

    func load<T: Decodable>(_ type: T.Type, for key: CloudSyncKey) -> T? {
        guard let data = store.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    @objc private func handleExternalChange() {
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
