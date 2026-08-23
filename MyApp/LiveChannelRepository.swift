import Foundation

/// Coordinates provider adapters, the channel database, and user preferences
/// to produce the `[Channel]` arrays consumed by existing UI code.
///
/// Design contract:
/// - Cache-first: returns stored channels immediately, then refreshes in background.
/// - Preference isolation: user overlays live in `ChannelPreferencesStore`,
///   never in the provider data path.
/// - Thread safety: `LiveChannelStore` is an actor so all DB operations run on
///   its isolated executor, not the main thread.
@MainActor
final class LiveChannelRepository {

    private let store = LiveChannelStore.shared
    private var refreshingProviders = Set<UUID>()

    // MARK: - Cache read

    /// Returns channels from the local SQLite cache for a playlist, or nil if no cache exists.
    /// Called on startup so the UI shows channels before the network is hit.
    func cachedChannels(for playlist: Playlist) async -> [Channel]? {
        do {
            guard try await store.hasChannels(for: playlist.id) else { return nil }
            // store.channels() runs on the LiveChannelStore actor (off-main thread).
            let liveChannels = try await store.channels(for: playlist.id)
            return liveChannels.map { $0.asChannel(playlistName: playlist.name) }
        } catch {
            return nil
        }
    }

    // MARK: - Network refresh

    /// Fetches fresh channels from the provider via the appropriate adapter,
    /// persists them to the SQLite cache, and returns `[Channel]`.
    /// Concurrent calls for the same provider are coalesced — the second caller
    /// receives the cached value while the first is in flight.
    func refreshChannels(for playlist: Playlist) async throws -> [Channel] {
        if refreshingProviders.contains(playlist.id) {
            return (await cachedChannels(for: playlist)) ?? []
        }
        refreshingProviders.insert(playlist.id)
        defer { refreshingProviders.remove(playlist.id) }

        var provider = LiveProvider(playlist: playlist)
        let adapter  = makeAdapter(for: provider)

        // Network + parsing happens inside the adapter (off-main via async/await or Task.detached).
        let adapterChannels = try await adapter.loadChannels()

        // ID assignment and model construction — background-threaded.
        let liveChannels: [LiveChannel] = await Task.detached(priority: .userInitiated) {
            adapterChannels.map { ac in
                LiveChannel.make(from: ac, providerID: provider.id, kind: provider.kind)
            }
        }.value

        provider.channelCount    = liveChannels.count
        provider.lastRefreshedAt = Date()

        // Persist asynchronously — the UI receives its channels immediately.
        let capturedProvider = provider
        let capturedChannels = liveChannels
        let capturedStore    = store
        Task.detached(priority: .utility) {
            do {
                try await capturedStore.upsertProvider(capturedProvider)
                try await capturedStore.replaceChannels(capturedChannels, for: capturedProvider.id)
            } catch {
                #if DEBUG
                print("LiveChannelRepository: DB write failed for \(capturedProvider.name): \(error)")
                #endif
            }
        }

        return liveChannels.map { $0.asChannel(playlistName: playlist.name) }
    }

    // MARK: - Single channel lookup

    /// Returns the cached LiveChannel for a given stable channel ID, or nil.
    func liveChannel(for id: String) async -> LiveChannel? {
        try? await store.channel(id: id)
    }

    // MARK: - Cleanup

    func removeChannels(for playlistID: UUID) {
        let capturedStore = store
        Task.detached(priority: .utility) {
            try? await capturedStore.deleteProvider(id: playlistID)
        }
    }

    // MARK: - Adapter factory

    private func makeAdapter(for provider: LiveProvider) -> any LiveProviderAdapter {
        switch provider.kind {
        case .m3u:    return M3UProviderAdapter(provider: provider)
        case .xtream: return XtreamProviderAdapter(provider: provider)
        }
    }
}
