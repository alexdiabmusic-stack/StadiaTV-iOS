import Foundation
import Testing
@testable import BannerTV

@Suite("Playlist channel order")
struct PlaylistChannelOrderTests {

    private func channel(_ id: String, in playlist: UUID) -> Channel {
        Channel(
            id: id, name: id, streamURL: URL(string: "http://example.com/\(id).m3u8")!, logoURL: nil, group: nil,
            playlistID: playlist, playlistName: "P"
        )
    }

    private let a = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "CCCCCCCC-0000-0000-0000-00000000000C")!

    @Test("Playlists are flattened in the order given, not in dictionary order")
    func flattensInGivenOrder() {
        let byPlaylist = [a: [channel("a1", in: a), channel("a2", in: a)], b: [channel("b1", in: b)], c: [channel("c1", in: c)]]
        for order in [[a, b, c], [c, b, a], [b, a, c]] {
            let built = PlaylistStore.buildIndexes(byPlaylist, order: order)
            #expect(built.channels.map(\.id) == order.flatMap { byPlaylist[$0]!.map(\.id) })
        }
    }

    @Test("A playlist missing from the order follows the listed ones, by id")
    func unlistedFollow() {
        let byPlaylist = [a: [channel("a1", in: a)], b: [channel("b1", in: b)], c: [channel("c1", in: c)]]
        let built = PlaylistStore.buildIndexes(byPlaylist, order: [c])
        #expect(built.channels.map(\.id) == ["c1", "a1", "b1"])
    }

    @Test("When two playlists carry an ID, the earlier playlist's channel is the one indexed")
    func earlierPlaylistWinsAnID() {
        let byPlaylist = [a: [channel("shared", in: a)], b: [channel("shared", in: b)]]
        #expect(PlaylistStore.buildIndexes(byPlaylist, order: [a, b]).byID["shared"]?.playlistID == a)
        #expect(PlaylistStore.buildIndexes(byPlaylist, order: [b, a]).byID["shared"]?.playlistID == b)
    }
}

@Suite("Network policy")
struct NetworkPolicyTests {

    @Test("Only an automatic refresh with a cached copy to fall back on defers in Low Data Mode")
    func deferral() {
        #expect(NetworkPolicy.defersInLowDataMode(.automatic, hasCachedCopy: true))
        #expect(!NetworkPolicy.defersInLowDataMode(.automatic, hasCachedCopy: false), "a first download isn't optional")
        #expect(!NetworkPolicy.defersInLowDataMode(.userInitiated, hasCachedCopy: true), "the user asked")
        #expect(!NetworkPolicy.defersInLowDataMode(.userInitiated, hasCachedCopy: false))
    }

    @Test("Large downloads get a generous resource timeout")
    func bulkTimeouts() {
        let configuration = NetworkPolicy.bulkConfiguration(allowsConstrainedAccess: true)
        #expect(configuration.timeoutIntervalForResource >= 600)
        #expect(configuration.timeoutIntervalForRequest <= 120)
    }
}
