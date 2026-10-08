import Foundation
import OSLog

/// Coordinates provider adapters, the channel database, and user preferences
/// to produce the `[Channel]` arrays consumed by existing UI code.
///
/// Design contract:
/// - Cache-first: returns stored channels immediately, then refreshes in background.
/// - Preference isolation: user overlays live in `ChannelPreferencesStore`,
///   never in the provider data path.
/// - Thread safety: `LiveChannelStore` is an actor so all DB operations run on
///   its isolated executor, not the main thread. Building the `[Channel]` models,
///   tens of thousands for a big playlist, is done off the main actor too.
@MainActor
final class LiveChannelRepository {

    private let store = LiveChannelStore.shared
    private var refreshingProviders = Set<UUID>()
    private let logger = Logger(subsystem: "BannerTV", category: "LiveChannels")

    // MARK: - Cache read

    /// Returns channels from the local SQLite cache for a playlist, or nil if no cache exists.
    /// Called on startup so the UI shows channels before the network is hit.
    func cachedChannels(for playlist: Playlist) async -> [Channel]? {
        // store.channels() runs on the LiveChannelStore actor (off-main thread).
        guard let liveChannels = try? await store.channels(for: playlist.id), !liveChannels.isEmpty else { return nil }
        let playlistName = playlist.name
        let userAgent = playlist.userAgent
        return await Task.detached(priority: .userInitiated) {
            liveChannels.map { $0.asChannel(playlistName: playlistName, defaultUserAgent: userAgent) }
        }.value
    }

    // MARK: - Network refresh

    /// Fetches fresh channels from the provider via the appropriate adapter,
    /// persists them to the SQLite cache, and returns `[Channel]`.
    /// Concurrent calls for the same provider are coalesced — the second caller
    /// receives the cached value while the first is in flight.
    ///
    /// An automatic refresh of a playlist that already has a cached lineup throws the system's
    /// Low Data Mode refusal (see `NetworkPolicy.isLowDataModeRefusal`) instead of downloading.
    func refreshChannels(
        for playlist: Playlist, origin: RefreshOrigin = .userInitiated, hasCachedCopy: Bool = false
    ) async throws -> (channels: [Channel], epgURL: String?) {
        if refreshingProviders.contains(playlist.id) {
            return ((await cachedChannels(for: playlist)) ?? [], nil)
        }
        refreshingProviders.insert(playlist.id)
        defer { refreshingProviders.remove(playlist.id) }

        var provider = LiveProvider(playlist: playlist)
        let session = NetworkPolicy.bulkSession(deferrable: NetworkPolicy.defersInLowDataMode(origin, hasCachedCopy: hasCachedCopy))
        let adapter = makeAdapter(for: provider, session: session)

        // Network + parsing happens inside the adapter (off-main via async/await or Task.detached).
        let (epgURL, adapterChannels) = try await adapter.loadChannels()

        // ID assignment and model construction — background-threaded.
        let providerID = provider.id
        let kind = provider.kind
        let playlistName = playlist.name
        let userAgent = playlist.userAgent
        let (liveChannels, channels) = await Task.detached(priority: .userInitiated) { () -> ([LiveChannel], [Channel]) in
            let live = LiveChannel.makeAll(from: adapterChannels, providerID: providerID, kind: kind)
            return (live, live.map { $0.asChannel(playlistName: playlistName, defaultUserAgent: userAgent) })
        }.value

        provider.channelCount    = liveChannels.count
        provider.lastRefreshedAt = Date()

        // Persist asynchronously — the UI receives its channels immediately.
        let capturedProvider = provider
        let capturedStore    = store
        let logger           = logger
        Task.detached(priority: .utility) {
            do {
                try await capturedStore.upsertProvider(capturedProvider)
                try await capturedStore.replaceChannels(liveChannels, for: capturedProvider.id)
            } catch {
                // A failed write leaves the cache stale (and empty on a first launch), so it is
                // logged in every build, not just Debug.
                logger.error("Channel cache write failed for \(capturedProvider.name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }

        return (channels, epgURL)
    }

    /// When a playlist's channels were last fetched from the provider (nil if never).
    func lastRefreshed(for playlistID: UUID) async -> Date? {
        try? await store.lastRefreshed(for: playlistID)
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

    private func makeAdapter(for provider: LiveProvider, session: URLSession) -> any LiveProviderAdapter {
        switch provider.kind {
        case .m3u:    return M3UProviderAdapter(provider: provider, session: session)
        case .xtream: return XtreamProviderAdapter(provider: provider, session: session)
        }
    }
}
