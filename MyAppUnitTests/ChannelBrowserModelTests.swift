import Foundation
import Testing
@testable import BannerTV

/// How the channel browser orders and searches a playlist (`ChannelBrowserModel.compute`).
@Suite("Channel browser")
struct ChannelBrowserModelTests {

    private let playlistID = UUID()

    private func channel(_ id: String, _ name: String, group: String? = nil) -> Channel {
        Channel(id: id, name: name, streamURL: URL(string: "https://example.test/\(id).m3u8")!, logoURL: nil,
                group: group, playlistID: playlistID, playlistName: "Test")
    }

    /// Channel ids in the order the browser would show them.
    private func ids(
        _ channels: [Channel], order: ChannelSortOrder = .providerOrder, query: String = "",
        source: ChannelBrowserModel.Input.Source = .all, hidden: Set<String> = [],
        favourites: [String] = [], customNames: [String: String] = [:]
    ) -> [String] {
        ChannelBrowserModel.compute(.init(
            source: source, channels: channels, byPlaylist: channels,
            channelsByID: Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            hiddenIDs: hidden, favoriteIDs: favourites, customNames: customNames, query: query, sortOrder: order
        )).map(\.id)
    }

    private var lineup: [Channel] {
        [channel("a", "ESPN"), channel("b", "Équipe 21"), channel("c", "dazn 1"), channel("d", "Fox Sports")]
    }

    // MARK: Ordering

    @Test("Provider order is kept, and hidden channels are left out")
    func providerOrder() {
        #expect(ids(lineup) == ["a", "b", "c", "d"])
        #expect(ids(lineup, hidden: ["b"]) == ["a", "c", "d"])
    }

    @Test("A to Z ignores case and accents, and Z to A reverses it")
    func nameOrder() {
        #expect(ids(lineup, order: .nameAZ) == ["c", "b", "a", "d"])
        #expect(ids(lineup, order: .nameZA) == ["d", "a", "b", "c"])
    }

    @Test("Custom names, not provider names, decide the order")
    func customNamesSort() {
        #expect(ids(lineup, order: .nameAZ, customNames: ["d": "Aardvark TV"]) == ["d", "c", "b", "a"])
    }

    @Test("Favourites come first, each group in name order")
    func favouritesFirst() {
        #expect(ids(lineup, order: .favoritesFirst, favourites: ["d", "a"]) == ["a", "d", "c", "b"])
    }

    @Test("Channel number order puts numbered channels first, lowest number first, and the rest last")
    func channelNumberOrder() {
        let numbered = [channel("a", "ESPN"), channel("b", "12. Sky"), channel("c", "7 - BBC"), channel("d", "103| TNT")]
        #expect(ids(numbered, order: .channelNumber) == ["c", "b", "d", "a"])
    }

    @Test("Favourites and ids sources show only those channels, in the order given")
    func sources() {
        #expect(ids(lineup, source: .favorites, favourites: ["d", "b"]) == ["d", "b"])
        #expect(ids(lineup, source: .ids(["c", "a", "missing"])) == ["c", "a"])
    }

    // MARK: Search

    @Test("Search ignores case and accents, and looks at custom names")
    func search() {
        #expect(ids(lineup, query: "equipe") == ["b"])
        #expect(ids(lineup, query: "  ESPN ") == ["a"])
        #expect(ids(lineup, query: "sports") == ["d"])
        #expect(ids(lineup, query: "zzz").isEmpty)
        #expect(ids(lineup, query: "news", customNames: ["c": "Sky News"]) == ["c"])
    }

    // MARK: Channel numbers

    @Test("A number is the digits before a dot, dash, bar or bracket")
    func channelNumbers() {
        #expect(ChannelBrowserModel.channelNumber("12. ESPN") == 12)
        #expect(ChannelBrowserModel.channelNumber("7 - BBC") == 7)
        #expect(ChannelBrowserModel.channelNumber("103| TNT") == 103)
        #expect(ChannelBrowserModel.channelNumber("5) Sky") == 5)
        #expect(ChannelBrowserModel.channelNumber("  44 . Fox") == 44)
        #expect(ChannelBrowserModel.channelNumber("\u{00A0}9.X") == 9)
        #expect(ChannelBrowserModel.channelNumber("007. Bond") == 7)
    }

    @Test("Names without a leading number, or with an unusable one, have none")
    func notNumbers() {
        #expect(ChannelBrowserModel.channelNumber("ESPN") == nil)
        #expect(ChannelBrowserModel.channelNumber("") == nil)
        #expect(ChannelBrowserModel.channelNumber("12 ESPN") == nil, "needs a separator")
        #expect(ChannelBrowserModel.channelNumber("x9. Y") == nil, "must start the name")
        #expect(ChannelBrowserModel.channelNumber("٣. Arabic") == nil, "only ASCII digits make a number")
        #expect(ChannelBrowserModel.channelNumber("99999999999999999999. Too big") == nil)
    }
}
