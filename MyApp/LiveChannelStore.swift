import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy text/blob data before bind returns,
// so the Swift string can be freed at any point after the bind call.
private typealias SQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
nonisolated private let kSQLiteTransient = unsafeBitCast(-1 as Int, to: SQLiteDestructor?.self)

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
        let url = caches.appendingPathComponent("BannerTV_Live.sqlite")
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
        try self.init(path: url.path)
    }

    /// `path` goes to SQLite as given, so `":memory:"` is a private in-memory database. It must not
    /// pass through a `URL`: `URL(fileURLWithPath: ":memory:")` resolves against the working
    /// directory, which made the old fallback open (or fail to create) a file with that name.
    private init(path: String) throws {
        guard sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw StoreError.openFailed
        }
        try Self.createSchema(on: db)
    }

    static func inMemory() throws -> LiveChannelStore {
        try LiveChannelStore(path: ":memory:")
    }

    private static func empty() -> LiveChannelStore {
        guard let store = try? LiveChannelStore.inMemory() else {
            fatalError("SQLite in-memory database unavailable — cannot create fallback store")
        }
        return store
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    /// Recorded in `PRAGMA user_version`. 0 = a database from before versioning.
    /// 1 = `live_channels.archive_enabled`, and the `(provider_id, sort_index)` index.
    nonisolated private static let schemaVersion: Int32 = 1

    /// Static so the synchronous initializer can run it before the actor is fully set up.
    nonisolated private static func createSchema(on db: OpaquePointer?) throws {
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
            archive_enabled  INTEGER NOT NULL DEFAULT 0,
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

        CREATE INDEX IF NOT EXISTS idx_ch_group
            ON live_channels(provider_id, group_title);
        CREATE INDEX IF NOT EXISTS idx_ch_tvg
            ON live_channels(tvg_id) WHERE tvg_id IS NOT NULL;
        """
        try exec(ddl, on: db)
        try migrate(on: db)
    }

    /// Brings a database created by an earlier version up to `schemaVersion`. The channel tables
    /// are only a cache of what the providers serve, but rewriting them in place keeps the
    /// lineup available offline on the first launch after an update.
    nonisolated private static func migrate(on db: OpaquePointer?) throws {
        guard scalar("PRAGMA user_version", on: db) < Int(schemaVersion) else { return }
        try exec("BEGIN IMMEDIATE TRANSACTION", on: db)
        do {
            // 1: a column instead of a text search through every channel's JSON.
            if !columns(of: "live_channels", on: db).contains("archive_enabled") {
                try exec("ALTER TABLE live_channels ADD COLUMN archive_enabled INTEGER NOT NULL DEFAULT 0", on: db)
                try exec(#"UPDATE live_channels SET archive_enabled = 1 WHERE streams_json LIKE '%"archiveEnabled":true%'"#, on: db)
            }
            // Reads order by sort_index within one provider; this also covers `provider_id` alone.
            try exec("CREATE INDEX IF NOT EXISTS idx_ch_provider_sort ON live_channels(provider_id, sort_index)", on: db)
            try exec("DROP INDEX IF EXISTS idx_ch_provider", on: db)
            try exec("PRAGMA user_version = \(schemaVersion)", on: db)
            try exec("COMMIT", on: db)
        } catch {
            try? exec("ROLLBACK", on: db)
            throw error
        }
    }

    nonisolated private static func scalar(_ sql: String, on db: OpaquePointer?) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    nonisolated private static func columns(of table: String, on db: OpaquePointer?) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW, let name = sqlite3_column_text(stmt, 1) {
            names.insert(String(cString: name))
        }
        return names
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

            // OR REPLACE so one repeated ID can't fail the whole transaction and leave the cache
            // stale; callers already give every channel a distinct ID (see `LiveChannelIDGenerator`).
            let insertSQL = """
            INSERT OR REPLACE INTO live_channels
                (id, provider_id, provider_kind, name, logo_url, group_title, tvg_id,
                 xtream_stream_id, xtream_cat_id, stream_url, streams_json, sort_index, archive_enabled)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                    sqlite3_bind_int(stmt, 13, ch.streams.contains { $0.archiveEnabled } ? 1 : 0)
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
                channels.append(liveChannel(from: stmt, providerID: providerID, decoder: decoder))
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

    /// When the provider's channels were last written, or nil if never refreshed.
    func lastRefreshed(for providerID: UUID) throws -> Date? {
        var date: Date?
        try withStatement("SELECT last_refreshed FROM live_providers WHERE id = ?") { stmt in
            bindText(stmt, 1, providerID.uuidString)
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 0))
            }
        }
        return date
    }

    func hasChannels(for providerID: UUID) throws -> Bool {
        try channelCount(for: providerID) > 0
    }

    /// Returns all channel IDs where any stream has archiveEnabled = true.
    func archiveEnabledChannelIDs() throws -> [String] {
        var ids: [String] = []
        try withStatement("SELECT id FROM live_channels WHERE archive_enabled = 1") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(columnText(stmt, 0))
            }
        }
        return ids
    }

    /// Returns a single channel by its stable ID, or nil if not found.
    func channel(id: String) throws -> LiveChannel? {
        let sql = """
        SELECT id, provider_kind, name, logo_url, group_title, tvg_id,
               xtream_stream_id, xtream_cat_id, streams_json, provider_id
          FROM live_channels WHERE id = ?
        """
        let decoder = JSONDecoder()
        var result: LiveChannel?
        try withStatement(sql) { stmt in
            bindText(stmt, 1, id)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let providerID = UUID(uuidString: columnText(stmt, 9)) ?? UUID()
                result = liveChannel(from: stmt, providerID: providerID, decoder: decoder)
            }
        }
        return result
    }

    /// Reads one row selected as `id, provider_kind, name, logo_url, group_title, tvg_id,
    /// xtream_stream_id, xtream_cat_id, streams_json`.
    private func liveChannel(from stmt: OpaquePointer?, providerID: UUID, decoder: JSONDecoder) -> LiveChannel {
        let streamsJSON = optionalText(stmt, 8) ?? "[]"
        return LiveChannel(
            id: columnText(stmt, 0),
            providerID: providerID,
            providerKind: LiveProviderKind(rawValue: columnText(stmt, 1)) ?? .m3u,
            name: columnText(stmt, 2),
            logoURL: optionalText(stmt, 3).flatMap(URL.init(string:)),
            groupTitle: optionalText(stmt, 4),
            streams: (try? decoder.decode([StreamDescriptor].self, from: Data(streamsJSON.utf8))) ?? [],
            tvgID: optionalText(stmt, 5),
            xtreamStreamID: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 6)) : nil,
            xtreamCategoryID: optionalText(stmt, 7)
        )
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
        try Self.exec(sql, on: db)
    }

    nonisolated private static func exec(_ sql: String, on db: OpaquePointer?) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw StoreError.execFailed(msg)
        }
    }

    // SQLITE_TRANSIENT copies the bytes before the call returns, so Swift's temporary C string
    // is enough; there's no need to allocate an NSString per value.
    private func bindText(_ stmt: OpaquePointer?, _ col: Int32, _ val: String) {
        sqlite3_bind_text(stmt, col, val, -1, kSQLiteTransient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ col: Int32, _ val: String?) {
        if let val {
            sqlite3_bind_text(stmt, col, val, -1, kSQLiteTransient)
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
