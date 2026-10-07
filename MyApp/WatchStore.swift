import Foundation
import SwiftUI
import Combine

/// A persistable snapshot of a channel so watch history survives app restarts and
/// playlist refreshes.
///
/// Deliberately holds no stream URL: Xtream stream URLs embed the account's username and
/// password in their path, and these snapshots are written to UserDefaults (so into device
/// backups) and to iCloud key-value storage. Playable channels are rebuilt from live
/// provider data by `PlaylistStore.channel(for:)`. Older builds did persist the URL; the
/// extra `streamURLString` key in those blobs is ignored when decoding and dropped on the
/// next save.
struct SavedChannel: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let logoURLString: String?
    let group: String?
    let playlistID: UUID
    let playlistName: String

    init(channel: Channel) {
        self.id = channel.id
        self.name = channel.name
        self.logoURLString = channel.logoURL?.absoluteString
        self.group = channel.group
        self.playlistID = channel.playlistID
        self.playlistName = channel.playlistName
    }
}

/// A dwell-confirmed recent channel for fast channel navigation.
struct RecentEntry: Codable, Hashable, Identifiable {
    let id: String
    let saved: SavedChannel
    var watchedAt: Date

    init(channel: Channel) {
        self.id = channel.id
        self.saved = SavedChannel(channel: channel)
        self.watchedAt = Date()
    }
}

/// One "continue watching" entry.
struct WatchHistoryEntry: Codable, Hashable, Identifiable {
    var saved: SavedChannel
    var lastWatched: Date

    var id: String { saved.id }
}

/// Owns the watch history ("continue watching") and dwell-confirmed recents.
///
/// Favourite channels live in `ChannelPreferencesStore`, the single source of truth shared
/// with the channel browser and Home; the favourite methods here forward to it so the
/// player's heart and every list agree.
@MainActor
final class WatchStore: ObservableObject {
    @Published private(set) var history: [WatchHistoryEntry] = []
    /// Dwell-confirmed recent channels for fast channel navigation (device-local, not cloud-synced).
    @Published private(set) var recents: [RecentEntry] = []

    private let channelPreferences: ChannelPreferencesStore
    private var preferencesObservation: AnyCancellable?

    private let historyKey = "bannertv.watchhistory.v1"
    private let recentsKey = "bannertv.recents.v1"
    private let historyLimit = 20
    private let recentsLimit = 20

    /// Marks blobs written by builds that stored each channel's stream URL.
    private static let legacyStreamURLMarker = Data("streamURLString".utf8)

    convenience init() {
        self.init(channelPreferences: ChannelPreferencesStore())
    }

    init(channelPreferences: ChannelPreferencesStore) {
        self.channelPreferences = channelPreferences
        CloudSyncService.shared.start()

        var rewriteLocalBlobs = false
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([WatchHistoryEntry].self, from: data) {
            history = decoded
            rewriteLocalBlobs = rewriteLocalBlobs || data.range(of: Self.legacyStreamURLMarker) != nil
        } else if let cloud: [WatchHistoryEntry] = CloudSyncService.shared.load([WatchHistoryEntry].self, for: .watchHistory) {
            history = cloud
        }
        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let decoded = try? JSONDecoder().decode([RecentEntry].self, from: data) {
            recents = decoded
            rewriteLocalBlobs = rewriteLocalBlobs || data.range(of: Self.legacyStreamURLMarker) != nil
        }

        // Older builds persisted stream URLs (which carry Xtream credentials) in these blobs,
        // locally and in iCloud. Re-save without them and purge the synced copies.
        let purgedCloudKeys = CloudSyncService.shared.purgeLegacyStreamURLBlobs()
        if rewriteLocalBlobs {
            persistHistory()
            persistRecents()
        } else if purgedCloudKeys.contains(.watchHistory) {
            CloudSyncService.shared.save(history, for: .watchHistory)
        }

        // Favourite state changes in ChannelPreferencesStore must refresh views observing this store.
        preferencesObservation = channelPreferences.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        NotificationCenter.default.addObserver(
            forName: .bannertvCloudSyncDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.applyCloudStateIfNeeded() }
        }
    }

    // MARK: Favorites (forwarded to ChannelPreferencesStore)

    func isFavorite(_ channel: Channel) -> Bool {
        channelPreferences.isFavorite(channel.id)
    }

    func toggleFavorite(_ channel: Channel) {
        channelPreferences.toggleFavorite(channelID: channel.id)
    }

    /// IDs of every favourite channel, for filtering channel lists.
    var favoriteChannelIDs: Set<String> {
        Set(channelPreferences.favoriteChannelIDs)
    }

    // MARK: Continue watching

    /// Moves the channel to the front of the watch history.
    func recordWatch(_ channel: Channel) {
        history.removeAll { $0.id == channel.id }
        history.insert(WatchHistoryEntry(saved: SavedChannel(channel: channel), lastWatched: Date()), at: 0)
        if history.count > historyLimit {
            history.removeLast(history.count - historyLimit)
        }
        persistHistory()
    }

    func removeFromHistory(_ entry: WatchHistoryEntry) {
        history.removeAll { $0.id == entry.id }
        persistHistory()
    }

    func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    // MARK: Recents (dwell-confirmed)

    /// Records a channel as recently watched. Called after the dwell threshold has elapsed.
    func recordRecent(_ channel: Channel) {
        recents.removeAll { $0.id == channel.id }
        recents.insert(RecentEntry(channel: channel), at: 0)
        if recents.count > recentsLimit {
            recents.removeLast(recents.count - recentsLimit)
        }
        persistRecents()
    }

    // MARK: Persistence

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
        CloudSyncService.shared.save(history, for: .watchHistory)
    }

    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    private func applyCloudStateIfNeeded() {
        guard CloudSyncService.shared.isEnabled else { return }
        // A device still on an older build may re-upload a blob with stream URLs in it.
        let purgedCloudKeys = CloudSyncService.shared.purgeLegacyStreamURLBlobs()
        if purgedCloudKeys.contains(.watchHistory) {
            CloudSyncService.shared.save(history, for: .watchHistory)
            return
        }
        if let cloudHistory: [WatchHistoryEntry] = CloudSyncService.shared.load([WatchHistoryEntry].self, for: .watchHistory),
           cloudHistory != history {
            history = cloudHistory
            if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: historyKey)
            }
        }
    }
}
