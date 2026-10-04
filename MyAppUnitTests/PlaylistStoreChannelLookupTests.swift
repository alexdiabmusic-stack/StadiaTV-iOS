import Foundation
import Testing
@testable import BannerTV

/// Watch history and recents keep display fields only (see `SavedChannel`); `PlaylistStore.channel(for:)` rebuilds
/// the playable channel from the provider's live lineup.
@MainActor
@Suite("Rebuilding a saved channel")
struct PlaylistStoreChannelLookupTests {

    private func channel(
        _ id: String, name: String = "ESPN", url: String, playlist: UUID, playlistName: String = "Home",
        headers: [String: String]? = nil
    ) -> Channel {
        Channel(
            id: id, name: name, streamURL: URL(string: url)!, logoURL: nil, group: "Sports", playlistID: playlist,
            playlistName: playlistName, httpHeaders: headers
        )
    }

    private func playlist(_ id: UUID, _ name: String) -> Playlist {
        Playlist(id: id, name: name, kind: .xtream, host: "http://\(name.lowercased()).invalid", credentialID: id)
    }

    @Test("The stream URL and headers come from the live lineup, so a changed host or password is picked up")
    func liveURL() throws {
        let store = PlaylistStore()
        let playlistID = UUID()
        store.updateChannels(
            [channel("c1", url: "http://new.example/live/alice/newpass/1.m3u8", playlist: playlistID, headers: ["User-Agent": "Player/2"])],
            for: playlistID
        )
        let remembered = channel("c1", name: "ESPN (as last seen)", url: "http://old.example/live/alice/oldpass/1.m3u8", playlist: playlistID)

        let rebuilt = try #require(store.channel(for: SavedChannel(channel: remembered)))
        #expect(rebuilt.streamURL.absoluteString == "http://new.example/live/alice/newpass/1.m3u8")
        #expect(rebuilt.httpHeaders == ["User-Agent": "Player/2"])
        #expect(rebuilt.name == "ESPN (as last seen)", "display fields stay as the person last saw them")
    }

    @Test("A channel the provider no longer lists, or one whose playlist hasn't loaded, comes back nil")
    func missing() {
        let store = PlaylistStore()
        let playlistID = UUID()
        let remembered = SavedChannel(channel: channel("c9", url: "http://old.example/live/a/b/9.m3u8", playlist: playlistID))
        #expect(store.channel(for: remembered) == nil, "nothing loaded yet")
        store.updateChannels([channel("c1", url: "http://new.example/live/a/b/1.m3u8", playlist: playlistID)], for: playlistID)
        #expect(store.channel(for: remembered) == nil, "the provider dropped it")
    }

    @Test("When two playlists use the same channel id, the saved playlist's own copy is the one played")
    func shadowedID() throws {
        let store = PlaylistStore()
        let first = UUID(), second = UUID()
        store.seedPlaylistsForTesting([playlist(first, "First"), playlist(second, "Second")])
        store.updateChannels([channel("dup", url: "http://first.invalid/live/u/p/1.m3u8", playlist: first, playlistName: "First")], for: first)
        store.updateChannels([channel("dup", url: "http://second.invalid/live/u/p/1.m3u8", playlist: second, playlistName: "Second")], for: second)

        let savedFromSecond = SavedChannel(channel: channel("dup", url: "http://gone.invalid/x", playlist: second, playlistName: "Second"))
        let rebuilt = try #require(store.channel(for: savedFromSecond))
        #expect(rebuilt.playlistID == second)
        #expect(rebuilt.streamURL.host == "second.invalid")
    }
}
