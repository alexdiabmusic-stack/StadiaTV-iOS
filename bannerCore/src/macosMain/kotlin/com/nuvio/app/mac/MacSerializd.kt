package com.nuvio.app.mac

import com.nuvio.app.features.addons.httpGetText
import com.nuvio.app.features.serializd.KtorSerializdTransport
import com.nuvio.app.features.serializd.SerializdBackfillEpisode
import com.nuvio.app.features.serializd.SerializdClock
import com.nuvio.app.features.serializd.SerializdConnectResult
import com.nuvio.app.features.serializd.SerializdConnectionState
import com.nuvio.app.features.serializd.SerializdImportSink
import com.nuvio.app.features.serializd.SerializdImportedEpisode
import com.nuvio.app.features.serializd.SerializdKeyValue
import com.nuvio.app.features.serializd.SerializdLabels
import com.nuvio.app.features.serializd.SerializdManager
import com.nuvio.app.features.serializd.SerializdOperationStatus
import com.nuvio.app.features.serializd.SerializdScreenState
import com.nuvio.app.features.serializd.SerializdSecretStore
import com.nuvio.app.features.serializd.SerializdSyncEngine
import com.nuvio.app.features.tmdb.CoreKeyValue
import com.nuvio.app.features.tmdb.TmdbRuntime
import com.nuvio.app.features.tmdb.TmdbService
import com.nuvio.app.features.tmdb.buildTmdbUrl
import com.nuvio.app.features.watchlist.WatchLaterPlanner
import com.nuvio.app.features.watchlist.WatchlistApplyResult
import com.nuvio.app.features.watchlist.WatchlistSink
import com.nuvio.app.features.watchlist.WatchlistTitle
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.alloc
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.refTo
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.value
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import platform.CoreFoundation.*
import platform.Foundation.NSCalendar
import platform.Foundation.NSDate
import platform.Foundation.NSUserDefaults
import platform.Foundation.dateWithTimeIntervalSince1970
import platform.Security.*
import kotlin.random.Random

/** One line of the "Sync activity" view, already in words. */
class MacSerializdEvent(val id: String, val atMs: Long, val title: String, val kind: String, val status: String, val note: String?, val issue: Boolean)

class MacSerializdWatchlistShow(val tmdbId: Int, val name: String, val poster: String?, val watchedEpisodes: Int)

class MacSerializdWatchlist(val shows: List<MacSerializdWatchlistShow>, val readAtMs: Long)

/**
 * Serializd on the Mac: the same shared manager the phone apps run, with the Mac's own protected storage (Keychain), network
 * (URLSession), watched list and My List underneath. The SwiftUI screens only draw [SerializdScreenState] and call these functions.
 * Observations arrive on the main thread; one-shot calls report back on it too.
 */
object MacSerializd {
    private val ui = macScope()
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Default + macExceptionHandler)
    private val json = Json { ignoreUnknownKeys = true }
    private val clock = SerializdClock { at -> NSCalendar.currentCalendar.timeZone.secondsFromGMTForDate(NSDate.dateWithTimeIntervalSince1970(at / 1_000.0)) * 1_000L }

    private val kv = object : SerializdKeyValue {
        override fun read(key: String): String? = NSUserDefaults.standardUserDefaults.stringForKey("serializd_$key")?.takeIf { it.isNotEmpty() }
        override fun write(key: String, value: String?) {
            if (value == null) NSUserDefaults.standardUserDefaults.removeObjectForKey("serializd_$key")
            else NSUserDefaults.standardUserDefaults.setObject(value, forKey = "serializd_$key")
        }
    }

    private val tmdbByMeta = HashMap<String, Int>()
    private val metaByTmdb = HashMap<Int, String>()

    val manager: SerializdManager by lazy {
        SerializdManager(
            kv = kv,
            secrets = MacSerializdSecrets,
            transport = KtorSerializdTransport(::macSerializdHttpClient),
            scope = work,
            newId = { "${kotlin.time.Clock.System.now().toEpochMilliseconds().toString(36)}-${Random.nextLong().toULong().toString(36)}" },
            isFavorite = { _, tmdb -> metaByTmdb[tmdb]?.let { MacAccountData.isInLibrary(it, "series") } == true },
            seasonLengthsOf = { tmdb -> runCatching { seasonCounts(tmdb) }.getOrDefault(emptyMap()) },
            importSink = MacWatchedSink,
            watchlistSink = MacWatchlistSink,
        )
    }

    fun profileId(): Int = MacAccountData.activeProfileIndex

    // ------------------------------------------------------------------ observing

    /** Follows the active profile's screen state; call again (and cancel the old watch) when the profile changes. */
    fun watchScreen(onChange: (SerializdScreenState) -> Unit): MacWatch {
        val profile = profileId()
        onChange(manager.screenNow(profile, clock))
        return MacWatch(ui.launch { manager.screenFlow(profile, clock).collect { onChange(it) } })
    }

    fun watchActivity(onChange: (List<MacSerializdEvent>) -> Unit): MacWatch {
        val profile = profileId()
        return MacWatch(ui.launch {
            manager.engine.events.collect { events ->
                onChange(events.filter { it.profileId == profile }.sortedByDescending { it.atMs }.take(80).map { e ->
                    MacSerializdEvent(
                        id = e.id, atMs = e.atMs,
                        title = e.title + (e.seasonNumber?.let { " · S$it" + (e.episodeNumber?.let { n -> "E$n" } ?: "") } ?: "") + if (e.rewatch) " · rewatch" else "",
                        kind = SerializdLabels.type(e.type), status = SerializdLabels.status(e.status),
                        note = listOfNotNull(e.note, SerializdLabels.error(e.error).takeIf { it.isNotEmpty() }).joinToString(" · ").takeIf { it.isNotEmpty() },
                        issue = SerializdLabels.needsAttention(e.status),
                    )
                })
            }
        })
    }

    fun watchlist(): MacSerializdWatchlist? {
        val profile = profileId()
        val snapshot = manager.watchlistFlow.value[profile] ?: return null
        val account = manager.accountOf(profile)
        return MacSerializdWatchlist(
            snapshot.entries.map { MacSerializdWatchlistShow(it.showTmdbId, it.name ?: "Show ${it.showTmdbId}", it.posterPath?.let { p -> "https://image.tmdb.org/t/p/w185$p" }, account?.let { a -> manager.engine.watchedEpisodeCount(a, it.showTmdbId) } ?: 0) },
            snapshot.completeAtMs,
        )
    }

    // ------------------------------------------------------------------ actions (each reports back on the main thread)

    fun connect(email: String, password: String, reconnect: Boolean, done: (String?) -> Unit) {
        val profile = profileId()
        ui.launch {
            val message = when (val r = manager.connect(profile, email, password, guidedSetup = !reconnect)) {
                is SerializdConnectResult.Connected -> null
                is SerializdConnectResult.Failed -> r.message
                is SerializdConnectResult.TooManyAttempts -> "Too many attempts. Try again in ${(r.waitMs / 1000).coerceAtLeast(1)} seconds."
            }
            done(message)
        }
    }

    fun syncNow(done: () -> Unit) { val p = profileId(); ui.launch { manager.syncNowAndWait(p); done() } }
    fun importNow(done: (String) -> Unit) { val p = profileId(); ui.launch { done(manager.importFromSerializd(p)) } }
    fun refreshWatchlist(done: (Boolean) -> Unit) { val p = profileId(); ui.launch { done(manager.refreshWatchlist(p) != null) } }
    fun completeSetup(recommended: Boolean, done: () -> Unit) { val p = profileId(); ui.launch { manager.completeSetup(p, recommended); done() } }
    fun retryFailed() = manager.retryAll(profileId())
    fun disconnect(deleteLocalHistory: Boolean, done: () -> Unit) { val p = profileId(); ui.launch { manager.disconnect(p, deleteLocalHistory); done() } }

    fun verifyConnection(done: (String) -> Unit) {
        val p = profileId()
        ui.launch {
            done(when (manager.checkConnection(p)) {
                SerializdConnectionState.Connected -> "Connected as ${manager.accountOf(p) ?: "your account"}."
                SerializdConnectionState.TemporarilyUnavailable -> "Serializd is unavailable right now. Try again later."
                SerializdConnectionState.Disconnected, SerializdConnectionState.Connecting -> "Not connected."
                else -> "Sign in again to keep syncing."
            })
        }
    }

    fun setSyncWatchlist(on: Boolean, done: (String?) -> Unit) { val p = profileId(); ui.launch { done(manager.setSyncWatchlist(p, on)) } }
    fun setTrackEpisodes(on: Boolean) = manager.updateSettings(profileId()) { it.copy(autoTrackEpisodes = on) }
    fun setSyncRatings(on: Boolean) = manager.updateSettings(profileId()) { it.copy(syncRatings = on) }
    fun setCreateDiaryEntries(on: Boolean) = manager.updateSettings(profileId()) { it.copy(createDiaryEntries = on) }
    fun setLogRewatches(on: Boolean) = manager.updateSettings(profileId()) { it.copy(logRewatches = on) }
    fun setSyncFavorites(on: Boolean) = manager.updateSettings(profileId()) { it.copy(syncFavorites = on) }
    fun setImportWatchedHistory(on: Boolean) = manager.updateSettings(profileId()) { it.copy(importWatchedHistory = on) }
    fun setCompletionPercent(percent: Int) = manager.updateSettings(profileId()) { it.copy(completionThreshold = percent / 100.0) }

    /** The optional, explicit upload of this Mac's own watched episodes. [days] 0 means everything. Returns a sentence to show. */
    fun sendHistory(days: Int, withDiary: Boolean, done: (String) -> Unit) {
        val p = profileId()
        ui.launch {
            if (manager.accountOf(p) == null) { done("Nothing was queued."); return@launch }
            val since = if (days > 0) kotlin.time.Clock.System.now().toEpochMilliseconds() - days * 86_400_000L else null
            val items = MacAccountData.watched.value.filter { it.contentType == "series" && it.season != null && it.episode != null && (since == null || it.watchedAt >= since) }
            if (items.isEmpty()) { done("Nothing new to send: no episodes in that range."); return@launch }
            val ids = HashMap<String, Int?>()
            items.map { it.contentId }.distinct().chunked(8).forEach { chunk ->
                coroutineScope { chunk.map { id -> async { id to showTmdbId(id) } }.awaitAll() }.forEach { (id, tmdb) -> ids[id] = tmdb }
            }
            val episodes = items.mapNotNull { w ->
                val show = ids[w.contentId] ?: return@mapNotNull null
                SerializdBackfillEpisode(show, w.title, w.season!!, w.episode!!, w.watchedAt.takeIf { it >= SerializdSyncEngine.PLAUSIBLE_WATCH_DATE_MS })
            }
            val (marks, entries, skipped) = manager.backfill(p, episodes, withDiary)
            done(
                if (marks + entries == 0) "Nothing new to send: $skipped already on Serializd or nothing in that range."
                else "$marks watched requests and $entries diary entries are on their way; $skipped episodes were already on Serializd.",
            )
        }
    }

    /** The app came to the front: send what is waiting and read Serializd again when the last read is old. Never writes anything of its own. */
    fun onForeground() {
        val profile = profileId()
        if (manager.accountOf(profile) == null) return
        manager.syncNow()
        manager.refreshIfStale(profile)
    }

    // ------------------------------------------------------------------ the player

    /** The show's TMDB id for a BannerTV series id (an IMDb id), looked up once and remembered. Null for a show with none. */
    private suspend fun showTmdbId(metaId: String): Int? {
        tmdbByMeta[metaId]?.let { return it.takeIf { id -> id > 0 } }
        val id = runCatching { TmdbService.ensureTmdbId(metaId, "tv") }.getOrNull()?.toIntOrNull() ?: 0
        tmdbByMeta[metaId] = id
        if (id > 0) metaByTmdb[id] = metaId
        return id.takeIf { it > 0 }
    }

    private val resolving = HashSet<String>()

    /** Called about once a second while an episode plays. Cheap when no account is connected; nothing counts until the show's TMDB id is known. */
    fun onPlayback(
        metaId: String, season: Int, episode: Int, showName: String, episodeTitle: String?, poster: String?,
        positionSeconds: Double, durationSeconds: Double, isPlaying: Boolean, isEnded: Boolean,
    ) {
        val profile = profileId()
        if (metaId.isBlank() || manager.accountOf(profile) == null) return
        val tmdb = tmdbByMeta[metaId]
        if (tmdb == null) {
            if (resolving.add(metaId)) work.launch { showTmdbId(metaId); resolving.remove(metaId) }
            return
        }
        if (tmdb <= 0) return
        manager.playbackSample(profile, tmdb, season, episode, showName, episodeTitle, poster, (positionSeconds * 1000).toLong(), (durationSeconds * 1000).toLong(), isPlaying, isEnded)
    }

    fun onPlaybackStopped(metaId: String, season: Int, episode: Int) {
        val tmdb = tmdbByMeta[metaId] ?: return
        if (tmdb > 0) manager.playbackStopped(profileId(), tmdb, season, episode)
    }

    private suspend fun seasonCounts(showTmdbId: Int): Map<Int, Int> {
        val key = TmdbRuntime.apiKey().takeIf { it.isNotBlank() } ?: return emptyMap()
        val root = json.parseToJsonElement(httpGetText(buildTmdbUrl(endpoint = "tv/$showTmdbId", apiKey = key, query = mapOf("language" to "en-US")))) as? JsonObject ?: return emptyMap()
        val out = HashMap<Int, Int>()
        (root["seasons"] as? JsonArray).orEmpty().forEach { el ->
            val o = el as? JsonObject ?: return@forEach
            val n = o["season_number"]?.jsonPrimitive?.int ?: return@forEach
            val c = o["episode_count"]?.jsonPrimitive?.int ?: return@forEach
            if (n > 0 && c > 0) out[n] = c
        }
        return out
    }
}

// ---------------------------------------------------------------------------------------------- where imports land

private const val UNKNOWN_DATE_MS = 946_728_000_000L
private const val IMAGE_BASE = "https://image.tmdb.org/t/p"

/** History read from Serializd becomes watched here, with the date Serializd gave or the "unknown" placeholder, never today's date. */
private object MacWatchedSink : SerializdImportSink {
    override suspend fun apply(profileId: Int, episodes: List<SerializdImportedEpisode>) {
        check(profileId == MacAccountData.activeProfileIndex) { "Switch to this profile to add its Serializd history to the watched list" }
        val ids = HashMap<Int, String>()
        episodes.map { it.showTmdbId }.distinct().chunked(8).forEach { chunk ->
            coroutineScope { chunk.map { tmdb -> async { tmdb to (runCatching { TmdbService.tmdbToImdb(tmdb, "tv") }.getOrNull() ?: "tmdb:$tmdb") } }.awaitAll() }.forEach { (t, id) -> ids[t] = id }
        }
        val items = episodes.mapNotNull { e ->
            val id = ids[e.showTmdbId] ?: return@mapNotNull null
            if (MacAccountData.isWatched(id, e.seasonNumber, e.episodeNumber)) null
            else MacWatched(id, "series", e.showName.orEmpty(), e.seasonNumber, e.episodeNumber, e.watchedAtMs ?: UNKNOWN_DATE_MS)
        }
        items.chunked(100).forEach { MacAccountData.setWatched(it, true, keepDates = true) }
    }
}

/** The watchlist goes to My List by the shared planner's rules: only additions, nothing duplicated, no watched films, nothing the member removed. */
internal object MacWatchlistSink : WatchlistSink {
    private const val STORE = "watchlist_import"
    private val json = Json { ignoreUnknownKeys = true }

    override suspend fun apply(profileId: Int, source: String, titles: List<WatchlistTitle>): WatchlistApplyResult {
        check(profileId == MacAccountData.activeProfileIndex) { "Switch to this profile to add its watchlist to My List" }
        val distinct = titles.distinctBy { it.key }
        val ids = HashMap<String, String>()
        distinct.chunked(8).forEach { chunk ->
            coroutineScope {
                chunk.map { t -> async { t.key to (runCatching { TmdbService.tmdbToImdb(t.tmdbId, if (t.isSeries) "tv" else "movie") }.getOrNull() ?: "tmdb:${t.tmdbId}") } }.awaitAll()
            }.forEach { (k, v) -> ids[k] = v }
        }
        val typeOf = { t: WatchlistTitle -> if (t.isSeries) "series" else "movie" }
        val plan = WatchLaterPlanner.plan(
            titles = distinct, handledBefore = readHandled(source, profileId),
            isInMyList = { t -> MacAccountData.isInLibrary(ids.getValue(t.key), typeOf(t)) },
            isWatched = { t -> MacAccountData.isWatched(ids.getValue(t.key), null, null) },
        )
        if (plan.add.isNotEmpty()) {
            MacAccountData.saveAll(plan.add.map { t ->
                MacLibraryItem(contentId = ids.getValue(t.key), contentType = typeOf(t), name = t.name, poster = t.posterPath?.let { "$IMAGE_BASE/w500$it" }, releaseInfo = t.year)
            })
        }
        // Remembered only once the save went through, so a failure is tried again next time.
        writeHandled(source, profileId, plan.handled)
        return WatchlistApplyResult(plan.add.size, plan.alreadyThere, plan.removedByMember, plan.alreadyWatched, 0)
    }

    private fun readHandled(source: String, profileId: Int): Set<String> =
        CoreKeyValue.getString(STORE, "$source.$profileId")?.let { runCatching { json.decodeFromString(ListSerializer(String.serializer()), it) }.getOrNull() }.orEmpty().toSet()

    private fun writeHandled(source: String, profileId: Int, handled: Set<String>) =
        CoreKeyValue.putString(STORE, "$source.$profileId", json.encodeToString(ListSerializer(String.serializer()), handled.toList()))
}

// ---------------------------------------------------------------------------------------------- platform: Keychain and network

internal fun macSerializdHttpClient(): HttpClient = HttpClient(Darwin) {
    followRedirects = false
    expectSuccess = false
    install(HttpTimeout) {
        // Longer than the transport's own 60 s, so the transport's decision (a lost reply to a write is "may have landed") is the one that applies.
        requestTimeoutMillis = 75_000
        connectTimeoutMillis = 20_000
        socketTimeoutMillis = 75_000
    }
    engine {
        configureSession {
            HTTPShouldSetCookies = false
            HTTPCookieStorage = null
        }
    }
}

/**
 * One service's secrets (a profile's sign-in or session), in the Keychain: never preferences, never backed up, never shared between
 * profiles. [service] names the Keychain entry (`com.nuvio.media.serializd`, `com.nuvio.media.letterboxd`); [noun] is for error text only.
 */
@OptIn(ExperimentalForeignApi::class)
internal class MacKeychain(private val service: String, private val noun: String) {
    fun read(profileId: Int): String? = query(profileId) { query ->
        CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue)
        CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne)
        memScoped {
            val result = alloc<CFTypeRefVar>()
            val status = SecItemCopyMatching(query, result.ptr)
            if (status == errSecItemNotFound) return@memScoped null
            check(status == errSecSuccess) { "Unable to read the $noun (OSStatus $status)" }
            val data: CFDataRef = result.value?.reinterpret() ?: return@memScoped null
            try {
                val bytes = CFDataGetBytePtr(data) ?: return@memScoped null
                ByteArray(CFDataGetLength(data).toInt()) { bytes[it].toByte() }.decodeToString()
            } finally {
                CFRelease(data)
            }
        }
    }

    fun write(profileId: Int, value: String?) = query(profileId) { query ->
        if (value == null) {
            val status = SecItemDelete(query)
            check(status == errSecSuccess || status == errSecItemNotFound) { "Unable to remove the $noun (OSStatus $status)" }
        } else {
            val bytes = value.encodeToByteArray().toUByteArray()
            require(bytes.isNotEmpty())
            val data = CFDataCreate(null, bytes.refTo(0), bytes.size.toLong()) ?: error("Unable to encode the $noun")
            val attributes = dictionary()
            try {
                CFDictionarySetValue(attributes, kSecValueData, data)
                val update = SecItemUpdate(query, attributes)
                if (update == errSecItemNotFound) {
                    CFDictionarySetValue(query, kSecValueData, data)
                    CFDictionarySetValue(query, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
                    val added = SecItemAdd(query, null)
                    check(added == errSecSuccess) { "Unable to save the $noun (OSStatus $added)" }
                } else {
                    check(update == errSecSuccess) { "Unable to update the $noun (OSStatus $update)" }
                }
            } finally {
                CFRelease(attributes)
                CFRelease(data)
            }
        }
    }

    private fun dictionary(): CFMutableDictionaryRef =
        CFDictionaryCreateMutable(null, 0L, kCFTypeDictionaryKeyCallBacks.ptr, kCFTypeDictionaryValueCallBacks.ptr) ?: error("Unable to create the Keychain query")

    private inline fun <T> query(profileId: Int, block: (CFMutableDictionaryRef) -> T): T {
        val serviceName = CFStringCreateWithCString(null, service, kCFStringEncodingUTF8) ?: error("Unable to encode the Keychain service")
        val account = CFStringCreateWithCString(null, "profile.$profileId", kCFStringEncodingUTF8) ?: error("Unable to encode the Keychain account")
        val query = dictionary()
        try {
            CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword)
            CFDictionarySetValue(query, kSecAttrService, serviceName)
            CFDictionarySetValue(query, kSecAttrAccount, account)
            return block(query)
        } finally {
            CFRelease(query); CFRelease(account); CFRelease(serviceName)
        }
    }
}

/** Each profile's Serializd email, password and token. */
internal object MacSerializdSecrets : SerializdSecretStore {
    private val keychain = MacKeychain("com.nuvio.media.serializd", "Serializd sign-in")
    override fun read(profileId: Int): String? = keychain.read(profileId)
    override fun write(profileId: Int, value: String?) = keychain.write(profileId, value)
}
