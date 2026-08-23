import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy text/blob data before bind returns,
// so the Swift string can be freed at any point after the bind call.
private typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
private let kSQLiteTransient = unsafeBitCast(-1 as Int, to: SQLiteDestructor?.self)

/// SQLite-backed persistent store for live TV channels.
///
/// All mutations run within the actor, so SQLite access is single-threaded.
/// Large playlists (10 000+ channels) are written in a single WAL transaction
/// and can be paginated on read without loading the full table into memory.
actor LiveChannelStore {

    private var db: OpaquePointer?

    // MARK: - Lifecycle

    static let shared: LiveChannelStore = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("StadiaTV_Live.sqlite")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let store = try LiveChannelStore(url: url)
            return store
        } catch {
            return (try? LiveChannelStore.inMemory()) ?? LiveChannelStore.empty()
        }
    }()

    init(url: URL) throws {
        guard sqlite3_open_v2(
            url.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw StoreError.openFailed
        }
        try createSchema()
    }

    static func inMemory() throws -> LiveChannelStore {
        try LiveChannelStore(url: URL(fileURLWithPath: ":memory:"))
    }

    private static func empty() -> LiveChannelStore {
        // Fallback that accepts all writes silently but never reads.
        try! LiveChannelStore.inMemory()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    private func createSchema() throws {
        let ddl = """
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        PRAGMA synchronous = NORMAL;

        CREATE TABLE IF NOT EXISTS live_providers (
            id               TEXT PRIMARY KEY,
            name             TEXT NOT NULL,
            kind             TEXT NOT NULL,
            added_at         REAL NOT NULL DEFAULT 0,
            last_refreshed   REAL,
            channel_count    INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS live_channels (
            id               TEXT PRIMARY KEY,
            provider_id      TEXT NOT NULL,
            provider_kind    TEXT NOT NULL,
            name             TEXT NOT NULL,
            logo_url         TEXT,
            group_title      TEXT,
            tvg_id           TEXT,
            xtream_stream_id INTEGER,
            xtream_cat_id    TEXT,
            stream_url       TEXT NOT NULL,
            streams_json     TEXT NOT NULL DEFAULT '[]',
            sort_index       INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(provider_id) REFERENCES live_providers(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS channel_preferences (
            channel_id              TEXT PRIMARY KEY,
            custom_name             TEXT,
            is_hidden               INTEGER NOT NULL DEFAULT 0,
            sort_order              INTEGER,
            manual_epg_channel_id   TEXT,
            epg_offset              INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS idx_ch_provider
            ON live_channels(provider_id);
        CREATE INDEX IF NOT EXISTS idx_ch_group
            ON live_channels(provider_id, group_title);
        CREATE INDEX IF NOT EXISTS idx_ch_tvg
            ON live_channels(tvg_id) WHERE tvg_id IS NOT NULL;
        """
        try exec(ddl)
    }

    // MARK: - Provider operations

    func upsertProvider(_ provider: LiveProvider) throws {
        let sql = """
        INSERT OR REPLACE INTO live_providers
            (id, name, kind, added_at, last_refreshed, channel_count)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        try withStatement(sql) { stmt in
            bindText(stmt, 1, provider.id.uuidString)
            bindText(stmt, 2, provider.name)
            bindText(stmt, 3, provider.kind.rawValue)
            sqlite3_bind_double(stmt, 4, provider.addedAt.timeIntervalSinceReferenceDate)
            if let r = provider.lastRefreshedAt {
                sqlite3_bind_double(stmt, 5, r.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_int64(stmt, 6, Int64(provider.channelCount))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.writeFailed }
        }
    }

    func deleteProvider(id: UUID) throws {
        try withStatement("DELETE FROM live_providers WHERE id = ?") { stmt in
            bindText(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.writeFailed }
        }
    }

    // MARK: - Channel operations

    /// Atomically replaces all channels for a provider inside a transaction.
    /// Existing user preferences are untouched.
    func replaceChannels(_ channels: [LiveChannel], for providerID: UUID) throws {
        try exec("BEGIN EXCLUSIVE TRANSACTION")
        do {
            let deleteSQL = "DELETE FROM live_channels WHERE provider_id = ?"
            try withStatement(deleteSQL) { stmt in
                bindText(stmt, 1, providerID.uuidString)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.writeFailed }
            }

            let insertSQL = """
            INSERT INTO live_channels
                (id, provider_id, provider_kind, name, logo_url, group_title, tvg_id,
                 xtream_stream_id, xtream_cat_id, stream_url, streams_json, sort_index)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let encoder = JSONEncoder()
            try withStatement(insertSQL) { stmt in
                for (index, ch) in channels.enumerated() {
                    let streamsData = try? encoder.encode(ch.streams)
                    let streamsJSON = streamsData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    let streamURL = ch.primaryStream?.streamURL.absoluteString ?? ""

                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, ch.id)
                    bindText(stmt, 2, providerID.uuidString)
                    bindText(stmt, 3, ch.providerKind.rawValue)
                    bindText(stmt, 4, ch.name)
                    bindOptionalText(stmt, 5, ch.logoURL?.absoluteString)
                    bindOptionalText(stmt, 6, ch.groupTitle)
                    bindOptionalText(stmt, 7, ch.tvgID)
                    if let xid = ch.xtreamStreamID {
                        sqlite3_bind_int64(stmt, 8, Int64(xid))
                    } else {
                        sqlite3_bind_null(stmt, 8)
                    }
                    bindOptionalText(stmt, 9, ch.xtreamCategoryID)
                    bindText(stmt, 10, streamURL)
                    bindText(stmt, 11, streamsJSON)
                    sqlite3_bind_int64(stmt, 12, Int64(index))
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.writeFailed }
                }
            }

            let updateSQL = """
            UPDATE live_providers
               SET channel_count = ?, last_refreshed = ?
             WHERE id = ?
            """
            try withStatement(updateSQL) { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(channels.count))
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSinceReferenceDate)
                bindText(stmt, 3, providerID.uuidString)
                _ = sqlite3_step(stmt)
            }

            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Returns all channels for a provider in insertion order.
    /// Call from a background context; do not load on the main thread.
    func channels(for providerID: UUID) throws -> [LiveChannel] {
        let sql = """
        SELECT id, provider_kind, name, logo_url, group_title, tvg_id,
               xtream_stream_id, xtream_cat_id, streams_json
          FROM live_channels
         WHERE provider_id = ?
         ORDER BY sort_index
        """
        let decoder = JSONDecoder()
        var channels: [LiveChannel] = []
        try withStatement(sql) { stmt in
            bindText(stmt, 1, providerID.uuidString)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id          = columnText(stmt, 0)
                let kindRaw     = columnText(stmt, 1)
                let kind        = LiveProviderKind(rawValue: kindRaw) ?? .m3u
                let name        = columnText(stmt, 2)
                let logoURL     = optionalText(stmt, 3).flatMap(URL.init(string:))
                let groupTitle  = optionalText(stmt, 4)
                let tvgID       = optionalText(stmt, 5)
                let xStreamID   = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                                    ? Int(sqlite3_column_int64(stmt, 6)) : nil
                let xCatID      = optionalText(stmt, 7)
                let streamsJSON = optionalText(stmt, 8) ?? "[]"
                let streams     = (try? decoder.decode(
                                    [StreamDescriptor].self,
                                    from: Data(streamsJSON.utf8))) ?? []

                channels.append(LiveChannel(
                    id: id,
                    providerID: providerID,
                    providerKind: kind,
                    name: name,
                    logoURL: logoURL,
                    groupTitle: groupTitle,
                    streams: streams,
                    tvgID: tvgID,
                    xtreamStreamID: xStreamID,
                    xtreamCategoryID: xCatID
                ))
            }
        }
        return channels
    }

    /// Paginated channel read — useful for future UI virtualisation.
    func channels(for providerID: UUID, offset: Int, limit: Int) throws -> [LiveChannel] {
        let sql = """
        SELECT id, provider_kind, name, logo_url, group_title, tvg_id,
               xtream_stream_id, xtream_cat_id, streams_json
          FROM live_channels
         WHERE provider_id = ?
         ORDER BY sort_index
         LIMIT ? OFFSET ?
        """
        let decoder = JSONDecoder()
        var channels: [LiveChannel] = []
        try withStatement(sql) { stmt in
            bindText(stmt, 1, providerID.uuidString)
            sqlite3_bind_int64(stmt, 2, Int64(limit))
            sqlite3_bind_int64(stmt, 3, Int64(offset))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id         = columnText(stmt, 0)
                let kindRaw    = columnText(stmt, 1)
                let kind       = LiveProviderKind(rawValue: kindRaw) ?? .m3u
                let name       = columnText(stmt, 2)
                let logoURL    = optionalText(stmt, 3).flatMap(URL.init(string:))
                let groupTitle = optionalText(stmt, 4)
                let tvgID      = optionalText(stmt, 5)
                let xStreamID  = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                                   ? Int(sqlite3_column_int64(stmt, 6)) : nil
                let xCatID     = optionalText(stmt, 7)
                let json       = optionalText(stmt, 8) ?? "[]"
                let streams    = (try? decoder.decode(
                                   [StreamDescriptor].self,
                                   from: Data(json.utf8))) ?? []

                channels.append(LiveChannel(
                    id: id,
                    providerID: providerID,
                    providerKind: kind,
                    name: name,
                    logoURL: logoURL,
                    groupTitle: groupTitle,
                    streams: streams,
                    tvgID: tvgID,
                    xtreamStreamID: xStreamID,
                    xtreamCategoryID: xCatID
                ))
            }
        }
        return channels
    }

    func channelCount(for providerID: UUID) throws -> Int {
        var count = 0
        try withStatement("SELECT COUNT(*) FROM live_channels WHERE provider_id = ?") { stmt in
            bindText(stmt, 1, providerID.uuidString)
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return count
    }

    func hasChannels(for providerID: UUID) throws -> Bool {
        try channelCount(for: providerID) > 0
    }

    /// Returns all channel IDs where any stream has archiveEnabled = true.
    /// Uses a JSON text search — fast enough for one-shot enrichment on channel load.
    func archiveEnabledChannelIDs() throws -> [String] {
        var ids: [String] = []
        try withStatement(
            #"SELECT id FROM live_channels WHERE streams_json LIKE '%"archiveEnabled":true%'"#
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(columnText(stmt, 0))
            }
        }
        return ids
    }

    /// Returns a single channel by its stable ID, or nil if not found.
    func channel(id: String) throws -> LiveChannel? {
        let sql = """
        SELECT provider_id, provider_kind, name, logo_url, group_title, tvg_id,
               xtream_stream_id, xtream_cat_id, streams_json
          FROM live_channels WHERE id = ?
        """
        let decoder = JSONDecoder()
        var result: LiveChannel?
        try withStatement(sql) { stmt in
            bindText(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let providerID  = UUID(uuidString: columnText(stmt, 0)) ?? UUID()
                let kind        = LiveProviderKind(rawValue: columnText(stmt, 1)) ?? .m3u
                let name        = columnText(stmt, 2)
                let logoURL     = optionalText(stmt, 3).flatMap(URL.init(string:))
                let groupTitle  = optionalText(stmt, 4)
                let tvgID       = optionalText(stmt, 5)
                let xStreamID   = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                                    ? Int(sqlite3_column_int64(stmt, 6)) : nil
                let xCatID      = optionalText(stmt, 7)
                let json        = optionalText(stmt, 8) ?? "[]"
                let streams     = (try? decoder.decode([StreamDescriptor].self,
                                                       from: Data(json.utf8))) ?? []
                result = LiveChannel(
                    id: id,
                    providerID: providerID,
                    providerKind: kind,
                    name: name,
                    logoURL: logoURL,
                    groupTitle: groupTitle,
                    streams: streams,
                    tvgID: tvgID,
                    xtreamStreamID: xStreamID,
                    xtreamCategoryID: xCatID
                )
            }
        }
        return result
    }

    // MARK: - SQLite helpers

    private func withStatement(_ sql: String, body: (OpaquePointer?) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(sql)
        }
        defer { sqlite3_finalize(stmt) }
        try body(stmt)
    }

    private func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw StoreError.execFailed(msg)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ col: Int32, _ val: String) {
        sqlite3_bind_text(stmt, col, (val as NSString).utf8String, -1, kSQLiteTransient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ col: Int32, _ val: String?) {
        if let val {
            sqlite3_bind_text(stmt, col, (val as NSString).utf8String, -1, kSQLiteTransient)
        } else {
            sqlite3_bind_null(stmt, col)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }

    private func optionalText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }

    // MARK: - Errors

    enum StoreError: Error, LocalizedError {
        case openFailed
        case prepareFailed(String)
        case execFailed(String)
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .openFailed:          return "Could not open the channel database."
            case .prepareFailed(let s): return "SQL prepare failed: \(s)"
            case .execFailed(let msg): return "SQL exec failed: \(msg)"
            case .writeFailed:         return "Channel database write failed."
            }
        }
    }
}
