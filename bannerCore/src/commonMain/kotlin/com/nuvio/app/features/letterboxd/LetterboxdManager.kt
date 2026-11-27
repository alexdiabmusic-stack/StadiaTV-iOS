package com.nuvio.app.features.letterboxd

import com.nuvio.app.features.watchlist.WatchlistApplyResult
import com.nuvio.app.features.watchlist.WatchlistSink
import com.nuvio.app.features.watchlist.WatchlistTitle
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import com.nuvio.app.features.serializd.SerializdClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** Protected storage for the session material of each profile (the Keychain on iOS). Never plain preferences. */
interface LetterboxdSecretStore {
    fun read(profileId: Int): String?
    fun write(profileId: Int, value: String?)
}

@Serializable
private data class StoredSecret(val cookies: Map<String, String>, val userAgent: String, val username: String)

sealed interface LetterboxdConnectResult {
    data class Connected(val username: String) : LetterboxdConnectResult
    /** Signed in, but the username could not be read from the site: ask the member and call connect again with it. */
    data object NeedsUsername : LetterboxdConnectResult
    data class Failed(val message: String) : LetterboxdConnectResult
}

/** What reading the watchlist did. [films] is null when the read was not complete (nothing was replaced then). */
data class LetterboxdWatchlistResult(
    val films: Int?,
    val unmatched: Int,
    val message: String?,
    /** The one-line outcome of putting it in My List, when that was done. */
    val summary: String?,
)

data class LetterboxdImportResult(
    val newViewings: Int,
    val alreadyKnown: Int,
    val unmatched: Int,
    val pagesRead: Int,
    /** True when the run stopped early (limit reached or an error) and running it again continues. */
    val partial: Boolean,
    val message: String?,
)

/**
 * Everything the app does with Letterboxd, per profile: accounts, settings, sessions, the connection state, the player's
 * completion detection, and import. The platform supplies protected storage, the network, a place for the sign-in screen and
 * the player's samples; nothing else is needed.
 */
class LetterboxdManager(
    private val kv: LetterboxdKeyValue,
    private val secrets: LetterboxdSecretStore,
    private val transport: LetterboxdTransport,
    private val scope: CoroutineScope,
    private val now: () -> Long = { kotlin.time.Clock.System.now().toEpochMilliseconds() },
    private val localDate: (Long) -> String,
    private val newId: () -> String,
    /** Whether a title is one of the member's favourites (for the optional favourites-to-likes setting). */
    private val isFavorite: (profileId: Int, tmdbId: Int) -> Boolean = { _, _ -> false },
    private val pageSpacingMs: Long = 1_200L,
    /** Where the watchlist goes in the app (BannerTV's My List). Called only with a complete read. */
    private val watchlistSink: WatchlistSink = WatchlistSink { _, _, _ -> WatchlistApplyResult.NONE },
) : LetterboxdEngineHost {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val filmCache = LetterboxdFilmCache(kv, now)
    private val sessions = HashMap<Int, LetterboxdSession>()
    private val services = HashMap<Int, LetterboxdWebService>()
    private val sessionLock = Mutex()
    /** Guards the plain maps below, which the player's thread and background workers both reach. */
    private val mapLock = SynchronizedObject()
    private val importLock = Mutex()
    private val watchlistLock = Mutex()

    private val accounts = MutableStateFlow(loadMap(ACCOUNTS_KEY, LetterboxdAccount.serializer()))
    private val settings = MutableStateFlow(loadMap(SETTINGS_KEY, LetterboxdSettings.serializer()))
    private val states = MutableStateFlow(
        loadMap(STATES_KEY, String.serializer()).mapValues { (_, v) -> LetterboxdConnectionState.entries.firstOrNull { it.name == v } ?: LetterboxdConnectionState.Connected },
    )

    private val watchlists = MutableStateFlow(loadMap(WATCHLIST_KEY, LetterboxdWatchlistSnapshot.serializer()))
    /** The last complete read of each profile's watchlist. */
    val watchlistFlow: StateFlow<Map<Int, LetterboxdWatchlistSnapshot>> = watchlists.asStateFlow()

    val engine = LetterboxdSyncEngine(kv, this, now, localDate, newId)

    /** Per-profile account (null when none is connected). */
    val accountsFlow: StateFlow<Map<Int, LetterboxdAccount>> = accounts.asStateFlow()
    val settingsFlow: StateFlow<Map<Int, LetterboxdSettings>> = settings.asStateFlow()
    val connectionStates: StateFlow<Map<Int, LetterboxdConnectionState>> = states.asStateFlow()

    private val _finished = MutableSharedFlow<LetterboxdViewing>(extraBufferCapacity = 8)
    /** A film the member finished, once it is recorded: the app can show the post-watch sheet. */
    val finishedViewings: SharedFlow<LetterboxdViewing> = _finished.asSharedFlow()

    private val _importing = MutableStateFlow<String?>(null)
    /** A one-line status while an import runs, else null. */
    val importStatus: StateFlow<String?> = _importing.asStateFlow()

    private fun <T> loadMap(key: String, s: kotlinx.serialization.KSerializer<T>): Map<Int, T> =
        kv.read(key)?.let { raw -> runCatching { json.decodeFromString(MapSerializer(String.serializer(), s), raw) }.getOrNull() }
            .orEmpty().mapNotNull { (k, v) -> k.toIntOrNull()?.let { it to v } }.toMap()

    private fun <T> saveMap(key: String, map: Map<Int, T>, s: kotlinx.serialization.KSerializer<T>) =
        kv.write(key, json.encodeToString(MapSerializer(String.serializer(), s), map.mapKeys { it.key.toString() }))

    // ------------------------------------------------------------------ host for the engine

    override fun accountOf(profileId: Int): String? = accounts.value[profileId]?.username
    override fun settingsOf(profileId: Int): LetterboxdSettings = settings.value[profileId] ?: LetterboxdSettings()
    override fun serviceOf(profileId: Int): LetterboxdWebService? = serviceFor(profileId)

    override fun onConnectionState(profileId: Int, state: LetterboxdConnectionState) {
        if (accounts.value[profileId] == null) return
        setState(profileId, state)
    }

    private fun setState(profileId: Int, state: LetterboxdConnectionState) {
        if (states.value[profileId] == state) return
        states.value = states.value + (profileId to state)
        // Only the states that must survive a restart are stored; Connected is the default for a connected account.
        saveMap(STATES_KEY, states.value.filterValues { it != LetterboxdConnectionState.Connected && it != LetterboxdConnectionState.Connecting }.mapValues { it.value.name }, String.serializer())
    }

    fun stateOf(profileId: Int): LetterboxdConnectionState =
        if (accounts.value[profileId] == null) states.value[profileId]?.takeIf { it == LetterboxdConnectionState.Connecting } ?: LetterboxdConnectionState.Disconnected
        else states.value[profileId] ?: LetterboxdConnectionState.Connected

    // ------------------------------------------------------------------ sessions

    private fun serviceFor(profileId: Int): LetterboxdWebService? = synchronized(mapLock) {
        services[profileId]?.let { return@synchronized it }
        val session = sessionFor(profileId) ?: return@synchronized null
        LetterboxdWebService(session, filmCache, now, pageSpacingMs = pageSpacingMs).also { services[profileId] = it }
    }

    /** Only called with [mapLock] held. */
    private fun sessionFor(profileId: Int): LetterboxdSession? {
        sessions[profileId]?.let { return it }
        val raw = secrets.read(profileId) ?: return null
        val secret = runCatching { json.decodeFromString<StoredSecret>(raw) }.getOrNull() ?: return null
        if (accountOf(profileId)?.equals(secret.username, ignoreCase = true) != true) return null
        return LetterboxdSession(LetterboxdSessionMaterial(secret.cookies, secret.userAgent, secret.username), transport) { m -> saveSecret(profileId, m) }
            .also { sessions[profileId] = it }
    }

    private fun saveSecret(profileId: Int, m: LetterboxdSessionMaterial) {
        if (accounts.value[profileId] == null) return
        runCatching { secrets.write(profileId, json.encodeToString(StoredSecret(m.cookies, m.userAgent, m.username))) }
    }

    // ------------------------------------------------------------------ connect / disconnect

    /**
     * Completes a sign-in: [cookies] and [userAgent] are what the member's own sign-in produced in the web view. The session is
     * checked against the site and the username found (or taken from [usernameHint], which is checked too) before anything is stored.
     * A reconnect for a profile that has an account must be the same account.
     */
    suspend fun connect(profileId: Int, cookies: Map<String, String>, userAgent: String, usernameHint: String? = null): LetterboxdConnectResult = sessionLock.withLock {
        if (!LetterboxdSignInSupport.isSignedIn(cookies.keys)) return@withLock LetterboxdConnectResult.Failed("Letterboxd did not finish signing in. Try again.")
        val existing = accounts.value[profileId]?.username
        val previousState = states.value[profileId]
        setStateRaw(profileId, LetterboxdConnectionState.Connecting)
        try {
            val probe = LetterboxdSession(LetterboxdSessionMaterial(cookies, userAgent, usernameHint ?: existing ?: ""), transport)
            probe.validate()
            val found = LetterboxdAccountDiscovery.discoverUsername(probe)
            val name = usernameHint ?: found ?: existing
            if (name == null) { setStateRaw(profileId, previousState); return@withLock LetterboxdConnectResult.NeedsUsername }
            if (!LetterboxdSignInSupport.isValidUsername(name)) { setStateRaw(profileId, previousState); return@withLock LetterboxdConnectResult.Failed("That is not a Letterboxd username.") }
            if (existing != null && !existing.equals(name, ignoreCase = true)) {
                setStateRaw(profileId, previousState)
                return@withLock LetterboxdConnectResult.Failed("This profile is connected to $existing. Disconnect it before signing in as another account.")
            }
            if (found != null && !found.equals(name, ignoreCase = true)) {
                setStateRaw(profileId, previousState)
                return@withLock LetterboxdConnectResult.Failed("You signed in as $found, not $name.")
            }
            val checked = LetterboxdSession(LetterboxdSessionMaterial(probe.material().cookies, userAgent, name), transport)
            if (!LetterboxdAccountDiscovery.profileExists(checked, name)) { setStateRaw(profileId, previousState); return@withLock LetterboxdConnectResult.Failed("No Letterboxd profile named $name was found.") }
            val material = checked.material()
            accounts.value = accounts.value + (profileId to LetterboxdAccount(name, now(), now())); saveMap(ACCOUNTS_KEY, accounts.value, LetterboxdAccount.serializer())
            secrets.write(profileId, json.encodeToString(StoredSecret(material.cookies, material.userAgent, material.username)))
            synchronized(mapLock) { sessions.remove(profileId); services.remove(profileId) }
            setStateRaw(profileId, LetterboxdConnectionState.Connected); setState(profileId, LetterboxdConnectionState.Connected)
            scope.launch {
                engine.onReconnected(profileId); engine.processPending()
                // A first connection reads the watchlist (a handful of pages) so it can go to My List; it writes nothing to Letterboxd.
                if (existing == null && settingsOf(profileId).watchlistToLibrary) runCatching { importWatchlist(profileId) }
            }
            LetterboxdConnectResult.Connected(name)
        } catch (e: CancellationException) {
            throw e
        } catch (e: LetterboxdException.Blocked) {
            setStateRaw(profileId, previousState); LetterboxdConnectResult.Failed("Letterboxd is asking for a bot check right now. Try again in a little while.")
        } catch (e: LetterboxdException) {
            setStateRaw(profileId, previousState)
            LetterboxdConnectResult.Failed(if (e is LetterboxdException.SessionExpired) "Letterboxd did not accept that sign-in. Try again." else "Could not reach Letterboxd. Check your connection and try again.")
        }
    }

    private fun setStateRaw(profileId: Int, state: LetterboxdConnectionState?) {
        states.value = if (state == null) states.value - profileId else states.value + (profileId to state)
    }

    /** Signs the profile out of Letterboxd here: the session is deleted, nothing more is sent, queued writes are dropped. */
    suspend fun disconnect(profileId: Int, deleteLocalHistory: Boolean) = sessionLock.withLock {
        val account = accounts.value[profileId]?.username
        accounts.value = accounts.value - profileId; saveMap(ACCOUNTS_KEY, accounts.value, LetterboxdAccount.serializer())
        runCatching { secrets.write(profileId, null) }
        synchronized(mapLock) {
            sessions.remove(profileId); services.remove(profileId)
            trackers.keys.filter { it.startsWith("$profileId|") }.forEach { trackers.remove(it) }
        }
        setStateRaw(profileId, null)
        saveMap(STATES_KEY, states.value.filterValues { it != LetterboxdConnectionState.Connected && it != LetterboxdConnectionState.Connecting }.mapValues { it.value.name }, String.serializer())
        if (account != null) engine.onDisconnected(profileId, account, deleteLocalHistory)
        if (deleteLocalHistory) {
            settings.value = settings.value - profileId; saveMap(SETTINGS_KEY, settings.value, LetterboxdSettings.serializer())
            watchlists.value = watchlists.value - profileId; saveMap(WATCHLIST_KEY, watchlists.value, LetterboxdWatchlistSnapshot.serializer())
        }
    }

    /**
     * Removes every Letterboxd session, setting and local record for every profile: used when the app's account is wiped.
     * Nothing is sent to Letterboxd.
     */
    suspend fun wipeAll(maxProfiles: Int = 8) = sessionLock.withLock {
        (1..maxProfiles).forEach { runCatching { secrets.write(it, null) } }
        accounts.value.keys.forEach { runCatching { secrets.write(it, null) } }
        accounts.value = emptyMap(); settings.value = emptyMap(); states.value = emptyMap(); watchlists.value = emptyMap()
        listOf(ACCOUNTS_KEY, SETTINGS_KEY, STATES_KEY, SLUGS_KEY, WATCHLIST_KEY).forEach { kv.write(it, null) }
        synchronized(mapLock) { sessions.clear(); services.clear(); trackers.clear() }
        engine.wipeEverything()
    }

    /** Whether the stored session still works. Updates the connection state either way. */
    suspend fun checkConnection(profileId: Int): LetterboxdConnectionState {
        val service = serviceFor(profileId) ?: run { if (accounts.value[profileId] != null) setState(profileId, LetterboxdConnectionState.ReconnectionRequired); return stateOf(profileId) }
        try {
            if (service.validateSession()) { setState(profileId, LetterboxdConnectionState.Connected); engine.onReconnected(profileId) }
            else setState(profileId, LetterboxdConnectionState.SessionExpired)
        } catch (e: CancellationException) { throw e }
        catch (e: LetterboxdException.Blocked) { setState(profileId, LetterboxdConnectionState.TemporarilyUnavailable) }
        catch (e: LetterboxdException) { /* offline or a server error: the state is left as it was */ }
        return stateOf(profileId)
    }

    // ------------------------------------------------------------------ settings

    fun updateSettings(profileId: Int, change: (LetterboxdSettings) -> LetterboxdSettings) {
        val next = change(settingsOf(profileId))
        settings.value = settings.value + (profileId to next.copy(completionThreshold = next.completionThreshold.coerceIn(0.80, 1.0)))
        saveMap(SETTINGS_KEY, settings.value, LetterboxdSettings.serializer())
    }

    // ------------------------------------------------------------------ queue triggers

    /** Sends what is due: call when the app opens or returns to the foreground and when the network comes back. */
    fun syncNow() { scope.launch { engine.processPending() } }

    /** Checks the connection and sends what is waiting. A second call while one is running does nothing, so repeated taps never start two. */
    suspend fun syncNowAndWait(profileId: Int) {
        if (accounts.value[profileId] == null) return
        if (!beginSync(profileId)) return
        try {
            checkConnection(profileId)
            engine.processPending()
        } finally {
            endSync(profileId)
        }
    }

    /** Profiles with a Sync now in progress. */
    private val syncing = MutableStateFlow<Set<Int>>(emptySet())

    private fun beginSync(profileId: Int): Boolean {
        while (true) {
            val current = syncing.value
            if (profileId in current) return false
            if (syncing.compareAndSet(current, current + profileId)) return true
        }
    }

    private fun endSync(profileId: Int) {
        while (true) {
            val current = syncing.value
            if (syncing.compareAndSet(current, current - profileId)) return
        }
    }

    // ------------------------------------------------------------------ the settings screen

    /** What the settings screens show for a profile, kept current. The screens draw this and nothing else. */
    fun screenFlow(profileId: Int, clock: SerializdClock): Flow<LetterboxdScreenState> {
        val sources: List<Flow<Any?>> = listOf(accounts, states, settings, engine.operations, engine.events, engine.viewings, watchlists, _importing, syncing)
        return combine(sources) { screenNow(profileId, clock) }
    }

    /** The same state, read right now: the first frame of a screen, before the flow has emitted. */
    fun screenNow(profileId: Int, clock: SerializdClock): LetterboxdScreenState = LetterboxdScreenText.build(
        profileId = profileId, account = accounts.value[profileId], connection = stateOf(profileId), settings = settingsOf(profileId),
        operations = engine.operations.value, events = engine.events.value,
        journalFilms = engine.viewings.value.filter { it.profileId == profileId }.map { it.tmdbId }.distinct().size,
        watchlist = watchlists.value[profileId], importStatus = _importing.value, syncing = profileId in syncing.value,
        nowMs = now(), clock = clock,
    )

    /**
     * The "Sync watchlist" switch. Turning it on reads the watchlist now and adds it to My List; turning it off stops that, and
     * nothing already in My List is touched. Returns a short line for the member, or null.
     */
    suspend fun setSyncWatchlist(profileId: Int, on: Boolean): String? {
        updateSettings(profileId) { it.copy(watchlistToLibrary = on) }
        if (!on || accounts.value[profileId] == null) return null
        val r = importWatchlist(profileId)
        if (r.films == null) return addSavedWatchlistToMyList(profileId) ?: (r.message ?: "Couldn't read your watchlist. Try again in a moment.")
        return r.summary ?: "Read ${LetterboxdScreenText.films(r.films)} from your watchlist."
    }

    /** Tries everything held or stopped for a profile again. */
    fun retryAll(profileId: Int) {
        scope.launch {
            engine.operations.value.filter { it.profileId == profileId && it.status in LetterboxdScreenText.STOPPED }.forEach { engine.retry(it.id) }
            engine.processPending()
        }
    }

    fun setRating(profileId: Int, tmdbId: Int, title: String, stars: Double?, viewingId: String? = null) {
        scope.launch {
            engine.setRating(profileId, tmdbId, title, stars, viewingId)
            // The rating is held for the debounce, then sent.
            delay(LetterboxdSyncEngine.RATING_DEBOUNCE_MS + 500)
            engine.processPending()
        }
    }

    fun retry(opId: String) { scope.launch { engine.retry(opId); engine.processPending() } }

    fun logViewing(profileId: Int, tmdbId: Int, title: String, posterUrl: String?, stars: Double?) {
        scope.launch {
            engine.logViewingManually(profileId, tmdbId, title, posterUrl, stars, isFavorite(profileId, tmdbId) && settingsOf(profileId).syncFavorites)
            engine.processPending()
        }
    }

    suspend fun publishReview(viewingId: String, text: String, spoilers: Boolean, stars: Double?): LetterboxdReviewOutcome? {
        val outcome = engine.publishReview(viewingId, text, spoilers, stars)
        if (outcome == LetterboxdReviewOutcome.Queued) scope.launch { engine.processPending() }
        return outcome
    }

    // ------------------------------------------------------------------ playback

    private class Watching(var tracker: LetterboxdPlaybackTracker, var samples: Int = 0)

    private val trackers = HashMap<String, Watching>()

    /**
     * One look at the player, about once a second, for a movie. Does nothing when this profile has no Letterboxd account.
     * Never blocks: a completion is handed to a background task.
     */
    fun playbackSample(profileId: Int, tmdbId: Int, title: String, posterUrl: String?, positionMs: Long, durationMs: Long, isPlaying: Boolean, isEnded: Boolean) {
        if (accounts.value[profileId] == null || tmdbId <= 0) return
        val key = "$profileId|$tmdbId"
        val threshold = settingsOf(profileId).completionThreshold
        val w = synchronized(mapLock) { trackers.getOrPut(key) { Watching(newTracker(profileId, tmdbId, title, threshold)) } }
        val completion = w.tracker.onSample(positionMs, durationMs, isPlaying, isEnded, now())
        if (completion != null) {
            synchronized(mapLock) { trackers[key] = Watching(newTracker(profileId, tmdbId, title, threshold, fresh = true)) }
            scope.launch {
                engine.saveCoverage(profileId, tmdbId, WatchedCoverage())
                val viewing = engine.onCompletion(completion, posterUrl, isFavorite(profileId, tmdbId))
                _finished.emit(viewing)
                engine.processPending()
            }
            return
        }
        if (isPlaying && ++w.samples % COVERAGE_SAVE_EVERY == 0) {
            val coverage = w.tracker.coverage
            scope.launch { engine.saveCoverage(profileId, tmdbId, coverage) }
        }
    }

    private fun newTracker(profileId: Int, tmdbId: Int, title: String, threshold: Double, fresh: Boolean = false) =
        LetterboxdPlaybackTracker(
            sessionId = newId(), profileId = profileId, tmdbId = tmdbId, title = title,
            initialCoverage = if (fresh) WatchedCoverage() else engine.coverageNow(profileId, tmdbId), threshold = threshold,
        )

    /** The player left this movie (stopped, closed, or switched): progress is kept, and nothing counts as finished. */
    fun playbackStopped(profileId: Int, tmdbId: Int) {
        val w = synchronized(mapLock) { trackers.remove("$profileId|$tmdbId") } ?: return
        w.tracker.onInterrupted()
        val coverage = w.tracker.coverage
        if (!w.tracker.completed) scope.launch { engine.saveCoverage(profileId, tmdbId, coverage) }
    }

    // ------------------------------------------------------------------ import

    /**
     * Reads the member's diary and their watched-films list (every film they have marked watched, dated or not) and adds what is
     * missing to the Watch Journal here. It writes nothing to Letterboxd and is safe to run again: each diary entry has a stable
     * id, and a film already matched is remembered. Each new film needs one page read to learn its TMDB id, read a few at a
     * time; at most [maxFilms] are matched per run, and a bigger library is finished by running it again.
     */
    suspend fun importDiary(profileId: Int, maxFilms: Int = 3_000, maxPages: Int = 60, includeWatchedList: Boolean = true): LetterboxdImportResult {
        if (!importLock.tryLock()) return LetterboxdImportResult(0, 0, 0, 0, true, "An import is already running")
        try {
            val account = accountOf(profileId) ?: return LetterboxdImportResult(0, 0, 0, 0, false, "No Letterboxd account is connected")
            val service = serviceFor(profileId) ?: return LetterboxdImportResult(0, 0, 0, 0, true, "Reconnect Letterboxd first")
            val slugToTmdb = loadSlugMap().toMutableMap()
            val slugLock = Mutex()
            val imported = ArrayList<LetterboxdViewing>()
            var unmatched = 0; var already = 0; var pages = 0; var partial = false; var message: String? = null
            val known = engine.viewings.value.filter { it.profileId == profileId }.map { it.id }.toHashSet()
            val diary = ArrayList<LetterboxdDiaryRow>()
            val grid = ArrayList<LetterboxdGridFilm>()
            try {
                var page = 1
                while (page <= maxPages) {
                    _importing.value = "Reading diary page $page"
                    val (rows, more) = service.diaryPage(page); pages++
                    diary += rows
                    if (!more) break
                    page++
                    if (page > maxPages) partial = true
                }
                if (includeWatchedList) {
                    page = 1
                    while (page <= maxPages) {
                        _importing.value = "Reading watched films page $page"
                        val (films, more) = service.watchedGridPage(page); pages++
                        grid += films
                        if (!more) break
                        page++
                        if (page > maxPages) partial = true
                    }
                }
                // Which films still need their TMDB id, newest diary entries first.
                val todo = (diary.map { it.slug } + grid.map { it.slug }).distinct().filter { it !in slugToTmdb }
                val batch = todo.take(maxFilms)
                if (todo.size > batch.size) partial = true
                var done = 0
                if (batch.isNotEmpty()) coroutineScope {
                    val gate = Semaphore(IMPORT_PARALLEL)
                    batch.map { slug ->
                        async {
                            gate.withPermit {
                                val id = service.tmdbIdForSlug(slug)
                                slugLock.withLock {
                                    slugToTmdb[slug] = id ?: 0
                                    done++
                                    _importing.value = "Matching films $done of ${batch.size}"
                                    if (done % SLUG_SAVE_EVERY == 0) saveSlugMap(slugToTmdb)
                                }
                            }
                        }
                    }.awaitAll()
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: LetterboxdException) {
                partial = true; message = "Stopped early: ${e.message?.takeIf { it.isNotBlank() } ?: e.category.name}"
                if (e is LetterboxdException.SessionExpired) setState(profileId, LetterboxdConnectionState.SessionExpired)
            } finally {
                saveSlugMap(slugToTmdb)
                _importing.value = null
            }
            val titles = grid.mapNotNull { g -> g.title?.let { g.slug to it } }.toMap()
            fun titleOf(slug: String) = titles[slug] ?: slug.split('-').joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } }
            val diarySlugs = HashSet<String>()
            for (row in diary) {
                diarySlugs += row.slug
                val id = "imp-${account.lowercase()}-${row.date}-${row.slug}"
                if (id in known) { already++; continue }
                val tmdb = slugToTmdb[row.slug]
                if (tmdb == null) continue // not matched yet in this run (the run was cut short)
                if (tmdb <= 0) { unmatched++; continue }
                known += id
                imported += LetterboxdViewing(
                    id = id, profileId = profileId, tmdbId = tmdb, title = titleOf(row.slug), posterUrl = null,
                    completedAtMs = LetterboxdDates.epochDay(row.date)!! * 86_400_000L + 12 * 3_600_000L, localDate = row.date,
                    rewatch = row.rewatch, stars = row.stars, source = "import", onDiary = true,
                )
            }
            // Films marked watched with no diary entry: one undated record each.
            for (film in grid) {
                if (film.slug in diarySlugs) continue
                val id = "imp-${account.lowercase()}-list-${film.slug}"
                if (id in known) { already++; continue }
                val tmdb = slugToTmdb[film.slug] ?: continue
                if (tmdb <= 0) { unmatched++; continue }
                known += id
                imported += LetterboxdViewing(
                    id = id, profileId = profileId, tmdbId = tmdb, title = titleOf(film.slug), posterUrl = null,
                    completedAtMs = LetterboxdViewing.UNDATED_EPOCH_DAY * 86_400_000L + 12 * 3_600_000L, localDate = LetterboxdViewing.UNDATED,
                    stars = film.stars, source = "import", onDiary = true,
                )
            }
            val added = engine.addImported(profileId, account, imported)
            engine.recordEvent(profileId, account, 0, "Diary import", LetterboxdOperationType.ImportDiary,
                if (partial) LetterboxdOperationStatus.RetryScheduled else LetterboxdOperationStatus.Succeeded,
                "$added new, $already already here, $unmatched not matched (${diary.size} diary entries, ${grid.size} watched films read)" + if (partial) " (run again to continue)" else "")
            return LetterboxdImportResult(added, already, unmatched, pages, partial, message)
        } finally {
            importLock.unlock()
        }
    }

    // ------------------------------------------------------------------ watchlist

    /**
     * Reads the member's whole watchlist, matches each film to its TMDB id (the same page read per new film the diary import uses, kept in
     * the same cache), keeps the result and, when the setting is on, puts it in BannerTV's My List. It writes nothing to Letterboxd.
     * The saved copy is only replaced by a read that is complete: every page, no page repeated, the total the site declares reached, and every
     * film matched or known to have no TMDB movie. A failure part way keeps the last copy, and the matches made so far are kept for next time.
     */
    suspend fun importWatchlist(profileId: Int, maxPages: Int = MAX_WATCHLIST_PAGES): LetterboxdWatchlistResult {
        if (!watchlistLock.tryLock()) return LetterboxdWatchlistResult(null, 0, "A watchlist read is already running", null)
        try {
            val account = accountOf(profileId) ?: return LetterboxdWatchlistResult(null, 0, "No Letterboxd account is connected", null)
            val service = serviceFor(profileId) ?: return LetterboxdWatchlistResult(null, 0, "Reconnect Letterboxd first", null)
            val slugToTmdb = loadSlugMap().toMutableMap()
            val films = ArrayList<LetterboxdGridFilm>()
            val seen = HashSet<String>()
            try {
                var declared: Int? = null
                var page = 1
                while (true) {
                    if (page > maxPages) throw LetterboxdException.Unexpected("More than $maxPages watchlist pages")
                    _importing.value = "Reading watchlist page $page"
                    val result = service.watchlistPage(page)
                    declared = result.declaredTotal ?: declared
                    val before = seen.size
                    result.films.forEach { if (seen.add(it.slug)) films += it }
                    if (page > 1 && result.films.isNotEmpty() && seen.size == before) throw LetterboxdException.Unexpected("Watchlist page $page repeated earlier films")
                    if (!result.hasNext) break
                    page++
                }
                declared?.let { total -> if (seen.size != total) throw LetterboxdException.Unexpected("Letterboxd lists $total films but ${seen.size} were read") }
                val todo = films.map { it.slug }.filter { it !in slugToTmdb }
                matchSlugs(service, todo, slugToTmdb, "Matching watchlist films")
            } catch (e: CancellationException) {
                throw e
            } catch (e: LetterboxdException) {
                if (e is LetterboxdException.SessionExpired) setState(profileId, LetterboxdConnectionState.SessionExpired)
                val message = "The watchlist could not be read completely, so the last copy was kept: ${e.message?.takeIf { it.isNotBlank() } ?: e.category.name}"
                engine.recordEvent(profileId, account, 0, "Watchlist", LetterboxdOperationType.ImportDiary, LetterboxdOperationStatus.RetryScheduled, message)
                return LetterboxdWatchlistResult(null, 0, message, null)
            } finally {
                saveSlugMap(slugToTmdb)
                _importing.value = null
            }
            val matched = films.mapNotNull { f ->
                val tmdb = slugToTmdb[f.slug]?.takeIf { it > 0 } ?: return@mapNotNull null
                LetterboxdWatchlistFilm(f.slug, tmdb, f.title ?: f.slug.split('-').joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } }, f.year)
            }
            watchlists.value = watchlists.value + (profileId to LetterboxdWatchlistSnapshot(matched, now())); saveMap(WATCHLIST_KEY, watchlists.value, LetterboxdWatchlistSnapshot.serializer())
            accounts.value[profileId]?.let { accounts.value = accounts.value + (profileId to it.copy(lastWatchlistAtMs = now())); saveMap(ACCOUNTS_KEY, accounts.value, LetterboxdAccount.serializer()) }
            val summary = if (settingsOf(profileId).watchlistToLibrary) addToMyList(profileId, matched) else null
            return LetterboxdWatchlistResult(matched.size, films.size - matched.size, null, summary)
        } finally {
            watchlistLock.unlock()
        }
    }

    /** Puts the saved watchlist in My List without reading Letterboxd again (what switching the setting on does). Null when there is no saved copy. */
    suspend fun addSavedWatchlistToMyList(profileId: Int): String? {
        val snapshot = watchlists.value[profileId] ?: return null
        return addToMyList(profileId, snapshot.films)
    }

    private suspend fun addToMyList(profileId: Int, films: List<LetterboxdWatchlistFilm>): String {
        val summary = try {
            watchlistSink.apply(profileId, "letterboxd", films.map { WatchlistTitle(it.tmdbId, false, it.title, it.year) }).summary()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // A failure here never costs the watchlist copy that was just read.
            "Could not add the watchlist to My List: ${e.message?.take(100) ?: "unexpected error"}"
        }
        accounts.value[profileId]?.let { accounts.value = accounts.value + (profileId to it.copy(lastWatchlistSummary = summary)); saveMap(ACCOUNTS_KEY, accounts.value, LetterboxdAccount.serializer()) }
        accountOf(profileId)?.let { engine.recordEvent(profileId, it, 0, "Watchlist to My List", LetterboxdOperationType.ImportDiary, LetterboxdOperationStatus.Succeeded, summary) }
        return summary
    }

    /**
     * Called when the app comes to the front: reads the watchlist again when the last read is old (at most every [maxAgeMs]). Does nothing for a
     * profile with no Letterboxd account or while the session needs the member, and writes nothing to Letterboxd.
     */
    fun refreshWatchlistIfStale(profileId: Int, maxAgeMs: Long = REFRESH_AFTER_MS) {
        val account = accounts.value[profileId] ?: return
        if (stateOf(profileId) != LetterboxdConnectionState.Connected) return
        if (!settingsOf(profileId).watchlistToLibrary) return
        if (now() - account.lastWatchlistAtMs <= maxAgeMs) return
        scope.launch { runCatching { importWatchlist(profileId) } }
    }

    /** Matches film slugs to TMDB ids a few at a time (0 marks a TV entry or a film with no TMDB movie), saving progress as it goes. */
    private suspend fun matchSlugs(service: LetterboxdWebService, todo: List<String>, slugToTmdb: MutableMap<String, Int>, label: String) {
        if (todo.isEmpty()) return
        val slugLock = Mutex()
        var done = 0
        coroutineScope {
            val gate = Semaphore(IMPORT_PARALLEL)
            todo.map { slug ->
                async {
                    gate.withPermit {
                        val id = service.tmdbIdForSlug(slug)
                        slugLock.withLock {
                            slugToTmdb[slug] = id ?: 0
                            done++
                            _importing.value = "$label $done of ${todo.size}"
                            if (done % SLUG_SAVE_EVERY == 0) saveSlugMap(slugToTmdb)
                        }
                    }
                }
            }.awaitAll()
        }
    }

    private fun loadSlugMap(): Map<String, Int> =
        kv.read(SLUGS_KEY)?.let { runCatching { json.decodeFromString(MapSerializer(String.serializer(), Int.serializer()), it) }.getOrNull() }.orEmpty()

    private fun saveSlugMap(map: Map<String, Int>) = kv.write(SLUGS_KEY, json.encodeToString(MapSerializer(String.serializer(), Int.serializer()), map))

    private companion object {
        const val ACCOUNTS_KEY = "letterboxd_accounts_v1"
        const val SETTINGS_KEY = "letterboxd_settings_v1"
        const val STATES_KEY = "letterboxd_states_v1"
        const val SLUGS_KEY = "letterboxd_slug_tmdb_v1"
        const val WATCHLIST_KEY = "letterboxd_watchlist_v1"
        const val MAX_WATCHLIST_PAGES = 100
        const val REFRESH_AFTER_MS = 12 * 3_600_000L
        const val COVERAGE_SAVE_EVERY = 20
        const val IMPORT_PARALLEL = 4
        const val SLUG_SAVE_EVERY = 25
    }
}
