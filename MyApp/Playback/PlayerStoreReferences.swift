import SwiftUI

/// Stores the player reads from without observing them.
///
/// `@EnvironmentObject` re-renders the whole player on every publish (EPG import progress,
/// playlist loading flags) while the video is starting. The player only needs point-in-time
/// lookups from these stores, so they're passed as plain references instead.
struct PlayerStoreReferences: Equatable {
    let playlistStore: PlaylistStore
    let epgRepository: EPGRepository
    let streamStore: StreamAvailabilityStore

    static func == (lhs: PlayerStoreReferences, rhs: PlayerStoreReferences) -> Bool {
        lhs.playlistStore === rhs.playlistStore && lhs.epgRepository === rhs.epgRepository
            && lhs.streamStore === rhs.streamStore
    }
}

extension EnvironmentValues {
    @Entry var playerStores: PlayerStoreReferences? = nil
}
