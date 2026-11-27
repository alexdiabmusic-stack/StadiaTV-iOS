package com.nuvio.app.mac

import com.nuvio.app.features.letterboxd.KtorLetterboxdTransport
import com.nuvio.app.features.letterboxd.LetterboxdConnectResult
import com.nuvio.app.features.letterboxd.LetterboxdConnectionState
import com.nuvio.app.features.letterboxd.LetterboxdKeyValue
import com.nuvio.app.features.letterboxd.LetterboxdLabels
import com.nuvio.app.features.letterboxd.LetterboxdManager
import com.nuvio.app.features.letterboxd.LetterboxdRating
import com.nuvio.app.features.letterboxd.LetterboxdScreenState
import com.nuvio.app.features.letterboxd.LetterboxdScreenText
import com.nuvio.app.features.letterboxd.LetterboxdSecretStore
import com.nuvio.app.features.letterboxd.LetterboxdSignInSupport
import com.nuvio.app.features.letterboxd.LetterboxdViewing
import com.nuvio.app.features.serializd.SerializdClock
import com.nuvio.app.features.tmdb.TmdbService
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import platform.Foundation.NSCalendar
import platform.Foundation.NSDate
import platform.Foundation.NSDateFormatter
import platform.Foundation.NSLocale
import platform.Foundation.NSUserDefaults
import platform.Foundation.dateWithTimeIntervalSince1970
import kotlin.random.Random

/** One line of the "Sync activity" view, already in words. */
class MacLetterboxdEvent(val id: String, val atMs: Long, val title: String, val kind: String, val status: String, val note: String?, val issue: Boolean)

/** One film in the Watch Journal, already in words. [tone] is "Good", "Warning", "Problem" or "Neutral". */
class MacLetterboxdViewing(val id: String, val title: String, val poster: String?, val detail: String, val status: String, val tone: String)

class MacLetterboxdWatchlistFilm(val tmdbId: Int, val title: String, val year: String?)

class MacLetterboxdWatchlist(val films: List<MacLetterboxdWatchlistFilm>, val readAtMs: Long)

/** The outcome of signing in. [status] is "connected", "needsUsername" or "failed" (then [message] says why). */
class MacLetterboxdConnect(val status: String, val message: String?)

/**
 * Letterboxd on the Mac: the same shared manager the phone apps run, with the Mac's own protected storage (Keychain), network
 * (URLSession), watched list and My List underneath. Letterboxd has no sign-in API, so the member signs in on Letterboxd's own page in
 * a web view (Swift) and hands the session here; this layer never sees a password. The SwiftUI screens only draw
 * [LetterboxdScreenState] and call these functions. Observations arrive on the main thread; one-shot calls report back on it too.
 */
object MacLetterboxd {
    private val ui = macScope()
    private val work = CoroutineScope(SupervisorJob() + Dispatchers.Default + macExceptionHandler)
    private val clock = SerializdClock { at -> NSCalendar.currentCalendar.timeZone.secondsFromGMTForDate(NSDate.dateWithTimeIntervalSince1970(at / 1_000.0)) * 1_000L }

    private val kv = object : LetterboxdKeyValue {
        override fun read(key: String): String? = NSUserDefaults.standardUserDefaults.stringForKey("letterboxd_$key")?.takeIf { it.isNotEmpty() }
        override fun write(key: String, value: String?) {
            if (value == null) NSUserDefaults.standardUserDefaults.removeObjectForKey("letterboxd_$key")
            else NSUserDefaults.standardUserDefaults.setObject(value, forKey = "letterboxd_$key")
        }
    }

    private val secrets = object : LetterboxdSecretStore {
        private val keychain = MacKeychain("com.nuvio.media.letterboxd", "Letterboxd session")
        override fun read(profileId: Int): String? = keychain.read(profileId)
        override fun write(profileId: Int, value: String?) = keychain.write(profileId, value)
    }

    private val tmdbByMeta = HashMap<String, Int>()
    private val metaByTmdb = HashMap<Int, String>()
    private val resolving = HashSet<String>()

    /** The member's own calendar day for a moment, "yyyy-MM-dd". */
    private fun localDate(ms: Long): String = NSDateFormatter().apply {
        dateFormat = "yyyy-MM-dd"; locale = NSLocale("en_US_POSIX")
    }.stringFromDate(NSDate.dateWithTimeIntervalSince1970(ms / 1_000.0))

    val manager: LetterboxdManager by lazy {
        LetterboxdManager(
            kv = kv,
            secrets = secrets,
            transport = KtorLetterboxdTransport(::macLetterboxdHttpClient),
            scope = work,
            localDate = ::localDate,
            newId = { "${kotlin.time.Clock.System.now().toEpochMilliseconds().toString(36)}-${Random.nextLong().toULong().toString(36)}" },
            isFavorite = { _, tmdb -> metaByTmdb[tmdb]?.let { MacAccountData.isInLibrary(it, "movie") } == true },
            watchlistSink = MacWatchlistSink,
        )
    }

    fun profileId(): Int = MacAccountData.activeProfileIndex

    // ------------------------------------------------------------------ sign-in (the web view is Swift's)

    val signInUrl: String get() = LetterboxdSignInSupport.SIGN_IN_URL
    val signInHost: String get() = LetterboxdSignInSupport.HOST
    fun isSignedIn(cookieNames: List<String>): Boolean = LetterboxdSignInSupport.isSignedIn(cookieNames)

    /** Hands the session the member signed in with (cookies and the web view's user agent) to the core, which checks it before keeping it. */
    fun connect(cookies: Map<String, String>, userAgent: String, username: String?, done: (MacLetterboxdConnect) -> Unit) {
        val profile = profileId()
        ui.launch {
            done(when (val r = manager.connect(profile, cookies, userAgent, username)) {
                is LetterboxdConnectResult.Connected -> MacLetterboxdConnect("connected", null)
                LetterboxdConnectResult.NeedsUsername -> MacLetterboxdConnect("needsUsername", null)
                is LetterboxdConnectResult.Failed -> MacLetterboxdConnect("failed", r.message)
            })
        }
    }

    // ------------------------------------------------------------------ observing

    /** Follows the active profile's screen state; call again (and cancel the old watch) when the profile changes. */
    fun watchScreen(onChange: (LetterboxdScreenState) -> Unit): MacWatch {
        val profile = profileId()
        onChange(manager.screenNow(profile, clock))
        return MacWatch(ui.launch { manager.screenFlow(profile, clock).collect { onChange(it) } })
    }

    fun watchActivity(onChange: (List<MacLetterboxdEvent>) -> Unit): MacWatch {
        val profile = profileId()
        return MacWatch(ui.launch {
            manager.engine.events.collect { events ->
                onChange(events.filter { it.profileId == profile }.sortedByDescending { it.atMs }.take(80).map { e ->
                    MacLetterboxdEvent(
                        id = e.id, atMs = e.atMs, title = e.title, kind = LetterboxdLabels.type(e.type), status = LetterboxdLabels.status(e.status),
                        note = listOfNotNull(e.viewingDate, e.note, LetterboxdLabels.error(e.error).takeIf { it.isNotEmpty() }).joinToString(" · ").takeIf { it.isNotEmpty() },
                        issue = LetterboxdLabels.needsAttention(e.status),
                    )
                })
            }
        })
    }

    fun watchJournal(onChange: (List<MacLetterboxdViewing>) -> Unit): MacWatch {
        val profile = profileId()
        return MacWatch(ui.launch {
            manager.engine.viewings.collect { viewings ->
                val ops = manager.engine.operations.value
                val hasAccount = manager.accountOf(profile) != null
                onChange(viewings.filter { it.profileId == profile }.sortedByDescending { it.completedAtMs }.take(400).map { v ->
                    val status = LetterboxdLabels.viewingStatus(v, ops, hasAccount)
                    MacLetterboxdViewing(
                        id = v.id, title = v.title, poster = v.posterUrl,
                        detail = buildString {
                            append(if (v.localDate == LetterboxdViewing.UNDATED) "Date unknown" else v.localDate)
                            if (v.rewatch) append(" · Rewatch")
                            v.stars?.let { append(" · ${LetterboxdRating.label(it)}★") }
                        },
                        status = status.label, tone = status.tone.name,
                    )
                })
            }
        })
    }

    fun watchlist(): MacLetterboxdWatchlist? {
        val snapshot = manager.watchlistFlow.value[profileId()] ?: return null
        return MacLetterboxdWatchlist(snapshot.films.map { MacLetterboxdWatchlistFilm(it.tmdbId, it.title, it.year) }, snapshot.completeAtMs)
    }

    /** How many distinct films came from the imported diary (the "mark as watched" row shows only when there are some). */
    fun importedFilmCount(): Int = importedFilms(profileId()).size

    // ------------------------------------------------------------------ actions (each reports back on the main thread)

    fun syncNow(done: () -> Unit) { val p = profileId(); ui.launch { manager.syncNowAndWait(p); done() } }
    fun refreshWatchlist(done: (Boolean) -> Unit) { val p = profileId(); ui.launch { done(manager.importWatchlist(p).films != null) } }
    fun setSyncWatchlist(on: Boolean, done: (String?) -> Unit) { val p = profileId(); ui.launch { done(manager.setSyncWatchlist(p, on)) } }
    fun retryFailed() = manager.retryAll(profileId())
    fun disconnect(deleteLocalHistory: Boolean, done: () -> Unit) { val p = profileId(); ui.launch { manager.disconnect(p, deleteLocalHistory); done() } }

    fun verifyConnection(done: (String) -> Unit) {
        val p = profileId()
        ui.launch {
            done(when (manager.checkConnection(p)) {
                LetterboxdConnectionState.Connected -> "Connected as ${manager.accountOf(p) ?: "your account"}."
                LetterboxdConnectionState.TemporarilyUnavailable -> "Letterboxd is unavailable right now. Try again later."
                LetterboxdConnectionState.Disconnected, LetterboxdConnectionState.Connecting -> "Not connected."
                else -> "Sign in again to keep syncing."
            })
        }
    }

    fun setLogFilms(on: Boolean) = manager.updateSettings(profileId()) { it.copy(autoLogMovies = on) }
    fun setSyncRatings(on: Boolean) = manager.updateSettings(profileId()) { it.copy(syncRatings = on) }
    fun setLogRewatches(on: Boolean) = manager.updateSettings(profileId()) { it.copy(logRewatches = on) }
    fun setSyncFavorites(on: Boolean) = manager.updateSettings(profileId()) { it.copy(syncFavorites = on) }
    fun setCompletionPercent(percent: Int) = manager.updateSettings(profileId()) { it.copy(completionThreshold = percent / 100.0) }

    /**
     * Reads the whole diary (in runs, because each new film needs a page read), optionally marks the films watched in BannerTV, and then
     * reads the watchlist when that is switched on. Nothing is sent to Letterboxd. Returns the sentence to show.
     */
    fun importHistory(markWatched: Boolean, done: (String) -> Unit) {
        val p = profileId()
        ui.launch {
            var runs = 0; var newFilms = 0; var partial = false; var message: String? = null
            while (runs < MAX_RUNS) {
                runs++
                val r = manager.importDiary(p)
                newFilms += r.newViewings; message = r.message; partial = r.partial
                if (!r.partial || r.message != null || r.newViewings == 0) break
            }
            var unidentified = 0
            if (markWatched) unidentified = markImportedWatchedNow(p).third
            if (!partial && manager.settingsFlow.value[p]?.watchlistToLibrary != false) runCatching { manager.importWatchlist(p) }
            done(LetterboxdScreenText.importSentence(newFilms, unidentified, partial, message))
        }
    }

    /** Marks the imported films watched in BannerTV. Films already marked are left alone; safe to run again. */
    fun markImportedWatched(done: (String) -> Unit) {
        val p = profileId()
        ui.launch {
            val (marked, already, unknown) = markImportedWatchedNow(p)
            done("${LetterboxdScreenText.films(marked)} marked as watched, $already already ${if (already == 1) "was" else "were"}." + if (unknown > 0) " $unknown couldn't be matched." else "")
        }
    }

    private fun importedFilms(profile: Int): List<LetterboxdViewing> =
        manager.engine.viewings.value.filter { it.profileId == profile && it.source == "import" }.sortedByDescending { it.completedAtMs }.distinctBy { it.tmdbId }

    /** (newly marked, already watched, could not be matched). Dates are the real viewing dates; nothing is stamped "now". */
    private suspend fun markImportedWatchedNow(profile: Int): Triple<Int, Int, Int> {
        check(profile == MacAccountData.activeProfileIndex) { "Switch to this profile to mark its Letterboxd films" }
        val films = importedFilms(profile)
        val items = ArrayList<MacWatched>(films.size)
        var already = 0; var unknown = 0
        films.chunked(8).forEach { chunk ->
            val resolved = coroutineScope {
                chunk.map { film ->
                    async {
                        if (film.tmdbId <= 0) film to null
                        // BannerTV's catalog ids are IMDb ids; TMDB's own id is the fallback for titles it has no IMDb id for.
                        else film to (runCatching { TmdbService.tmdbToImdb(film.tmdbId, "movie") }.getOrNull() ?: "tmdb:${film.tmdbId}")
                    }
                }.awaitAll()
            }
            resolved.forEach { (film, id) ->
                if (id == null) { unknown++; return@forEach }
                if (MacAccountData.isWatched(id, null, null)) { already++; return@forEach }
                items += MacWatched(id, "movie", film.title, null, null, film.completedAtMs)
            }
        }
        items.chunked(100).forEach { MacAccountData.setWatched(it, true, keepDates = true) }
        return Triple(items.size, already, unknown)
    }

    // ------------------------------------------------------------------ the player

    /** Called about once a second while a movie plays. Cheap when no account is connected; nothing counts until the film's TMDB id is known. */
    fun onPlayback(metaId: String, title: String, poster: String?, positionSeconds: Double, durationSeconds: Double, isPlaying: Boolean, isEnded: Boolean) {
        val profile = profileId()
        if (metaId.isBlank() || manager.accountOf(profile) == null) return
        val tmdb = tmdbByMeta[metaId]
        if (tmdb == null) {
            if (resolving.add(metaId)) work.launch {
                val id = runCatching { TmdbService.ensureTmdbId(metaId, "movie") }.getOrNull()?.toIntOrNull() ?: 0
                tmdbByMeta[metaId] = id
                if (id > 0) metaByTmdb[id] = metaId
                resolving.remove(metaId)
            }
            return
        }
        if (tmdb <= 0) return
        manager.playbackSample(profile, tmdb, title, poster, (positionSeconds * 1000).toLong(), (durationSeconds * 1000).toLong(), isPlaying, isEnded)
    }

    fun onPlaybackStopped(metaId: String) {
        val tmdb = tmdbByMeta[metaId]?.takeIf { it > 0 } ?: return
        manager.playbackStopped(profileId(), tmdb)
    }

    /** The app came to the front: send what is waiting and read the watchlist again when the last read is old. Never writes anything of its own. */
    fun onForeground() {
        val profile = profileId()
        if (manager.accountOf(profile) == null) return
        manager.syncNow()
        manager.refreshWatchlistIfStale(profile)
    }

    private const val MAX_RUNS = 25
}

internal fun macLetterboxdHttpClient(): HttpClient = HttpClient(Darwin) {
    followRedirects = false
    expectSuccess = false
    install(HttpTimeout) {
        requestTimeoutMillis = 30_000
        connectTimeoutMillis = 15_000
        socketTimeoutMillis = 30_000
    }
    engine {
        configureSession {
            // The session's cookies are added by hand and read from Set-Cookie: nothing is kept by the system.
            HTTPShouldSetCookies = false
            HTTPCookieStorage = null
        }
    }
}
