package com.nuvio.app.features.serializd

import com.nuvio.app.features.letterboxd.LetterboxdPlaybackTracker
import com.nuvio.app.features.letterboxd.WatchedCoverage
import com.nuvio.app.features.watchlist.WatchlistApplyResult
import com.nuvio.app.features.watchlist.WatchlistSink
import com.nuvio.app.features.watchlist.WatchlistTitle
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlin.math.abs

/** Protected storage for the credentials and token of each profile (the Keychain on iOS). Never plain preferences. */
interface SerializdSecretStore {
    fun read(profileId: Int): String?
    fun write(profileId: Int, value: String?)
}

@Serializable
private data class StoredSecret(val email: String, val password: String, val token: String? = null, val username: String? = null)

sealed interface SerializdConnectResult {
    data class Connected(val username: String) : SerializdConnectResult
    data class Failed(val message: String) : SerializdConnectResult
    /** Too many wrong sign-ins in a row: try again in [waitMs]. */
    data class TooManyAttempts(val waitMs: Long) : SerializdConnectResult
}

/** Where history read from Serializd goes in the app: BannerTV's own watched list. Called with only what is new. */
fun interface SerializdImportSink {
    suspend fun apply(profileId: Int, episodes: List<SerializdImportedEpisode>)
}

/**
 * Everything the app does with Serializd, per profile: accounts, settings, sessions, the connection state, the player's completion
 * detection, import and the watchlist. The platform supplies protected storage, the network, the player's samples and a place for the
 * imported history to land; nothing else is needed.
 */
class SerializdManager(
    private val kv: SerializdKeyValue,
    private val secrets: SerializdSecretStore,
    private val transport: SerializdTransport,
    private val scope: CoroutineScope,
    private val now: () -> Long = { kotlin.time.Clock.System.now().toEpochMilliseconds() },
    private val newId: () -> String,
    /** Whether a series is one of the member's favourites (for the optional favourites-to-likes setting). */
    private val isFavorite: (profileId: Int, showTmdbId: Int) -> Boolean = { _, _ -> false },
    private val seasonLengthsOf: suspend (showTmdbId: Int) -> Map<Int, Int> = { emptyMap() },
    private val importSink: SerializdImportSink = SerializdImportSink { _, _ -> },
    /** Where the watchlist goes in the app (BannerTV's My List). Called only with a complete read. */
    private val watchlistSink: WatchlistSink = WatchlistSink { _, _, _ -> WatchlistApplyResult.NONE },
    private val pause: suspend (Long) -> Unit = { delay(it) },
) : SerializdEngineHost {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val sessions = HashMap<Int, SerializdSession>()
    private val services = HashMap<Int, SerializdService>()
    private val limiters = HashMap<Int, SerializdLoginLimiter>()
    private val sessionLock = Mutex()
    /** Guards the plain maps above, which the player's thread and background workers both reach. */
    private val mapLock = SynchronizedObject()
    private val importLock = Mutex()
    private val watchlistLock = Mutex()

    private val accounts = MutableStateFlow(loadMap(ACCOUNTS_KEY, SerializdAccount.serializer()))
    private val settings = MutableStateFlow(loadMap(SETTINGS_KEY, SerializdSettings.serializer()))
    private val states = MutableStateFlow(
        loadMap(STATES_KEY, String.serializer()).mapValues { (_, v) -> SerializdConnectionState.entries.firstOrNull { it.name == v } ?: SerializdConnectionState.Connected },
    )
    private val watchlists = MutableStateFlow(loadMap(WATCHLIST_KEY, SerializdWatchlistSnapshot.serializer()))
    private val remote = MutableStateFlow(
        kv.read(REMOTE_KEY)?.let { raw -> runCatching { json.decodeFromString(MapSerializer(String.serializer(), ListSerializer(SerializdRemoteEntry.serializer())), raw) }.getOrNull() }.orEmpty(),
    )

    val engine = SerializdSyncEngine(kv, this, now, newId)

    /** Per-profile account (absent when none is connected). */
    val accountsFlow: StateFlow<Map<Int, SerializdAccount>> = accounts.asStateFlow()
    val settingsFlow: StateFlow<Map<Int, SerializdSettings>> = settings.asStateFlow()
    val connectionStates: StateFlow<Map<Int, SerializdConnectionState>> = states.asStateFlow()
    /** The last complete read of each profile's watchlist. */
    val watchlistFlow: StateFlow<Map<Int, SerializdWatchlistSnapshot>> = watchlists.asStateFlow()
    /** Entries about whole shows and seasons read from the diary, by lower-case account name. */
    val remoteEntriesFlow: StateFlow<Map<String, List<SerializdRemoteEntry>>> = remote.asStateFlow()

    private val _finished = MutableSharedFlow<SerializdWatch>(extraBufferCapacity = 8)
    /** An episode the member finished, once it is recorded. */
    val finishedWatches: SharedFlow<SerializdWatch> = _finished.asSharedFlow()

    /** Profiles with a Sync now in progress. */
    private val syncing = MutableStateFlow<Set<Int>>(emptySet())

    private val _status = MutableStateFlow<String?>(null)
    /** A one-line status while an import or a watchlist refresh runs, else null. */
    val importStatus: StateFlow<String?> = _status.asStateFlow()

    private fun <T> loadMap(key: String, s: kotlinx.serialization.KSerializer<T>): Map<Int, T> =
        kv.read(key)?.let { raw -> runCatching { json.decodeFromString(MapSerializer(String.serializer(), s), raw) }.getOrNull() }
            .orEmpty().mapNotNull { (k, v) -> k.toIntOrNull()?.let { it to v } }.toMap()

    private fun <T> saveMap(key: String, map: Map<Int, T>, s: kotlinx.serialization.KSerializer<T>) =
        kv.write(key, json.encodeToString(MapSerializer(String.serializer(), s), map.mapKeys { it.key.toString() }))

    // ------------------------------------------------------------------ host for the engine

    override fun accountOf(profileId: Int): String? = accounts.value[profileId]?.username
    override fun settingsOf(profileId: Int): SerializdSettings = settings.value[profileId] ?: SerializdSettings()
    override fun serviceOf(profileId: Int): SerializdService? = serviceFor(profileId)
    override suspend fun seasonLengths(showTmdbId: Int): Map<Int, Int> = seasonLengthsOf(showTmdbId)

    override fun onConnectionState(profileId: Int, state: SerializdConnectionState) {
        if (accounts.value[profileId] == null) return
        setState(profileId, state)
    }

    private fun setState(profileId: Int, state: SerializdConnectionState) {
        if (states.value[profileId] == state) return
        states.value = states.value + (profileId to state)
        // Only the states that must survive a restart are stored; Connected is the default for a connected account.
        saveMap(STATES_KEY, states.value.filterValues { it != SerializdConnectionState.Connected && it != SerializdConnectionState.Connecting }.mapValues { it.value.name }, String.serializer())
    }

    private fun setStateRaw(profileId: Int, state: SerializdConnectionState?) {
        states.value = if (state == null) states.value - profileId else states.value + (profileId to state)
    }

    fun stateOf(profileId: Int): SerializdConnectionState =
        if (accounts.value[profileId] == null) states.value[profileId]?.takeIf { it == SerializdConnectionState.Connecting } ?: SerializdConnectionState.Disconnected
        else states.value[profileId] ?: SerializdConnectionState.Connected

    // ------------------------------------------------------------------ sessions

    private fun serviceFor(profileId: Int): SerializdService? = synchronized(mapLock) {
        services[profileId]?.let { return@synchronized it }
        val session = sessionFor(profileId) ?: return@synchronized null
        val api = SerializdApi(session)
        SerializdService(api, SerializdSeasonResolver(api, kv, now, "${SerializdSeasonResolver.KEY}_$profileId")).also { services[profileId] = it }
    }

    /** Only called with [mapLock] held. */
    private fun sessionFor(profileId: Int): SerializdSession? {
        sessions[profileId]?.let { return it }
        val raw = secrets.read(profileId) ?: return null
        val secret = runCatching { json.decodeFromString<StoredSecret>(raw) }.getOrNull() ?: return null
        if (accounts.value[profileId] == null) return null
        return SerializdSession(SerializdSessionMaterial(secret.email, secret.password, secret.token, secret.username), transport, { m -> saveSecret(profileId, m) }, pause)
            .also { sessions[profileId] = it }
    }

    private fun saveSecret(profileId: Int, m: SerializdSessionMaterial) {
        if (accounts.value[profileId] == null) return
        runCatching { secrets.write(profileId, json.encodeToString(StoredSecret(m.email, m.password, m.token, m.username))) }
    }

    private fun limiter(profileId: Int) = synchronized(mapLock) { limiters.getOrPut(profileId) { SerializdLoginLimiter(now) } }

    // ------------------------------------------------------------------ connect / disconnect

    /**
     * Signs in with the member's Serializd email and password. Nothing is stored and "Connected" is not shown until Serializd has
     * accepted the sign-in and given the username. A profile that already has an account can only reconnect as that account.
     */
    suspend fun connect(profileId: Int, email: String, password: String, guidedSetup: Boolean = false): SerializdConnectResult = sessionLock.withLock {
        val mail = email.trim()
        if (mail.isBlank() || password.isBlank()) return@withLock SerializdConnectResult.Failed("Enter the email and password of your Serializd account.")
        val wait = limiter(profileId).waitMs()
        if (wait > 0) return@withLock SerializdConnectResult.TooManyAttempts(wait)
        val existing = accounts.value[profileId]?.username
        val previousState = states.value[profileId]
        setStateRaw(profileId, SerializdConnectionState.Connecting)
        try {
            val probe = SerializdSession(SerializdSessionMaterial(mail, password, null, null), transport, pause = pause)
            val name = probe.signIn()
            limiter(profileId).recordSuccess()
            if (existing != null && !existing.equals(name, ignoreCase = true)) {
                setStateRaw(profileId, previousState)
                return@withLock SerializdConnectResult.Failed("This profile is connected to $existing. Disconnect it before signing in as another account.")
            }
            val material = probe.material()
            // A new account that connects through the setup step waits for the member's choice before anything is read; a reconnect never does.
            val waitForSetup = guidedSetup && existing == null
            accounts.value = accounts.value + (profileId to (accounts.value[profileId]?.copy(lastValidatedAtMs = now()) ?: SerializdAccount(name, now(), now(), setupPending = waitForSetup))); saveMap(ACCOUNTS_KEY, accounts.value, SerializdAccount.serializer())
            secrets.write(profileId, json.encodeToString(StoredSecret(material.email, material.password, material.token, material.username)))
            synchronized(mapLock) { sessions.remove(profileId); services.remove(profileId) }
            setStateRaw(profileId, SerializdConnectionState.Connected); setState(profileId, SerializdConnectionState.Connected)
            scope.launch {
                engine.onReconnected(profileId); engine.processPending()
                // The first connection reads what is already on Serializd; it never sends BannerTV's own history without being asked.
                if (existing == null && !waitForSetup) runCatching { importHistory(profileId); if (settingsOf(profileId).importWatchlist) refreshWatchlist(profileId) }
            }
            SerializdConnectResult.Connected(name)
        } catch (e: CancellationException) {
            throw e
        } catch (e: SerializdException.BadCredentials) {
            limiter(profileId).recordFailure()
            setStateRaw(profileId, previousState); SerializdConnectResult.Failed("Serializd did not accept that email and password.")
        } catch (e: SerializdException.RateLimited) {
            setStateRaw(profileId, previousState); SerializdConnectResult.Failed("Serializd is busy right now. Try again in a little while.")
        } catch (e: SerializdException.Server) {
            setStateRaw(profileId, previousState); SerializdConnectResult.Failed("Serializd is having trouble right now. Try again in a little while.")
        } catch (e: SerializdException) {
            setStateRaw(profileId, previousState); SerializdConnectResult.Failed("Could not reach Serializd. Check your connection and try again.")
        }
    }

    /** Signs the profile out of Serializd here: the credentials and token are deleted, nothing more is sent, queued writes are dropped. */
    suspend fun disconnect(profileId: Int, deleteLocalHistory: Boolean) = sessionLock.withLock {
        val account = accounts.value[profileId]?.username
        accounts.value = accounts.value - profileId; saveMap(ACCOUNTS_KEY, accounts.value, SerializdAccount.serializer())
        runCatching { secrets.write(profileId, null) }
        synchronized(mapLock) {
            sessions.remove(profileId); services.remove(profileId); limiters.remove(profileId)
            trackers.keys.filter { it.startsWith("$profileId|") }.forEach { trackers.remove(it) }
        }
        setStateRaw(profileId, null)
        saveMap(STATES_KEY, states.value.filterValues { it != SerializdConnectionState.Connected && it != SerializdConnectionState.Connecting }.mapValues { it.value.name }, String.serializer())
        kv.write("${SerializdSeasonResolver.KEY}_$profileId", null)
        if (account != null) engine.onDisconnected(profileId, account, deleteLocalHistory)
        if (deleteLocalHistory) {
            settings.value = settings.value - profileId; saveMap(SETTINGS_KEY, settings.value, SerializdSettings.serializer())
            watchlists.value = watchlists.value - profileId; saveMap(WATCHLIST_KEY, watchlists.value, SerializdWatchlistSnapshot.serializer())
            if (account != null) { remote.value = remote.value - account.lowercase(); saveRemote() }
        }
    }

    /** Removes every Serializd credential, setting and local record for every profile: used when the app's account is wiped. Nothing is sent to Serializd. */
    suspend fun wipeAll(maxProfiles: Int = 8) = sessionLock.withLock {
        (1..maxProfiles).forEach { runCatching { secrets.write(it, null) }; kv.write("${SerializdSeasonResolver.KEY}_$it", null) }
        accounts.value.keys.forEach { runCatching { secrets.write(it, null) } }
        accounts.value = emptyMap(); settings.value = emptyMap(); states.value = emptyMap(); watchlists.value = emptyMap(); remote.value = emptyMap()
        listOf(ACCOUNTS_KEY, SETTINGS_KEY, STATES_KEY, WATCHLIST_KEY, REMOTE_KEY).forEach { kv.write(it, null) }
        synchronized(mapLock) { sessions.clear(); services.clear(); trackers.clear(); limiters.clear() }
        engine.wipeEverything()
    }

    /** Whether the saved token still works, signing in again with the saved credentials when it does not. Updates the connection state. */
    suspend fun checkConnection(profileId: Int): SerializdConnectionState {
        val service = serviceFor(profileId) ?: run { if (accounts.value[profileId] != null) setState(profileId, SerializdConnectionState.ReconnectionRequired); return stateOf(profileId) }
        try {
            if (!service.session.validate()) service.session.signIn()
            accounts.value[profileId]?.let { accounts.value = accounts.value + (profileId to it.copy(lastValidatedAtMs = now())); saveMap(ACCOUNTS_KEY, accounts.value, SerializdAccount.serializer()) }
            setState(profileId, SerializdConnectionState.Connected); engine.onReconnected(profileId)
        } catch (e: CancellationException) {
            throw e
        } catch (e: SerializdException.BadCredentials) {
            setState(profileId, SerializdConnectionState.ReconnectionRequired)
        } catch (e: SerializdException.ReconnectRequired) {
            setState(profileId, SerializdConnectionState.ReconnectionRequired)
        } catch (e: SerializdException.SessionExpired) {
            setState(profileId, SerializdConnectionState.SessionExpired)
        } catch (e: SerializdException.Server) {
            setState(profileId, SerializdConnectionState.TemporarilyUnavailable)
        } catch (e: SerializdException) { /* offline or an odd answer: the state is left as it was */ }
        return stateOf(profileId)
    }

    // ------------------------------------------------------------------ settings

    fun updateSettings(profileId: Int, change: (SerializdSettings) -> SerializdSettings) {
        val next = change(settingsOf(profileId))
        settings.value = settings.value + (profileId to next.copy(completionThreshold = next.completionThreshold.coerceIn(0.70, 1.0)))
        saveMap(SETTINGS_KEY, settings.value, SerializdSettings.serializer())
    }

    // ------------------------------------------------------------------ queue triggers and actions

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

    /** What the settings screens show for a profile, kept current. The platforms draw this and nothing else. */
    fun screenFlow(profileId: Int, clock: SerializdClock): Flow<SerializdScreenState> {
        val sources: List<Flow<Any?>> = listOf(accounts, states, settings, engine.operations, engine.events, watchlists, _status, syncing)
        return combine(sources) { screenNow(profileId, clock) }
    }

    /** The same state, read right now: the first frame of a screen, before the flow has emitted. */
    fun screenNow(profileId: Int, clock: SerializdClock): SerializdScreenState {
        val account = accounts.value[profileId]
        return SerializdScreenText.build(
            profileId = profileId, account = account, connection = stateOf(profileId), settings = settingsOf(profileId),
            operations = engine.operations.value, events = engine.events.value,
            trackedEpisodes = account?.let { engine.trackedEpisodeCount(it.username) } ?: 0,
            watchlist = watchlists.value[profileId], importStatus = _status.value, syncing = profileId in syncing.value,
            nowMs = now(), clock = clock,
        )
    }

    /**
     * The single "Sync watchlist" switch: the watchlist is read and added to My List together. Turning it on reads it now (or adds the
     * copy already held); turning it off stops both, and nothing already in My List is touched. Returns a short line for the member, or null.
     */
    suspend fun setSyncWatchlist(profileId: Int, on: Boolean): String? {
        updateSettings(profileId) { it.copy(importWatchlist = on, watchlistToLibrary = on) }
        if (!on || accounts.value[profileId] == null) return null
        // Read the live watchlist (which also adds it to My List); only when that fails is the copy already held used.
        val shows = refreshWatchlist(profileId)
        if (shows != null) return accounts.value[profileId]?.lastWatchlistSummary ?: "Read $shows ${if (shows == 1) "show" else "shows"} from your watchlist."
        return addSavedWatchlistToMyList(profileId) ?: "Couldn't read your watchlist. Try again in a moment."
    }

    /** The one-tap import from the main screen: history first, then the watchlist when that is switched on. Returns the sentence to show. */
    suspend fun importFromSerializd(profileId: Int): String {
        val result = importHistory(profileId)
        if (settingsOf(profileId).importWatchlist && !result.partial) runCatching { refreshWatchlist(profileId) }
        return result.message?.takeIf { result.newEpisodes == 0 && result.unmatched == 0 && result.partial }
            ?: SerializdScreenText.importSentence(
                SerializdImportStats(now(), result.newEpisodes, result.alreadyKnown, result.unmatched, partial = result.partial),
            )
    }

    /**
     * Finishes the setup step. "Recommended" switches on episode tracking, ratings and the watchlist, leaves the diary, rewatch and
     * completion choices as they are, and reads what is already on Serializd (history and watchlist). "Customize" just ends the step so
     * the member can set things first. Neither ever sends BannerTV's own history to Serializd.
     */
    suspend fun completeSetup(profileId: Int, recommended: Boolean) {
        val account = accounts.value[profileId] ?: return
        if (!account.setupPending) return
        accounts.value = accounts.value + (profileId to account.copy(setupPending = false)); saveMap(ACCOUNTS_KEY, accounts.value, SerializdAccount.serializer())
        if (!recommended) return
        updateSettings(profileId) { it.copy(autoTrackEpisodes = true, syncRatings = true, importWatchedHistory = true, importWatchlist = true, watchlistToLibrary = true) }
        runCatching { importHistory(profileId); refreshWatchlist(profileId) }
    }

    fun setRating(profileId: Int, target: SerializdTarget, title: String, stars: Double?, watchId: String? = null) {
        scope.launch {
            engine.setRating(profileId, target, title, stars, watchId)
            // The rating is held for the debounce, then sent.
            delay(SerializdSyncEngine.RATING_DEBOUNCE_MS + 500)
            engine.processPending()
        }
    }

    fun setShowFavorite(profileId: Int, showTmdbId: Int, title: String, liked: Boolean) {
        scope.launch { engine.setShowLike(profileId, showTmdbId, title, liked); delay(SerializdSyncEngine.RATING_DEBOUNCE_MS + 500); engine.processPending() }
    }

    /**
     * Called when the app comes to the front: reads Serializd again when the last read is old (at most every [maxAgeMs]), so history and
     * the watchlist stay current without the member asking. iOS gives no guaranteed background time, so this happens while the app is open.
     * Does nothing for a profile that is not connected, and never writes to Serializd.
     */
    fun refreshIfStale(profileId: Int, maxAgeMs: Long = REFRESH_AFTER_MS) {
        val account = accounts.value[profileId] ?: return
        if (stateOf(profileId) != SerializdConnectionState.Connected) return
        if (account.setupPending) return
        val config = settingsOf(profileId)
        val t = now()
        scope.launch {
            if (config.importWatchedHistory && t - account.lastImportAtMs > maxAgeMs) runCatching { importHistory(profileId) }
            if (config.importWatchlist && t - account.lastWatchlistAtMs > maxAgeMs) runCatching { refreshWatchlist(profileId) }
        }
    }

    fun retry(opId: String) { scope.launch { engine.retry(opId); engine.processPending() } }
    fun retryAll(profileId: Int) { scope.launch { engine.retryAll(profileId); engine.processPending() } }

    /** A viewing the member logs by hand, on the date they give. */
    fun logViewing(profileId: Int, target: SerializdTarget, title: String, posterUrl: String?, watchedAtMs: Long, stars: Double?, rewatch: Boolean? = null) {
        scope.launch { engine.logViewingManually(profileId, target, title, posterUrl, watchedAtMs, stars, rewatch); engine.processPending() }
    }

    /**
     * Marks an episode watched on Serializd without making a diary entry, for the member who only wants the marker. The date is never
     * invented: a dated entry is a separate choice ([logViewing]).
     */
    fun markEpisodeWatched(profileId: Int, target: SerializdTarget, title: String) {
        val season = target.seasonNumber ?: return
        val episode = target.episodeNumber ?: return
        scope.launch {
            engine.enqueueBackfill(profileId, listOf(SerializdBackfillEpisode(target.showTmdbId, title, season, episode, null)), withDiary = false)
            engine.processPending()
        }
    }

    fun unmarkEpisode(profileId: Int, target: SerializdTarget, title: String) {
        scope.launch { engine.unmarkEpisode(profileId, target, title); engine.processPending() }
    }

    suspend fun publishReview(profileId: Int, target: SerializdTarget, title: String, text: String, spoilers: Boolean, stars: Double?, watchId: String? = null): SerializdReviewOutcome {
        val outcome = engine.publishReview(profileId, target, title, text, spoilers, stars, watchId)
        if (outcome == SerializdReviewOutcome.Queued) scope.launch { engine.processPending() }
        return outcome
    }

    /** The optional backfill of BannerTV's own watched history to Serializd. Nothing is sent until the member asks for it. */
    suspend fun backfill(profileId: Int, episodes: List<SerializdBackfillEpisode>, withDiary: Boolean): Triple<Int, Int, Int> {
        val queued = engine.enqueueBackfill(profileId, episodes, withDiary)
        scope.launch { engine.processPending() }
        return queued
    }

    // ------------------------------------------------------------------ playback

    private class Watching(var tracker: LetterboxdPlaybackTracker, var samples: Int = 0)

    private val trackers = HashMap<String, Watching>()

    /**
     * One look at the player, about once a second, for a TV episode. Does nothing when this profile has no Serializd account or episode
     * tracking is off. Never blocks: a completion is handed to a background task. Completion follows the same rules as films on
     * Letterboxd: only playing time counts, a seek does not, and stopping the player never completes an episode.
     */
    fun playbackSample(
        profileId: Int, showTmdbId: Int, seasonNumber: Int, episodeNumber: Int, showName: String, episodeTitle: String?, posterUrl: String?,
        positionMs: Long, durationMs: Long, isPlaying: Boolean, isEnded: Boolean,
    ) {
        if (accounts.value[profileId] == null || showTmdbId <= 0 || seasonNumber < 0 || episodeNumber <= 0) return
        val config = settingsOf(profileId)
        if (!config.autoTrackEpisodes) return
        val episodeKey = "$showTmdbId|$seasonNumber|$episodeNumber"
        val key = "$profileId|$episodeKey"
        val w = synchronized(mapLock) { trackers.getOrPut(key) { Watching(newTracker(profileId, showTmdbId, showName, episodeKey, config.completionThreshold)) } }
        val completion = w.tracker.onSample(positionMs, durationMs, isPlaying, isEnded, now())
        if (completion != null) {
            synchronized(mapLock) { trackers[key] = Watching(newTracker(profileId, showTmdbId, showName, episodeKey, config.completionThreshold, fresh = true)) }
            scope.launch {
                engine.saveCoverage(profileId, episodeKey, WatchedCoverage())
                val watch = engine.onCompletion(
                    SerializdCompletion(completion.sessionId, profileId, showTmdbId, seasonNumber, listOf(episodeNumber), showName, episodeTitle, completion.completedAtMs, completion.watchedFraction),
                    posterUrl, isFavorite(profileId, showTmdbId),
                )
                if (watch != null) _finished.emit(watch)
                engine.processPending()
            }
            return
        }
        if (isPlaying && ++w.samples % COVERAGE_SAVE_EVERY == 0) {
            val coverage = w.tracker.coverage
            scope.launch { engine.saveCoverage(profileId, episodeKey, coverage) }
        }
    }

    private fun newTracker(profileId: Int, showTmdbId: Int, showName: String, episodeKey: String, threshold: Double, fresh: Boolean = false) =
        LetterboxdPlaybackTracker(
            sessionId = newId(), profileId = profileId, tmdbId = showTmdbId, title = showName,
            initialCoverage = if (fresh) WatchedCoverage() else engine.coverageNow(profileId, episodeKey), threshold = threshold,
            minRuntimeMs = EPISODE_MIN_RUNTIME_MS,
        )

    /** The player left this episode (stopped, closed, or switched): progress is kept, and nothing counts as finished. */
    fun playbackStopped(profileId: Int, showTmdbId: Int, seasonNumber: Int, episodeNumber: Int) {
        val episodeKey = "$showTmdbId|$seasonNumber|$episodeNumber"
        val w = synchronized(mapLock) { trackers.remove("$profileId|$episodeKey") } ?: return
        w.tracker.onInterrupted()
        val coverage = w.tracker.coverage
        if (!w.tracker.completed) scope.launch { engine.saveCoverage(profileId, episodeKey, coverage) }
    }

    // ------------------------------------------------------------------ import

    /**
     * Reads the member's Serializd diary and watched seasons and adds what is missing to BannerTV's watched history. It writes nothing to
     * Serializd and is safe to run again: every diary entry has a stable id and everything read is remembered as already on Serializd,
     * so it is never sent back. Episodes with a diary entry keep their real dates; a season marked watched with no dates becomes watched
     * with an unknown date, never an invented one. An existing BannerTV rating is never cleared by an entry without one. A read that
     * fails part way keeps what was read (this only adds), and running it again continues.
     */
    suspend fun importHistory(profileId: Int, includeWatchedSeasons: Boolean = settingsOf(profileId).importWatchedHistory): SerializdImportResult {
        if (!importLock.tryLock()) return SerializdImportResult(0, 0, 0, 0, true, "An import is already running")
        try {
            val account = accountOf(profileId) ?: return SerializdImportResult(0, 0, 0, 0, false, "No Serializd account is connected")
            val service = serviceFor(profileId) ?: return SerializdImportResult(0, 0, 0, 0, true, "Reconnect Serializd first")
            var pages = 0; var partial = false; var message: String? = null
            val diary = ArrayList<SerializdDiaryEntry>()
            val watched = ArrayList<SerializdWatchedEntry>()
            var diaryRows = 0
            var diaryDeclared: Int? = null
            try {
                val username = service.session.ensureUsername()
                pages += readAll("Reading diary page", MAX_IMPORT_PAGES, { p -> service.api.diaryPage(username, p).also { diaryRows += it.rawCount; diaryDeclared = it.totalEntries ?: diaryDeclared }.let { Triple(it.entries, it.totalPages, it.rawCount) } }, { it.id?.toString() ?: "${it.showTmdbId}|${it.seasonId}|${it.episodeNumber}|${it.backdateMs}" }) { diary += it }
                // Serializd says how many entries the diary holds: a read that comes up short of that is not the whole diary.
                diaryDeclared?.let { total -> if (diaryRows < total) { partial = true; message = "Serializd lists $total diary entries but only $diaryRows were read" } }
                if (includeWatchedSeasons) {
                    pages += readAll("Reading watched shows page", MAX_IMPORT_PAGES, { p -> service.api.watchedPage(username, p).let { Triple(it.entries, it.totalPages, it.rawCount) } }, { it.showTmdbId.toString() }) { watched += it }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: SerializdException) {
                partial = true; message = "Stopped early: ${e.message?.takeIf { it.isNotBlank() } ?: e.category.name}"
                if (e is SerializdException.SessionExpired || e is SerializdException.ReconnectRequired) setState(profileId, SerializdConnectionState.SessionExpired)
            }
            val outcome = try {
                interpret(profileId, account, service, diary, watched)
            } finally { _status.value = null }
            val applied = try {
                if (outcome.episodes.isNotEmpty()) importSink.apply(profileId, outcome.episodes)
                true
            } catch (e: CancellationException) { throw e } catch (e: Throwable) {
                partial = true; message = "Could not add the imported episodes to your watched list"; false
            }
            // Only what really reached the watched list is remembered as imported, so a failed apply is read again next time.
            if (applied) engine.addImported(profileId, account, outcome.watches, outcome.markers, outcome.slotIds, outcome.ratings)
            if (outcome.remote.isNotEmpty()) { remote.value = remote.value + (account.lowercase() to mergeRemote(remote.value[account.lowercase()].orEmpty(), outcome.remote)); saveRemote() }
            val summary = "${outcome.episodes.size} episodes added to your watched list, ${outcome.alreadyKnown} already known, ${outcome.unmatched} not matched " +
                "(${diary.size} diary entries, ${watched.size} watched shows read)" +
                (if (outcome.placedByCount.isNotEmpty()) ". Placed by season count (Serializd has re-created these seasons' ids): ${outcome.placedByCount.take(5).joinToString(", ")}" + (if (outcome.placedByCount.size > 5) " and ${outcome.placedByCount.size - 5} more" else "") else "") +
                (if (outcome.notMatched.isNotEmpty()) ". Not matched: ${outcome.notMatched.take(5).joinToString(", ")}" + (if (outcome.notMatched.size > 5) " and ${outcome.notMatched.size - 5} more" else "") else "") +
                if (partial) " (run again to continue)" else ""
            accounts.value[profileId]?.let { accounts.value = accounts.value + (profileId to it.copy(lastImportAtMs = now(), lastImportSummary = summary, lastImportStats = SerializdImportStats(now(), if (applied) outcome.episodes.size else 0, outcome.alreadyKnown, outcome.unmatched, diary.size, watched.size, outcome.notMatched, outcome.placedByCount, partial))); saveMap(ACCOUNTS_KEY, accounts.value, SerializdAccount.serializer()) }
            engine.recordEvent(profileId, account, "History import", SerializdOperationType.ImportHistory,
                if (partial) SerializdOperationStatus.RetryScheduled else SerializdOperationStatus.Synced, summary)
            return SerializdImportResult(if (applied) outcome.episodes.size else 0, outcome.alreadyKnown, outcome.unmatched, pages, partial, message, outcome.notMatched, outcome.placedByCount)
        } finally {
            importLock.unlock()
        }
    }

    private class Interpreted(
        val episodes: List<SerializdImportedEpisode>,
        val watches: List<SerializdWatch>,
        val markers: List<SerializdTarget>,
        val slotIds: Map<String, Int>,
        val ratings: Map<String, Int>,
        val remote: List<SerializdRemoteEntry>,
        val alreadyKnown: Int,
        val unmatched: Int,
        val notMatched: List<String>,
        val placedByCount: List<String>,
    )

    /** Turns what was read into episodes for the watched list, local records and remembered ids. Pure apart from reading season data. */
    private suspend fun interpret(profileId: Int, account: String, service: SerializdService, diary: List<SerializdDiaryEntry>, watched: List<SerializdWatchedEntry>): Interpreted {
        val acct = account.lowercase()
        val watches = ArrayList<SerializdWatch>()
        val slotIds = HashMap<String, Int>()
        val ratings = HashMap<String, Int>()
        val remoteEntries = ArrayList<SerializdRemoteEntry>()
        val byEpisode = LinkedHashMap<SerializdTarget, SerializdImportedEpisode>()
        var unmatched = 0; var already = 0
        val notMatched = ArrayList<String>()
        val placedByCount = ArrayList<String>()
        val newestRating = HashMap<String, Long>()
        // Entries BannerTV sent itself are already viewings here: reading them back would make a second copy of the same viewing.
        val own = engine.watches.value.filter { it.profileId == profileId && it.account.equals(account, true) && it.source != SerializdWatch.SOURCE_IMPORT }
        val ownIds = own.mapNotNull { it.remoteReviewId }.toHashSet()
        for (e in diary) {
            val atMs = e.backdateMs ?: e.dateAddedMs
            val target = SerializdTarget(e.showTmdbId, e.seasonNumber, e.episodeNumber)
            if (e.episodeNumber != null && e.seasonNumber == null) { unmatched++; continue } // an episode whose season cannot be told: not guessed at
            // The most recent rating of each target is the one the member holds now.
            e.rating?.let { r ->
                val k = engine.pushedKeyFor(account, target)
                if ((atMs ?: 0L) >= (newestRating[k] ?: Long.MIN_VALUE)) { newestRating[k] = atMs ?: 0L; ratings[k] = r }
            }
            if (e.episodeNumber == null || e.seasonNumber == null) {
                // A review or rating of a whole show or season: kept for display and as the entry an edit goes to. Never an episode.
                e.id?.let { slotIds[engine.slotKeyFor(account, e.isLog, target)] = it }
                remoteEntries += SerializdRemoteEntry(e.id, e.showTmdbId, e.seasonNumber, null, SerializdRating.fromSerializd(e.rating), e.reviewText, e.containsSpoiler, e.isLog, atMs ?: 0L)
                continue
            }
            if (!e.isLog) {
                // A rating with no viewing: it is a rating, not a watch.
                e.id?.let { slotIds[engine.slotKeyFor(account, false, target)] = it }
                continue
            }
            if ((e.id != null && e.id in ownIds) || (atMs != null && own.any { it.target == target && abs(it.completedAtMs - atMs) <= OWN_ENTRY_MATCH_MS })) { already++; continue }
            val id = "imp-$acct-" + (e.id?.toString() ?: "${e.showTmdbId}-${e.seasonNumber}-${e.episodeNumber}-${e.backdateMs ?: 0}")
            val undated = atMs == null
            watches += SerializdWatch(
                id = id, profileId = profileId, account = account, showTmdbId = e.showTmdbId, showName = e.showName.orEmpty(), seasonNumber = e.seasonNumber,
                episodeNumber = e.episodeNumber, completedAtMs = atMs ?: UNDATED_MS, rewatch = e.isRewatch, stars = SerializdRating.fromSerializd(e.rating),
                liked = e.like, reviewDraft = e.reviewText, reviewSpoilers = e.containsSpoiler, reviewPublished = e.reviewText != null,
                source = SerializdWatch.SOURCE_IMPORT, markedWatched = true, onDiary = true, remoteReviewId = e.id, undated = undated,
            )
            if (engine.isMarkerKnown(account, target)) { already++; continue }
            val previous = byEpisode[target]
            if (previous == null || (atMs ?: 0L) > (previous.watchedAtMs ?: 0L)) {
                byEpisode[target] = SerializdImportedEpisode(e.showTmdbId, e.showName, e.seasonNumber, e.episodeNumber, atMs, SerializdRating.fromSerializd(e.rating), e.isRewatch)
            }
        }
        // Seasons marked watched as a whole: every episode of them, with no date, and never over an episode the diary already dated.
        val today = SerializdDates.utcDate(now())
        var shown = 0
        for (w in watched) {
            shown++
            _status.value = "Reading seasons $shown of ${watched.size}"
            val show = try { service.seasons.show(w.showTmdbId) } catch (e: CancellationException) { throw e } catch (e: SerializdException) { null }
            if (show == null) { unmatched++; continue }
            val placed = service.seasons.watchedSeasons(w.showTmdbId, w.seasonIds)
            val numbers = placed.numbers
            val label = w.name ?: show.name ?: "Show ${w.showTmdbId}"
            // A watched season whose id Serializd no longer lists (it re-created the show's seasons) is placed only when the count leaves
            // no choice. Otherwise it is not guessed at; either way it is said.
            if (placed.placedByCount > 0) placedByCount += "$label (${placed.placedByCount} ${if (placed.placedByCount == 1) "season" else "seasons"})"
            if (placed.lost > 0) { unmatched += placed.lost; notMatched += "$label (${placed.lost} ${if (placed.lost == 1) "season" else "seasons"})" }
            val lastSeason = show.seasons.maxOfOrNull { it.number }
            for (season in numbers) {
                if (season <= 0) continue // specials are not a season of the story; Serializd's count for them is not a real episode count
                val info = show.seasons.firstOrNull { it.number == season } ?: continue
                var episodeNumbers: List<Int>? = null
                if (show.inProduction && season == lastSeason) {
                    // A season still airing: only what has aired counts as watched.
                    episodeNumbers = try { service.api.seasonEpisodes(w.showTmdbId, season).filter { it.airDate != null && it.airDate <= today }.map { it.number } }
                        catch (e: CancellationException) { throw e } catch (e: SerializdException) { null }
                }
                val list = episodeNumbers ?: (1..(info.episodeCount ?: 0)).toList()
                for (n in list) {
                    val t = SerializdTarget(w.showTmdbId, season, n)
                    if (engine.isMarkerKnown(account, t)) { already++; continue }
                    byEpisode.getOrPut(t) { SerializdImportedEpisode(w.showTmdbId, w.name ?: show.name, season, n, null) }
                }
            }
        }
        return Interpreted(byEpisode.values.toList(), watches, byEpisode.keys.toList(), slotIds, ratings, remoteEntries, already, unmatched, notMatched, placedByCount)
    }

    /**
     * Reads a paged list to its end: until the declared page count, or an empty page. A page that only repeats earlier ones (an API that
     * loops) or a failed page stops the read with an exception, so a short read is never taken for the whole list.
     */
    private suspend fun <T> readAll(label: String, maxPages: Int, fetch: suspend (Int) -> Triple<List<T>, Int?, Int>, identity: (T) -> String, sink: (List<T>) -> Unit): Int {
        val seen = HashSet<String>()
        var page = 1
        while (page <= maxPages) {
            _status.value = "$label $page"
            val (items, total, raw) = fetch(page)
            if (raw == 0) break
            val before = seen.size
            items.forEach { seen += identity(it) }
            if (page > 1 && seen.size == before && items.isNotEmpty()) throw SerializdException.Unexpected("Serializd served page $page again instead of new entries")
            sink(items)
            if (total != null && page >= total) return page
            if (total == null && raw == 0) return page
            page++
        }
        if (page > maxPages) throw SerializdException.Unexpected("More than $maxPages pages; run the import again to continue")
        return page - 1
    }

    private fun mergeRemote(old: List<SerializdRemoteEntry>, fresh: List<SerializdRemoteEntry>): List<SerializdRemoteEntry> {
        val keyOf = { e: SerializdRemoteEntry -> e.id?.toString() ?: "${e.showTmdbId}|${e.seasonNumber}|${e.isLog}|${e.atMs}" }
        val merged = LinkedHashMap<String, SerializdRemoteEntry>()
        old.forEach { merged[keyOf(it)] = it }
        fresh.forEach { merged[keyOf(it)] = it }
        return merged.values.toList().takeLast(MAX_REMOTE)
    }

    private fun saveRemote() = kv.write(REMOTE_KEY, json.encodeToString(MapSerializer(String.serializer(), ListSerializer(SerializdRemoteEntry.serializer())), remote.value))

    // ------------------------------------------------------------------ watchlist

    /**
     * Reads the member's whole Serializd watchlist and keeps it. The saved snapshot is only ever replaced by another complete read: a page
     * that fails, a short read or an answer that does not look like a watchlist leaves the last good one untouched. Returns the number of
     * shows, or null when the read was not complete.
     */
    suspend fun refreshWatchlist(profileId: Int): Int? = watchlistLock.withLock {
        val account = accountOf(profileId) ?: return@withLock null
        val service = serviceFor(profileId) ?: return@withLock null
        try {
            val username = service.session.ensureUsername()
            val entries = ArrayList<SerializdWatchlistEntry>()
            val seenShows = HashSet<Int>()
            var declaredShows: Int? = null
            var page = 1
            while (true) {
                if (page > MAX_IMPORT_PAGES) throw SerializdException.Unexpected("More than $MAX_IMPORT_PAGES watchlist pages")
                _status.value = "Reading watchlist page $page"
                val result = service.api.watchlistPage(username, page)
                if (result.rawCount == 0) {
                    // An empty first page is an empty watchlist; an empty later page before the declared end is a short read.
                    if (page == 1 || result.totalPages == null || page > result.totalPages) break
                    throw SerializdException.Unexpected("An empty watchlist page $page before the end")
                }
                declaredShows = result.totalShows ?: declaredShows
                val before = seenShows.size
                result.entries.forEach { if (seenShows.add(it.showTmdbId)) entries += it }
                if (page > 1 && seenShows.size == before) throw SerializdException.Unexpected("Watchlist page $page repeated earlier shows")
                if (result.totalPages == null || page >= result.totalPages) break
                page++
            }
            // Serializd says how many shows the watchlist holds. A read that does not add up to that is a short read, not a smaller list.
            declaredShows?.let { total -> if (entries.size != total) throw SerializdException.Unexpected("Serializd lists $total shows but ${entries.size} were read") }
            // Season numbers are resolved last; a show that cannot be resolved keeps its entry with no seasons rather than failing the read.
            var done = 0
            val resolved = entries.map { e ->
                _status.value = "Matching seasons ${++done} of ${entries.size}"
                val numbers = try { service.seasons.seasonNumbers(e.showTmdbId, e.seasonIds) } catch (c: CancellationException) { throw c } catch (x: SerializdException) { emptyList() }
                e.copy(seasonNumbers = numbers)
            }
            watchlists.value = watchlists.value + (profileId to SerializdWatchlistSnapshot(resolved, now())); saveMap(WATCHLIST_KEY, watchlists.value, SerializdWatchlistSnapshot.serializer())
            accounts.value[profileId]?.let { accounts.value = accounts.value + (profileId to it.copy(lastWatchlistAtMs = now())); saveMap(ACCOUNTS_KEY, accounts.value, SerializdAccount.serializer()) }
            if (settingsOf(profileId).watchlistToLibrary) addToMyList(profileId, resolved)
            resolved.size
        } catch (e: CancellationException) {
            throw e
        } catch (e: SerializdException) {
            if (e is SerializdException.SessionExpired || e is SerializdException.ReconnectRequired) setState(profileId, SerializdConnectionState.SessionExpired)
            engine.recordEvent(profileId, account, "Watchlist", SerializdOperationType.ImportHistory, SerializdOperationStatus.RetryScheduled, "The watchlist could not be read completely; the last one was kept")
            null
        } finally {
            _status.value = null
        }
    }

    /**
     * Puts the saved watchlist in BannerTV's My List without reading Serializd again (what switching the setting on does). A show with only
     * some seasons on the watchlist goes in as the show. Returns the one-line outcome, also kept on the account.
     */
    suspend fun addSavedWatchlistToMyList(profileId: Int): String? {
        val snapshot = watchlists.value[profileId] ?: return null
        return addToMyList(profileId, snapshot.entries)
    }

    private suspend fun addToMyList(profileId: Int, entries: List<SerializdWatchlistEntry>): String {
        val summary = try {
            watchlistSink.apply(profileId, "serializd", entries.map { WatchlistTitle(it.showTmdbId, true, it.name ?: "Show ${it.showTmdbId}", null, it.posterPath) }).summary()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            // A failure here never costs the watchlist copy that was just read.
            "Could not add the watchlist to My List: ${e.message?.take(100) ?: "unexpected error"}"
        }
        accounts.value[profileId]?.let { accounts.value = accounts.value + (profileId to it.copy(lastWatchlistSummary = summary)); saveMap(ACCOUNTS_KEY, accounts.value, SerializdAccount.serializer()) }
        accountOf(profileId)?.let { engine.recordEvent(profileId, it, "Watchlist to My List", SerializdOperationType.ImportHistory, SerializdOperationStatus.Synced, summary) }
        return summary
    }

    private companion object {
        const val ACCOUNTS_KEY = "serializd_accounts_v1"
        const val SETTINGS_KEY = "serializd_settings_v1"
        const val STATES_KEY = "serializd_states_v1"
        const val WATCHLIST_KEY = "serializd_watchlist_v1"
        const val REMOTE_KEY = "serializd_remote_v1"
        const val COVERAGE_SAVE_EVERY = 20
        const val MAX_IMPORT_PAGES = 500
        const val REFRESH_AFTER_MS = 12 * 3_600_000L
        const val MAX_REMOTE = 1500
        /** A diary entry within this long of a viewing made here, for the same episode, is that viewing. */
        const val OWN_ENTRY_MATCH_MS = 2 * 60_000L
        /** An episode is shorter than a film: anything under three minutes is not worth tracking. */
        const val EPISODE_MIN_RUNTIME_MS = 3 * 60_000L
        /** 2000-01-01 12:00 UTC: the placeholder for a watch with no date, the same one the Letterboxd import uses. Never sent anywhere. */
        const val UNDATED_MS = 946_728_000_000L
    }
}
