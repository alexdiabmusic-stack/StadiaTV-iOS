import Foundation
import SwiftUI
import Combine

/// Owns the user's playlist configurations, persists them, and coordinates channel loading
/// via the Live data layer (LiveChannelRepository → adapters → SQLite cache).
///
/// Public surface is unchanged: all callers still read from `channelsByPlaylist`
/// and `allChannels`; provider-specific logic lives in the adapters.
@MainActor
final class PlaylistStore: ObservableObject {

    @Published private(set) var playlists: [Playlist] = []
    /// Channels loaded per playlist, keyed by playlist id.
    @Published private(set) var channelsByPlaylist: [UUID: [Channel]] = [:]
    @Published private(set) var loadingPlaylistIDs: Set<UUID> = []
    @Published private(set) var defaultPlaylistID: UUID?
    @Published var lastError: String?

    private let defaultsKey      = "stadiatv.playlists.v1"
    private let defaultPlaylistKey = "stadiatv.defaultplaylist.v1"

    private let repository = LiveChannelRepository()

    /// All channels across every loaded playlist — the pool the matcher searches.
    var allChannels: [Channel] {
        channelsByPlaylist.values.flatMap { $0 }
    }

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        defaultPlaylistID = UserDefaults.standard.string(forKey: defaultPlaylistKey)
            .flatMap(UUID.init(uuidString:))
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded.map { migrateCredentialsIfNeeded(for: $0) }
        if let defaultPlaylistID, !playlists.contains(where: { $0.id == defaultPlaylistID }) {
            self.defaultPlaylistID = nil
            UserDefaults.standard.removeObject(forKey: defaultPlaylistKey)
        }
        persist()
        // Populate the channel grid from the SQLite cache before any network calls.
        Task { await loadCachedChannels() }
    }

    /// Reads channels from the local SQLite cache for each known playlist.
    /// Runs without touching the network so the UI has data on cold start.
    private func loadCachedChannels() async {
        for playlist in playlists {
            guard channelsByPlaylist[playlist.id] == nil else { continue }
            if let cached = await repository.cachedChannels(for: playlist) {
                channelsByPlaylist[playlist.id] = cached
            }
        }
    }

    private func persist() {
        let sanitized = playlists.map(\.sanitizedForPersistence)
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    // MARK: - Credential migration

    private func migrateCredentialsIfNeeded(for playlist: Playlist) -> Playlist {
        guard playlist.kind == .xtream,
              let username = playlist.username, let password = playlist.password,
              !username.isEmpty, !password.isEmpty else {
            return playlist.sanitizedForPersistence
        }
        do {
            try KeychainStore.saveXtreamCredentials(
                XtreamCredentials(username: username, password: password),
                for: playlist.credentialID
            )
        } catch {
            lastError = "\(playlist.name): Couldn't secure saved credentials."
        }
        return playlist.sanitizedForPersistence
    }

    private func secureCredentialsIfNeeded(for playlist: Playlist) throws -> Playlist {
        guard playlist.kind == .xtream,
              let username = playlist.username, let password = playlist.password,
              !username.isEmpty, !password.isEmpty else {
            return playlist.sanitizedForPersistence
        }
        try KeychainStore.saveXtreamCredentials(
            XtreamCredentials(username: username, password: password),
            for: playlist.credentialID
        )
        return playlist.sanitizedForPersistence
    }

    // MARK: - Mutating

    func add(_ playlist: Playlist) {
        do {
            let secured = try secureCredentialsIfNeeded(for: playlist)
            playlists.append(secured)
            if defaultPlaylistID == nil { setDefault(secured) }
            persist()
            Task { await refresh(secured) }
        } catch {
            lastError = "\(playlist.name): Couldn't save credentials securely."
        }
    }

    func replace(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else {
            add(playlist)
            return
        }
        do {
            let secured = try secureCredentialsIfNeeded(for: playlist)
            playlists[index] = secured
            channelsByPlaylist[secured.id] = nil
            persist()
            Task { await refresh(secured) }
        } catch {
            lastError = "\(playlist.name): Couldn't save credentials securely."
        }
    }

    func setDefault(_ playlist: Playlist) {
        defaultPlaylistID = playlist.id
        UserDefaults.standard.set(playlist.id.uuidString, forKey: defaultPlaylistKey)
    }

    func isDefault(_ playlist: Playlist) -> Bool {
        defaultPlaylistID == playlist.id
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let playlist = playlists[index]
            channelsByPlaylist[playlist.id] = nil
            repository.removeChannels(for: playlist.id)
            if playlist.kind == .xtream {
                KeychainStore.deleteXtreamCredentials(for: playlist.credentialID)
            }
        }
        playlists.remove(atOffsets: offsets)
        if let defaultPlaylistID, !playlists.contains(where: { $0.id == defaultPlaylistID }) {
            self.defaultPlaylistID = playlists.first?.id
            if let fallbackID = self.defaultPlaylistID {
                UserDefaults.standard.set(fallbackID.uuidString, forKey: defaultPlaylistKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultPlaylistKey)
            }
        }
        persist()
    }

    func refreshAll() async {
        for playlist in playlists {
            await refresh(playlist)
        }
    }

    func channelCount(for playlist: Playlist) -> Int {
        channelsByPlaylist[playlist.id]?.count ?? 0
    }

    func isLoading(_ playlist: Playlist) -> Bool {
        loadingPlaylistIDs.contains(playlist.id)
    }

    /// Looks up a playlist by ID — used for provider credential resolution.
    func playlist(for id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    /// Returns the LiveChannel from the SQLite cache for a given stable channel ID.
    func liveChannel(for id: String) async -> LiveChannel? {
        await repository.liveChannel(for: id)
    }

    // MARK: - Channel loading

    /// Fetches fresh channels from the provider via the appropriate adapter,
    /// persists them to the SQLite cache, and publishes the result.
    /// Existing cached channels remain visible while the refresh is in flight.
    func refresh(_ playlist: Playlist) async {
        guard !loadingPlaylistIDs.contains(playlist.id) else { return }
        loadingPlaylistIDs.insert(playlist.id)
        defer { loadingPlaylistIDs.remove(playlist.id) }
        do {
            let channels = try await repository.refreshChannels(for: playlist)
            channelsByPlaylist[playlist.id] = channels
        } catch {
            lastError = "\(playlist.name): \(error.localizedDescription)"
        }
    }
}
