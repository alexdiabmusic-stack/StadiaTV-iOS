import Foundation
import Testing
@testable import BannerTV

@Suite("Event category detection")
struct EventCategoryDetectorTests {

    private let playlistID = UUID()

    private func channel(name: String, categoryID: String, group: String) -> Channel {
        Channel(id: UUID().uuidString, name: name, streamURL: URL(string: "https://example.com/s.m3u8")!,
                logoURL: nil, group: group, playlistID: playlistID, playlistName: "Test",
                xtreamCategoryID: categoryID)
    }

    @Test("A category named after a league is an event category even with generic channel names")
    func keywordCategoryDetected() {
        let channels = [
            channel(name: "Channel 01", categoryID: "10", group: "US ❖ MLB"),
            channel(name: "Channel 02", categoryID: "10", group: "US ❖ MLB"),
        ]
        #expect(EventCategoryDetector.eventCategoryIDs(in: channels).contains("10"))
    }

    @Test("A category where 30%+ of names carry a fixture separator is an event category")
    func fixtureHeavyCategoryDetected() {
        let channels = [
            channel(name: "US ★ EVENT 01: Jets @ Bills 1:00 PM ET", categoryID: "20", group: "US ❖ EVENTS"),
            channel(name: "US ★ EVENT 02: ", categoryID: "20", group: "US ❖ EVENTS"),
            channel(name: "US ★ EVENT 03: ", categoryID: "20", group: "US ❖ EVENTS"),
        ]
        #expect(EventCategoryDetector.eventCategoryIDs(in: channels).contains("20"))
    }

    @Test("A category with no league keyword and no fixture-like names is not an event category")
    func plainCategoryNotDetected() {
        let channels = [
            channel(name: "CNN HD", categoryID: "30", group: "US ❖ NEWS"),
            channel(name: "Fox News HD", categoryID: "30", group: "US ❖ NEWS"),
        ]
        #expect(!EventCategoryDetector.eventCategoryIDs(in: channels).contains("30"))
    }

    @Test("Channels with no Xtream category id (M3U) are ignored")
    func m3uChannelsIgnored() {
        let channel = Channel(id: "1", name: "US ★ MLB HD", streamURL: URL(string: "https://example.com/s.m3u8")!,
                               logoURL: nil, group: "US ❖ MLB", playlistID: playlistID, playlistName: "Test")
        #expect(EventCategoryDetector.eventCategoryIDs(in: [channel]).isEmpty)
    }
}

/// Answers `player_api.php?...action=get_live_streams&category_id=` from an in-memory fixture,
/// so `EventChannelRefreshService` can be exercised with no network and no live account.
private final class EventChannelStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responsesByCategoryID: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/player_api.php"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
        let categoryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "category_id" }?.value
        let data = categoryID.flatMap { Self.responsesByCategoryID[$0] } ?? Data("[]".utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite("EventChannelRefreshService")
struct EventChannelRefreshServiceTests {

    @Test("A renamed event-slot stream is updated in place by stream id, and marked new")
    func renamedStreamIsAppliedInPlace() async throws {
        let playlistStore = PlaylistStore()
        let playlistID = UUID()
        try KeychainStore.saveXtreamCredentials(XtreamCredentials(username: "u", password: "p"), for: playlistID)
        defer { KeychainStore.deleteXtreamCredentials(for: playlistID) }

        let playlist = Playlist(id: playlistID, name: "Test", kind: .xtream, host: "http://benchmark.invalid", credentialID: playlistID)
        let staleChannel = Channel(
            id: "101", name: "US ★ MLB 01: ", streamURL: URL(string: "https://example.com/101.m3u8")!,
            logoURL: nil, group: "US ❖ MLB", playlistID: playlistID, playlistName: "Test",
            xtreamCategoryID: "10", xtreamStreamID: 101
        )
        playlistStore.updateChannels([staleChannel], for: playlistID)
        // `playlists` is populated by load(), which this test's fresh UserDefaults-backed store
        // won't have — append directly via the same seam EventChannelRefreshService reads.
        playlistStore.seedPlaylistsForTesting([playlist])

        EventChannelStubURLProtocol.responsesByCategoryID["10"] = Data("""
        [{"stream_id":101,"name":"US ★ MLB 01: PHILADELPHIA PHILLIES @ ATLANTA BRAVES 2:00 PM ET","category_id":"10"}]
        """.utf8)

        let service = EventChannelRefreshService()
        service.noteChannelsLoaded(playlistID: playlistID, channels: [staleChannel])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EventChannelStubURLProtocol.self]
        XtreamProviderAdapterTestHooks.session = URLSession(configuration: config)
        defer { XtreamProviderAdapterTestHooks.session = nil }

        let changed = await service.refreshIfDue(playlists: playlistStore)
        #expect(changed)
        let updated = playlistStore.channelsByPlaylist[playlistID]?.first
        #expect(updated?.name == "US ★ MLB 01: PHILADELPHIA PHILLIES @ ATLANTA BRAVES 2:00 PM ET")
        #expect(service.isNew(streamID: 101, name: "US ★ MLB 01: PHILADELPHIA PHILLIES @ ATLANTA BRAVES 2:00 PM ET"))
    }
}
