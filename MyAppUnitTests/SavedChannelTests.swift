import Foundation
import Testing
@testable import BannerTV

/// Watch history and recents are written to UserDefaults (device backups) and iCloud key-value storage. Xtream stream
/// URLs carry the account's username and password in their path, so none of those snapshots may hold one.
@MainActor
@Suite("Saved channels")
struct SavedChannelTests {

    private let playlistID = UUID(uuidString: "6F1B2C3D-0000-4000-8000-000000000001")!

    private var xtreamChannel: Channel {
        Channel(
            id: "101", name: "ESPN HD", streamURL: URL(string: "http://host.example:8080/live/alice/s3cr3t/101.m3u8")!,
            logoURL: URL(string: "https://logo.example/espn.png"), group: "Sports", playlistID: playlistID, playlistName: "Home",
            xtreamCategoryID: "10", xtreamStreamID: 101
        )
    }

    @Test("A saved channel holds display fields only: no stream URL, so no username or password")
    func noStreamURL() throws {
        let data = try JSONEncoder().encode(SavedChannel(channel: xtreamChannel))
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["alice", "s3cr3t", "host.example", "m3u8", "8080"] {
            #expect(!text.contains(secret), "\(secret) must not be persisted")
        }
        let keys = Set(try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys)
        #expect(keys == ["id", "name", "logoURLString", "group", "playlistID", "playlistName"])
    }

    @Test("Recents and history entries nest only that snapshot")
    func entries() throws {
        let recent = try JSONEncoder().encode(RecentEntry(channel: xtreamChannel))
        let history = try JSONEncoder().encode(WatchHistoryEntry(saved: SavedChannel(channel: xtreamChannel), lastWatched: Date()))
        for data in [recent, history] {
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains("s3cr3t") && !text.contains("streamURL"))
        }
    }

    @Test("A history blob from an older build still loads, and saving it again drops the URL")
    func olderBlob() throws {
        let blob = """
        [{"saved":{"id":"101","name":"ESPN HD","streamURLString":"http://host.example:8080/live/alice/s3cr3t/101.m3u8",\
        "logoURLString":"https://logo.example/espn.png","group":"Sports","playlistID":"\(playlistID.uuidString)","playlistName":"Home"},\
        "lastWatched":770000000}]
        """
        let decoded = try JSONDecoder().decode([WatchHistoryEntry].self, from: Data(blob.utf8))
        #expect(decoded.count == 1)
        #expect(decoded.first?.saved.id == "101")
        #expect(decoded.first?.saved.name == "ESPN HD")
        #expect(decoded.first?.saved.playlistID == playlistID)

        let rewritten = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!rewritten.contains("s3cr3t") && !rewritten.contains("streamURLString"), "the secret goes with the next save")
    }
}
