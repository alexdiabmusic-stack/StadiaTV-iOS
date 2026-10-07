import Foundation
import Combine

/// Caches each Xtream playlist's connection-limit status, refreshed alongside the
/// playlist's own channel refresh (see `PlaylistStore.refresh(_:)`) rather than probed
/// fresh on every multiscreen attempt.
@MainActor
final class XtreamAccountStatusStore: ObservableObject {
    /// Singleton so code with no direct PlaylistStore reference (stream selection, the
    /// player) can read connection-limit status without extra wiring.
    static let shared = XtreamAccountStatusStore()

    @Published private(set) var statusByPlaylistID: [UUID: XtreamAccountStatus] = [:]

    func refresh(for playlist: Playlist) async {
        guard playlist.kind == .xtream else { return }
        let provider = LiveProvider(playlist: playlist)
        let adapter = XtreamProviderAdapter(provider: provider)
        let status = await adapter.accountStatus()
        statusByPlaylistID[playlist.id] = status
    }

    /// True if starting one more connection (multiscreen) risks disrupting an existing
    /// one for this playlist's account. Defaults to `false` (don't block) until a status
    /// has actually been fetched — the player's reactive 403/429 handling remains the
    /// safety net until then.
    func blocksAdditionalConnection(forPlaylistID id: UUID) -> Bool {
        statusByPlaylistID[id]?.blocksAdditionalConnection ?? false
    }
}
