import Foundation
import SQLite3
import Testing
@testable import BannerTV

/// The channel cache (`LiveChannelStore`) and the IDs that key it, against real SQLite.
@Suite("Live channel cache")
struct LiveChannelStoreTests {

    private let provider = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func channel(
        _ name: String, tvg: String? = nil, group: String? = "Sports", archive: Bool = false, xtream: Int? = nil, index: Int = 0
    ) -> AdapterChannel {
        AdapterChannel(
            name: name, streamURL: URL(string: "http://example.com/\(index).m3u8")!, groupTitle: group, tvgID: tvg,
            rawIndex: index, xtreamStreamID: xtream, archiveEnabled: archive, archiveDays: archive ? 3 : 0
        )
    }

    private func tail(_ id: String) -> String { String(id.dropFirst(provider.uuidString.count + 1)) }

    // MARK: IDs

    @Test("Channels sharing a tvg-id or a name each get their own ID; the first keeps the plain one")
    func uniqueIDs() {
        let adapterChannels = [
            channel("ESPN HD", tvg: "espn.us"), channel("ESPN SD", tvg: "espn.us"), channel("ESPN Backup", tvg: "espn.us"),
            channel("FS1", tvg: "fs1.us"), channel("No tvg"), channel("NO TVG"),
        ]
        let live = LiveChannel.makeAll(from: adapterChannels, providerID: provider, kind: .m3u)
        let ids = live.map(\.id)
        let plain = LiveChannelIDGenerator.m3uChannelID(providerID: provider, tvgID: "espn.us", name: "ESPN HD", group: "Sports")

        #expect(Set(ids).count == ids.count)
        #expect(ids[0] == plain, "the first holder keeps the ID favourites were already saved under")
        #expect(ids[1] == plain + "~2" && ids[2] == plain + "~3")
        #expect(ids[5] == ids[4] + "~2", "same name and group, no tvg-id")
        #expect(live[1].streams[0].id == ids[1] + "-s0", "stream IDs follow the channel's")
        #expect(LiveChannel.makeAll(from: adapterChannels, providerID: provider, kind: .m3u).map(\.id) == ids, "stable between refreshes")
    }

    @Test("Xtream IDs stay the provider's stream id, with a repeat disambiguated")
    func xtreamIDs() {
        let live = LiveChannel.makeAll(
            from: [channel("A", xtream: 10), channel("B", xtream: 11), channel("A again", xtream: 10)],
            providerID: provider, kind: .xtream
        )
        #expect(live.map { tail($0.id) } == ["10", "11", "10~2"])
    }

    // MARK: Store

    @Test("A playlist with repeated tvg-ids is cached in full, in order")
    func cachesRepeatedTvgIDs() async throws {
        let store = try LiveChannelStore.inMemory()
        let live = LiveChannel.makeAll(
            from: [channel("ESPN HD", tvg: "espn.us", index: 0), channel("ESPN SD", tvg: "espn.us", index: 1), channel("FS1", tvg: "fs1.us", index: 2)],
            providerID: provider, kind: .m3u
        )
        try await store.upsertProvider(LiveProvider(playlist: Playlist(id: provider, name: "Test", kind: .m3u, m3uURL: "http://x")))
        try await store.replaceChannels(live, for: provider)

        let stored = try await store.channels(for: provider)
        #expect(stored.map(\.id) == live.map(\.id))
        #expect(stored.map(\.name) == ["ESPN HD", "ESPN SD", "FS1"])
        #expect(try await store.channelCount(for: provider) == 3)
        #expect(try await store.channel(id: live[1].id)?.name == "ESPN SD")
        #expect(try await store.channel(id: "missing") == nil)
    }

    @Test("One repeated ID can't fail the whole write")
    func repeatedIDDoesNotFailTheTransaction() async throws {
        let store = try LiveChannelStore.inMemory()
        try await store.upsertProvider(LiveProvider(playlist: Playlist(id: provider, name: "Test", kind: .m3u, m3uURL: "http://x")))
        // Bypasses `makeAll`, so two rows really do share an ID.
        let clashing = [channel("One", tvg: "same", index: 0), channel("Two", tvg: "same", index: 1)]
            .map { LiveChannel.make(from: $0, providerID: provider, kind: .m3u) }
        #expect(clashing[0].id == clashing[1].id)
        try await store.replaceChannels(clashing, for: provider)
        #expect(try await store.channelCount(for: provider) == 1)
    }

    @Test("An in-memory store is private to itself and leaves no file behind")
    func inMemoryStoresArePrivate() async throws {
        let first = try LiveChannelStore.inMemory()
        let second = try LiveChannelStore.inMemory()
        try await first.upsertProvider(LiveProvider(playlist: Playlist(id: provider, name: "Test", kind: .m3u, m3uURL: "http://x")))
        try await first.replaceChannels(LiveChannel.makeAll(from: [channel("A", tvg: "a")], providerID: provider, kind: .m3u), for: provider)
        #expect(try await first.channelCount(for: provider) == 1)
        #expect(try await second.channelCount(for: provider) == 0)
        // It once went through a file URL, which put a database called ":memory:" in the working directory.
        #expect(!FileManager.default.fileExists(atPath: ":memory:"))
    }

    @Test("Strings come back exactly as stored")
    func stringsRoundTrip() async throws {
        let store = try LiveChannelStore.inMemory()
        try await store.upsertProvider(LiveProvider(playlist: Playlist(id: provider, name: "Test", kind: .m3u, m3uURL: "http://x")))
        let live = LiveChannel.makeAll(from: [
            channel("Quote \" 'single' \\ backslash", tvg: "q", group: "Ünïcödé ✓ 🏈", index: 0),
            channel("日本語 チャンネル", group: "", index: 1),
            channel(String(repeating: "x", count: 5000), tvg: "long", index: 2),
        ], providerID: provider, kind: .m3u)
        try await store.replaceChannels(live, for: provider)
        let stored = try await store.channels(for: provider)
        #expect(stored.map(\.name) == live.map(\.name))
        #expect(stored.map(\.groupTitle) == live.map(\.groupTitle))
    }

    @Test("Archive-enabled channels are found through a column, and follow each replace")
    func archiveIDs() async throws {
        let store = try LiveChannelStore.inMemory()
        try await store.upsertProvider(LiveProvider(playlist: Playlist(id: provider, name: "Test", kind: .m3u, m3uURL: "http://x")))
        let first = LiveChannel.makeAll(from: [channel("A", tvg: "a", archive: true, index: 0), channel("B", tvg: "b", index: 1)], providerID: provider, kind: .m3u)
        try await store.replaceChannels(first, for: provider)
        #expect(try await store.archiveEnabledChannelIDs() == [first[0].id])

        let second = LiveChannel.makeAll(from: [channel("A", tvg: "a", index: 0), channel("B", tvg: "b", archive: true, index: 1)], providerID: provider, kind: .m3u)
        try await store.replaceChannels(second, for: provider)
        #expect(try await store.archiveEnabledChannelIDs() == [second[1].id])
    }

    // MARK: Migration

    /// A database exactly as the version before schema versioning left it.
    private func writeLegacyDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw LiveChannelStore.StoreError.openFailed }
        defer { sqlite3_close(db) }
        let streams = { (archive: Bool) in
            #"[{"id":"x-s0","streamURL":"http://e.com/a.m3u8","providerID":"\#(provider.uuidString)","resolution":0,"archiveEnabled":\#(archive),"archiveDays":3}]"#
        }
        let sql = """
        CREATE TABLE live_providers (id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, added_at REAL NOT NULL DEFAULT 0, last_refreshed REAL, channel_count INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE live_channels (
            id TEXT PRIMARY KEY, provider_id TEXT NOT NULL, provider_kind TEXT NOT NULL, name TEXT NOT NULL, logo_url TEXT, group_title TEXT, tvg_id TEXT,
            xtream_stream_id INTEGER, xtream_cat_id TEXT, stream_url TEXT NOT NULL, streams_json TEXT NOT NULL DEFAULT '[]', sort_index INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(provider_id) REFERENCES live_providers(id) ON DELETE CASCADE);
        CREATE INDEX idx_ch_provider ON live_channels(provider_id);
        INSERT INTO live_providers (id, name, kind, last_refreshed) VALUES ('\(provider.uuidString)', 'Legacy', 'm3u', 1000);
        INSERT INTO live_channels (id, provider_id, provider_kind, name, stream_url, streams_json, sort_index) VALUES ('c1', '\(provider.uuidString)', 'm3u', 'A', 'http://e.com/a.m3u8', '\(streams(true))', 0);
        INSERT INTO live_channels (id, provider_id, provider_kind, name, stream_url, streams_json, sort_index) VALUES ('c2', '\(provider.uuidString)', 'm3u', 'B', 'http://e.com/b.m3u8', '\(streams(false))', 1);
        INSERT INTO live_channels (id, provider_id, provider_kind, name, stream_url, streams_json, sort_index) VALUES ('c3', '\(provider.uuidString)', 'm3u', 'C', 'http://e.com/c.m3u8', '\(streams(true))', 2);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LiveChannelStore.StoreError.writeFailed }
    }

    private func userVersion(of url: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }

    @Test("A database from before schema versioning keeps its channels and is upgraded in place")
    func migratesLegacyDatabase() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        try writeLegacyDatabase(at: url)
        #expect(userVersion(of: url) == 0)

        let store = try LiveChannelStore(url: url)
        #expect(Set(try await store.archiveEnabledChannelIDs()) == ["c1", "c3"], "the column is backfilled from the old JSON")
        #expect(try await store.channels(for: provider).map(\.name) == ["A", "B", "C"])
        #expect(userVersion(of: url) == 1)

        // Writing works afterwards, and opening it again changes nothing.
        let live = LiveChannel.makeAll(from: [channel("New", tvg: "n", archive: true)], providerID: provider, kind: .m3u)
        try await store.replaceChannels(live, for: provider)
        let reopened = try LiveChannelStore(url: url)
        #expect(try await reopened.archiveEnabledChannelIDs() == [live[0].id])
        #expect(userVersion(of: url) == 1)
    }
}
