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
    @Published private(set) var channelsByPlaylist: [UUID: [Channel]] = [:] {
        didSet { rebuildChannelIndexes() }
    }
    /// All channels across every loaded playlist — the pool the matcher searches.
    /// Rebuilt once when `channelsByPlaylist` changes, never on read.
    @Published private(set) var allChannels: [Channel] = []
    /// `allChannels` keyed by channel ID.
    private(set) var channelsByID: [String: Channel] = [:]
    /// Bumped each time `allChannels` is rebuilt. Use this, not `allChannels.count`,
    /// as a `.task(id:)` / `onChange` key.
    @Published private(set) var channelsRevision = 0
    @Published private(set) var loadingPlaylistIDs: Set<UUID> = []
    @Published private(set) var defaultPlaylistID: UUID?
    @Published var lastError: String?

    /// Connection-limit status per Xtream playlist, refreshed alongside channel data.
    let xtreamAccountStatus = XtreamAccountStatusStore.shared

    /// Fetches Xtream EPG data for one provider channel — `fullSchedule: true` calls
    /// `get_simple_data_table` (a full multi-day schedule, ~0.5-1s per the provider docs,
    /// only worth it for a row actually scrolled into view); `false` calls
    /// `get_short_epg` (now/next only), reading `start_timestamp`/`stop_timestamp`
    /// directly rather than a formatted date string. Wired into `EPGRepository` once at
    /// app startup via `xtreamEPGFetcher` since that repository has no direct
    /// PlaylistStore reference.
    func fetchXtreamEPG(forProviderChannelId providerChannelId: String, fullSchedule: Bool) async -> [EPGProgramme] {
        guard let liveChannel = try? await LiveChannelStore.shared.channel(id: providerChannelId),
              let streamID = liveChannel.xtreamStreamID,
              let playlist = playlists.first(where: { $0.id == liveChannel.providerID }) else { return [] }
        let adapter = XtreamProviderAdapter(provider: LiveProvider(playlist: playlist))
        do {
            let listings = fullSchedule
                ? try await adapter.simpleDataTable(streamID: streamID)
                : try await adapter.shortEPG(streamID: streamID)
            let sourceId = "xtream-\(playlist.id.uuidString)"
            return listings.map { listing in
                EPGProgramme(
                    id: "xtream-\(streamID)-\(Int(listing.startTimestamp.timeIntervalSince1970))",
                    epgChannelId: "xtream:\(providerChannelId)",
                    canonicalChannelId: nil,
                    title: listing.title,
                    subtitle: nil,
                    description: listing.description,
                    categories: [],
                    start: listing.startTimestamp,
                    end: listing.stopTimestamp,
                    imageURL: nil,
                    season: nil,
                    episode: nil,
                    rating: nil,
                    sourceId: sourceId,
                    sourcePriority: 5,
                    endTimeIsInferred: false
                )
            }
        } catch {
            return []
        }
    }

    private let defaultsKey      = "bannertv.playlists.v1"
    private let defaultPlaylistKey = "bannertv.defaultplaylist.v1"

    private let repository = LiveChannelRepository()

    private var indexGeneration = 0
    private var cacheLoadTask: Task<Void, Never>?
    /// Above this, flattening and indexing runs off the main thread.
    private static let backgroundIndexThreshold = 5_000
    /// Playlists refreshed more recently than this aren't re-downloaded at launch.
    static let automaticRefreshInterval: TimeInterval = 12 * 60 * 60

    init() {
        load()
    }

    /// Patches channels in place for one playlist — used by `EventChannelRefreshService` to
    /// apply a renamed event-slot channel without re-downloading or re-matching the whole
    /// playlist. Bumps `channelsRevision` like any other channel-list change.
    func updateChannels(_ channels: [Channel], for playlistID: UUID) {
        channelsByPlaylist[playlistID] = channels
    }

    /// Rebuilds a playable channel from a saved snapshot (watch history, recents).
    ///
    /// The stream URL, headers and Xtream identifiers come from live provider data, never from
    /// the snapshot (see `SavedChannel`), so a changed host or password is picked up and no
    /// credentials are persisted with history. Display fields stay as the user last saw them.
    /// Returns nil until the channel's playlist has loaded, or when the provider no longer lists it.
    func channel(for saved: SavedChannel) -> Channel? {
        guard let indexed = channelsByID[saved.id] else { return nil }
        // The ID index keeps one channel per ID; prefer the saved playlist's own copy if another shadows it.
        let live = indexed.playlistID == saved.playlistID
            ? indexed
            : (channelsByPlaylist[saved.playlistID]?.first { $0.id == saved.id } ?? indexed)
        return Channel(
            id: live.id,
            name: saved.name,
            streamURL: live.streamURL,
            logoURL: saved.logoURLString.flatMap(URL.init(string:)) ?? live.logoURL,
            group: saved.group,
            playlistID: live.playlistID,
            playlistName: live.playlistName,
            tvgId: live.tvgId,
            httpHeaders: live.httpHeaders,
            xtreamCategoryID: live.xtreamCategoryID,
            xtreamStreamID: live.xtreamStreamID
        )
    }

    #if DEBUG
    /// Test-only: sets `playlists` directly, bypassing `load()`'s UserDefaults/Keychain
    /// round trip, so tests can exercise code that reads `playlists` without touching real
    /// persisted state.
    func seedPlaylistsForTesting(_ playlists: [Playlist]) {
        self.playlists = playlists
    }
    #endif

    // MARK: - Channel indexes

    private func rebuildChannelIndexes() {
        indexGeneration += 1
        let generation = indexGeneration
        let snapshot = channelsByPlaylist
        let total = snapshot.values.reduce(0) { $0 + $1.count }
        guard total > Self.backgroundIndexThreshold else {
            apply(Self.buildIndexes(snapshot))
            return
        }
        Task {
            let built = await Task.detached(priority: .userInitiated) { Self.buildIndexes(snapshot) }.value
            guard generation == self.indexGeneration else { return }
            self.apply(built)
        }
    }

    private func apply(_ built: (channels: [Channel], byID: [String: Channel])) {
        allChannels = built.channels
        channelsByID = built.byID
        channelsRevision &+= 1
    }

    nonisolated private static func buildIndexes(_ byPlaylist: [UUID: [Channel]]) -> (channels: [Channel], byID: [String: Channel]) {
        let channels = byPlaylist.values.flatMap { $0 }
        var byID: [String: Channel] = [:]
        byID.reserveCapacity(channels.count)
        for channel in channels where byID[channel.id] == nil {
            byID[channel.id] = channel
        }
        return (channels, byID)
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
        cacheLoadTask = Task { await loadCachedChannels() }
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

    /// Refreshes all playlists concurrently rather than serially.
    /// Each playlist's network request is independent, so there is no
    /// reason to wait for one before starting the next.
    /// - Parameter force: when false (launch), playlists with cached channels refreshed in the
    ///   last 12 hours are skipped. Pull-to-refresh and the playlist editor pass true.
    func refreshAll(force: Bool = false) async {
        // The TTL check needs to know which playlists already have cached channels.
        await cacheLoadTask?.value
        var due: [Playlist] = []
        for playlist in playlists {
            if !force, channelsByPlaylist[playlist.id]?.isEmpty == false,
               let last = await repository.lastRefreshed(for: playlist.id),
               Date().timeIntervalSince(last) < Self.automaticRefreshInterval {
                continue
            }
            due.append(playlist)
        }
        await withTaskGroup(of: Void.self) { group in
            for playlist in due {
                group.addTask { await self.refresh(playlist) }
            }
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

    /// Re-checks connection-limit status for every Xtream playlist without re-downloading
    /// channels — called when the app becomes active, since `active_cons` changes on the
    /// server's side independent of anything this app does. See MatchLinker/PROMPTS.md,
    /// Prompt 6 step 1.
    func refreshAccountStatus() async {
        await withTaskGroup(of: Void.self) { group in
            for playlist in playlists where playlist.kind == .xtream {
                group.addTask { await self.xtreamAccountStatus.refresh(for: playlist) }
            }
        }
    }

    // MARK: - Channel loading

    /// Fetches fresh channels from the provider via the appropriate adapter,
    /// persists them to the SQLite cache, and publishes the result.
    /// Existing cached channels remain visible while the refresh is in flight.
    func refresh(_ playlist: Playlist) async {
        guard !loadingPlaylistIDs.contains(playlist.id) else { return }
        loadingPlaylistIDs.insert(playlist.id)
        defer { loadingPlaylistIDs.remove(playlist.id) }
        // Read user_info/server_info alongside the channel refresh, not on every
        // multiscreen/recording attempt — a no-op for M3U playlists.
        Task { await xtreamAccountStatus.refresh(for: playlist) }
        do {
            let result = try await repository.refreshChannels(for: playlist)
            channelsByPlaylist[playlist.id] = result.channels

            if let parsedEPGURL = result.epgURL, playlist.epgURL != parsedEPGURL {
                var updated = playlist
                updated.epgURL = parsedEPGURL
                // Replace without triggering another refresh to avoid loop
                if let index = playlists.firstIndex(where: { $0.id == updated.id }) {
                    playlists[index] = updated.sanitizedForPersistence
                    persist()
                }
            }
        } catch {
            lastError = "\(playlist.name): \(error.localizedDescription)"
        }
    }
}
