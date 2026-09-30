import Foundation
import SQLite3

// SQLITE_TRANSIENT tells SQLite to copy text/blob data before bind returns,
// so the Swift string can be freed at any point after the bind call.
private typealias EPGSQLiteDestructor = @convention(c) (UnsafeMutableRawPointer?) -> Void
nonisolated private let kEPGSQLiteTransient = unsafeBitCast(-1 as Int, to: EPGSQLiteDestructor?.self)

/// SQLite-backed persistent store for parsed guide (EPGTV/XMLTV) programme data.
///
/// Indexed purely by **guide ID** (`EPGProgramme.epgChannelId` — the XMLTV/tvg-id the
/// provider's guide data itself uses). Guide-ID → canonical-channel translation is an
/// in-memory concern owned by `EPGRepository`/the match-linking engine, not this store —
/// that mapping changes independently of the underlying guide data and re-keying every
/// row on every re-match would be wasteful and a source of staleness bugs.
///
/// Replaces the old `programmeIndex.v2.json` full-dictionary-rewrite cache: writes are
/// scoped to one source at a time inside a transaction, and old rows are pruned on write
/// instead of trimmed only at load time, so the on-disk footprint stays bounded.
actor EPGProgrammeStore {

    private var db: OpaquePointer?

    // MARK: - Lifecycle

    static let shared: EPGProgrammeStore = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("BannerTV_EPG.sqlite")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try EPGProgrammeStore(url: url)
        } catch {
            return (try? EPGProgrammeStore.inMemory()) ?? EPGProgrammeStore.empty()
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
        try Self.createSchema(on: db)
    }

    static func inMemory() throws -> EPGProgrammeStore {
        try EPGProgrammeStore(url: URL(fileURLWithPath: ":memory:"))
    }

    private static func empty() -> EPGProgrammeStore {
        guard let store = try? EPGProgrammeStore.inMemory() else {
            fatalError("SQLite in-memory database unavailable — cannot create fallback store")
        }
        return store
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    /// Static so the synchronous initializer can run it before the actor is fully set up.
    nonisolated private static func createSchema(on db: OpaquePointer?) throws {
        let ddl = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;

        CREATE TABLE IF NOT EXISTS epg_programmes (
            id                 TEXT PRIMARY KEY,
            epg_channel_id     TEXT NOT NULL,
            title              TEXT NOT NULL,
            subtitle           TEXT,
            description        TEXT,
            categories_json    TEXT NOT NULL DEFAULT '[]',
            start_time         REAL NOT NULL,
            end_time           REAL NOT NULL,
            image_url          TEXT,
            season             INTEGER,
            episode            INTEGER,
            rating             TEXT,
            source_id          TEXT NOT NULL,
            source_priority    INTEGER NOT NULL DEFAULT 0,
            end_time_inferred  INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS idx_prog_guide_id
            ON epg_programmes(epg_channel_id);
        CREATE INDEX IF NOT EXISTS idx_prog_guide_time
            ON epg_programmes(epg_channel_id, start_time);
        CREATE INDEX IF NOT EXISTS idx_prog_source
            ON epg_programmes(source_id);
        """
        try exec(ddl, on: db)
    }

    // MARK: - Writes

    /// Atomically replaces all rows for one guide source, then prunes anything that
    /// ended more than `retentionDays` ago (across all sources).
    func replaceProgrammes(_ programmes: [EPGProgramme], sourceId: String, retentionDays: Int = 7) throws {
        try exec("BEGIN EXCLUSIVE TRANSACTION")
        do {
            try withStatement("DELETE FROM epg_programmes WHERE source_id = ?") { stmt in
                bindText(stmt, 1, sourceId)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.writeFailed }
            }

            let insertSQL = """
            INSERT INTO epg_programmes
                (id, epg_channel_id, title, subtitle, description, categories_json,
                 start_time, end_time, image_url, season, episode, rating,
                 source_id, source_priority, end_time_inferred)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            let encoder = JSONEncoder()
            try withStatement(insertSQL) { stmt in
                for prog in programmes {
                    let categoriesData = try? encoder.encode(prog.categories)
                    let categoriesJSON = categoriesData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, prog.id)
                    bindText(stmt, 2, prog.epgChannelId)
                    bindText(stmt, 3, prog.title)
                    bindOptionalText(stmt, 4, prog.subtitle)
                    bindOptionalText(stmt, 5, prog.description)
                    bindText(stmt, 6, categoriesJSON)
                    sqlite3_bind_double(stmt, 7, prog.start.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 8, prog.end.timeIntervalSince1970)
                    bindOptionalText(stmt, 9, prog.imageURL?.absoluteString)
                    if let season = prog.season {
                        sqlite3_bind_int64(stmt, 10, Int64(season))
                    } else {
                        sqlite3_bind_null(stmt, 10)
                    }
                    if let episode = prog.episode {
                        sqlite3_bind_int64(stmt, 11, Int64(episode))
                    } else {
                        sqlite3_bind_null(stmt, 11)
                    }
                    bindOptionalText(stmt, 12, prog.rating)
                    bindText(stmt, 13, prog.sourceId)
                    sqlite3_bind_int64(stmt, 14, Int64(prog.sourcePriority))
                    sqlite3_bind_int64(stmt, 15, prog.endTimeIsInferred ? 1 : 0)
                    guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.writeFailed }
                }
            }

            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970
            try withStatement("DELETE FROM epg_programmes WHERE end_time < ?") { stmt in
                sqlite3_bind_double(stmt, 1, cutoff)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.writeFailed }
            }

            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Reads

    /// Programmes for a single guide ID overlapping `[from, to]`, ordered by start time.
    /// Call from a background context; do not load on the main thread.
    func programmes(epgChannelId: String, from: Date, to: Date) throws -> [EPGProgramme] {
        let sql = """
        SELECT id, epg_channel_id, title, subtitle, description, categories_json,
               start_time, end_time, image_url, season, episode, rating,
               source_id, source_priority, end_time_inferred
          FROM epg_programmes
         WHERE epg_channel_id = ?
           AND end_time > ? AND start_time < ?
         ORDER BY start_time
        """
        var results: [EPGProgramme] = []
        try withStatement(sql) { stmt in
            bindText(stmt, 1, epgChannelId)
            sqlite3_bind_double(stmt, 2, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, to.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(programme(from: stmt))
            }
        }
        return results
    }

    /// Same as above but for a batch of guide IDs — used when resolving a canonical
    /// channel's programmes across every stream mapped to it.
    func programmes(epgChannelIds: Set<String>, from: Date, to: Date) throws -> [EPGProgramme] {
        guard !epgChannelIds.isEmpty else { return [] }
        let ids = Array(epgChannelIds)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT id, epg_channel_id, title, subtitle, description, categories_json,
               start_time, end_time, image_url, season, episode, rating,
               source_id, source_priority, end_time_inferred
          FROM epg_programmes
         WHERE epg_channel_id IN (\(placeholders))
           AND end_time > ? AND start_time < ?
         ORDER BY start_time
        """
        var results: [EPGProgramme] = []
        try withStatement(sql) { stmt in
            var col: Int32 = 1
            for id in ids {
                bindText(stmt, col, id)
                col += 1
            }
            sqlite3_bind_double(stmt, col, from.timeIntervalSince1970); col += 1
            sqlite3_bind_double(stmt, col, to.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(programme(from: stmt))
            }
        }
        return results
    }

    /// Every programme overlapping `[from, to]`, across every guide ID — the raw snapshot
    /// `MatchLinkService` indexes into a `StreamLinker`. Unlike `programmes(epgChannelId:from:to:)`,
    /// this is not scoped to a single channel: the linker maps guide IDs to playlist streams itself.
    func snapshot(from: Date, to: Date) throws -> [EPGProgramme] {
        let sql = """
        SELECT id, epg_channel_id, title, subtitle, description, categories_json,
               start_time, end_time, image_url, season, episode, rating,
               source_id, source_priority, end_time_inferred
          FROM epg_programmes
         WHERE end_time > ? AND start_time < ?
         ORDER BY epg_channel_id, start_time
        """
        var results: [EPGProgramme] = []
        try withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(programme(from: stmt))
            }
        }
        return results
    }

    /// Every distinct guide ID currently stored — used to build the guide-ID index
    /// the match-linking engine maps streams against.
    func allEpgChannelIds() throws -> Set<String> {
        var ids: Set<String> = []
        try withStatement("SELECT DISTINCT epg_channel_id FROM epg_programmes") { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.insert(columnText(stmt, 0))
            }
        }
        return ids
    }

    private func programme(from stmt: OpaquePointer?) -> EPGProgramme {
        let id = columnText(stmt, 0)
        let epgChannelId = columnText(stmt, 1)
        let title = columnText(stmt, 2)
        let subtitle = optionalText(stmt, 3)
        let description = optionalText(stmt, 4)
        let categoriesJSON = optionalText(stmt, 5) ?? "[]"
        let categories = (try? JSONDecoder().decode([String].self, from: Data(categoriesJSON.utf8))) ?? []
        let start = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let end = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let imageURL = optionalText(stmt, 8).flatMap(URL.init(string:))
        let season = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 9)) : nil
        let episode = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 10)) : nil
        let rating = optionalText(stmt, 11)
        let sourceId = columnText(stmt, 12)
        let sourcePriority = Int(sqlite3_column_int64(stmt, 13))
        let endTimeInferred = sqlite3_column_int64(stmt, 14) != 0

        return EPGProgramme(
            id: id,
            epgChannelId: epgChannelId,
            canonicalChannelId: nil,
            title: title,
            subtitle: subtitle,
            description: description,
            categories: categories,
            start: start,
            end: end,
            imageURL: imageURL,
            season: season,
            episode: episode,
            rating: rating,
            sourceId: sourceId,
            sourcePriority: sourcePriority,
            endTimeIsInferred: endTimeInferred
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

    private func bindText(_ stmt: OpaquePointer?, _ col: Int32, _ val: String) {
        sqlite3_bind_text(stmt, col, (val as NSString).utf8String, -1, kEPGSQLiteTransient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ col: Int32, _ val: String?) {
        if let val {
            sqlite3_bind_text(stmt, col, (val as NSString).utf8String, -1, kEPGSQLiteTransient)
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
            case .openFailed:           return "Could not open the EPG database."
            case .prepareFailed(let s): return "SQL prepare failed: \(s)"
            case .execFailed(let msg):  return "SQL exec failed: \(msg)"
            case .writeFailed:          return "EPG database write failed."
            }
        }
    }
}
