import Foundation
import SwiftUI
import Combine

/// A persistable snapshot of a channel so favorites and watch history survive
/// app restarts and playlist refreshes.
struct SavedChannel: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let streamURLString: String
    let logoURLString: String?
    let group: String?
    let playlistID: UUID
    let playlistName: String

    init(channel: Channel) {
        self.id = channel.id
        self.name = channel.name
        self.streamURLString = channel.streamURL.absoluteString
        self.logoURLString = channel.logoURL?.absoluteString
        self.group = channel.group
        self.playlistID = channel.playlistID
        self.playlistName = channel.playlistName
    }

    /// Rebuilds a playable channel from the snapshot.
    var channel: Channel? {
        guard let url = URL(string: streamURLString) else { return nil }
        return Channel(
            id: id,
            name: name,
            streamURL: url,
            logoURL: logoURLString.flatMap(URL.init(string:)),
            group: group,
            playlistID: playlistID,
            playlistName: playlistName
        )
    }
}

/// One "continue watching" entry.
struct WatchHistoryEntry: Codable, Hashable, Identifiable {
    var saved: SavedChannel
    var lastWatched: Date

    var id: String { saved.id }
}

/// Owns favorite channels and recently watched channels, persisted to UserDefaults.
@MainActor
final class WatchStore: ObservableObject {
    @Published private(set) var favorites: [SavedChannel] = []
    @Published private(set) var history: [WatchHistoryEntry] = []

    private let favoritesKey = "stadiatv.favoritechannels.v1"
    private let historyKey = "stadiatv.watchhistory.v1"
    private let historyLimit = 20

    init() {
        CloudSyncService.shared.start()
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let decoded = try? JSONDecoder().decode([SavedChannel].self, from: data) {
            favorites = decoded
        } else if let cloud: [SavedChannel] = CloudSyncService.shared.load([SavedChannel].self, for: .favoriteChannels) {
            favorites = cloud
        }
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([WatchHistoryEntry].self, from: data) {
            history = decoded
        } else if let cloud: [WatchHistoryEntry] = CloudSyncService.shared.load([WatchHistoryEntry].self, for: .watchHistory) {
            history = cloud
        }
        NotificationCenter.default.addObserver(
            forName: .stadiatvCloudSyncDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyCloudStateIfNeeded() }
        }
    }

    // MARK: Favorites

    func isFavorite(_ channel: Channel) -> Bool {
        favorites.contains { $0.id == channel.id }
    }

    func toggleFavorite(_ channel: Channel) {
        if let index = favorites.firstIndex(where: { $0.id == channel.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(SavedChannel(channel: channel))
        }
        persistFavorites()
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

    // MARK: Persistence

    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
        CloudSyncService.shared.save(favorites, for: .favoriteChannels)
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
        CloudSyncService.shared.save(history, for: .watchHistory)
    }

    private func applyCloudStateIfNeeded() {
        guard CloudSyncService.shared.isEnabled else { return }
        if let cloudFavorites: [SavedChannel] = CloudSyncService.shared.load([SavedChannel].self, for: .favoriteChannels),
           cloudFavorites != favorites {
            favorites = cloudFavorites
            if let data = try? JSONEncoder().encode(favorites) {
                UserDefaults.standard.set(data, forKey: favoritesKey)
            }
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
