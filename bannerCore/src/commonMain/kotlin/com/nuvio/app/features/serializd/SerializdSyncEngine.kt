package com.nuvio.app.features.serializd

import com.nuvio.app.features.letterboxd.WatchedCoverage
import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.SetSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlin.math.abs

/** What the sync engine needs from the app around it. */
interface SerializdEngineHost {
    /** The connected Serializd username for [profileId], or null when none is connected. */
    fun accountOf(profileId: Int): String?
    fun settingsOf(profileId: Int): SerializdSettings
    /** A service on the profile's session, or null when it must reconnect first. */
    fun serviceOf(profileId: Int): SerializdService?
    fun onConnectionState(profileId: Int, state: SerializdConnectionState)
    /**
     * How many episodes each season of the show has, as the app knows it. Only asked when Serializd keeps the show as one long season
     * and the later seasons' episodes have to be placed after the earlier ones; empty when unknown.
     */
    suspend fun seasonLengths(showTmdbId: Int): Map<Int, Int> = emptyMap()
}

/** A finished episode (or a file holding several): what the playback tracker reports. */
data class SerializdCompletion(
    val sessionId: String,
    val profileId: Int,
    val showTmdbId: Int,
    val seasonNumber: Int,
    /** One number for an ordinary episode, several for a multi-episode file. */
    val episodeNumbers: List<Int>,
    val showName: String,
    val episodeTitle: String?,
    val completedAtMs: Long,
    val watchedFraction: Double,
)

/** One episode of the member's BannerTV history, offered for the optional backfill to Serializd. */
data class SerializdBackfillEpisode(val showTmdbId: Int, val showName: String, val seasonNumber: Int, val episodeNumber: Int, val watchedAtMs: Long?)

/** What happened when a review was asked to go out. */
sealed interface SerializdReviewOutcome {
    /** Queued: as a new entry, an edit of the entry that exists, or folded into the entry still waiting to be sent. */
    data object Queued : SerializdReviewOutcome
    /** Serializd has this entry, its id is not known, and it could not be found: the text is kept and the entry can be opened to edit. */
    data class DraftKeptOpenSerializd(val url: String) : SerializdReviewOutcome
    data object NotConnected : SerializdReviewOutcome
}

@Serializable
private data class StoredCoverage(val key: String, val coverage: WatchedCoverage)

/** After a few login-type failures in a row the account stops being tried until the member reconnects. */
class SerializdAuthBreaker {
    var consecutiveFailures: Int = 0; private set
    val isOpen: Boolean get() = consecutiveFailures >= THRESHOLD
    fun recordFailure(): Boolean { consecutiveFailures++; return consecutiveFailures == THRESHOLD }
    fun recordSuccess() { consecutiveFailures = 0 }
    fun reset() { consecutiveFailures = 0 }
    companion object { const val THRESHOLD = 3 }
}

/**
 * The persistent queue behind every Serializd write, plus the local record of viewings. Ported from the ideas of Jellyscribe's
 * PlaybackHandler, SerializdSyncRunner, EpisodeFinishGuard and SerializdSyncHistory:
 *  - one operation per remote phase (watched marker, dated diary entry, rating, review): when one fails only that one is retried,
 *    and one that succeeded is never sent again because a later one failed;
 *  - a finish callback repeated for the same playback session is the same viewing, and a finish within [FINISH_WINDOW_MS] of one
 *    already recorded is dropped, so a repeated callback is never sent as a rewatch; a later finish is a genuine rewatch;
 *  - every viewing and every operation is saved before anything is sent, so a closed app loses nothing;
 *  - a dated entry that was sent and not confirmed is looked for on the diary before it is ever sent again;
 *  - an entry that is already on Serializd is edited, never added a second time;
 *  - login-type failures stop the account instead of retrying (see [SerializdAuthBreaker]).
 * Nothing here runs on the player's thread and nothing blocks playback.
 */
class SerializdSyncEngine(
    private val store: SerializdKeyValue,
    private val host: SerializdEngineHost,
    private val now: () -> Long = { kotlin.time.Clock.System.now().toEpochMilliseconds() },
    private val newId: () -> String,
) {
    // Defaults are left out of the saved copy: the lists are written whole on every change and kept in the app's small preferences store.
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = false }
    private val stateLock = Mutex()
    private val processLock = Mutex()
    private val breakers = HashMap<Int, SerializdAuthBreaker>()
    private val breakerLock = SynchronizedObject()

    private val _operations = MutableStateFlow(loadList(OPS_KEY, SerializdOperation.serializer()))
    private val _watches = MutableStateFlow(loadList(WATCHES_KEY, SerializdWatch.serializer()))
    private val _events = MutableStateFlow(loadList(EVENTS_KEY, SerializdSyncEvent.serializer()))
    val operations: StateFlow<List<SerializdOperation>> = _operations.asStateFlow()
    val watches: StateFlow<List<SerializdWatch>> = _watches.asStateFlow()
    val events: StateFlow<List<SerializdSyncEvent>> = _events.asStateFlow()

    private fun <T> loadList(key: String, s: kotlinx.serialization.KSerializer<T>): List<T> =
        store.read(key)?.let { runCatching { json.decodeFromString(ListSerializer(s), it) }.getOrNull() }.orEmpty()

    private fun saveOps() = store.write(OPS_KEY, json.encodeToString(ListSerializer(SerializdOperation.serializer()), _operations.value))
    private fun saveWatches() = store.write(WATCHES_KEY, json.encodeToString(ListSerializer(SerializdWatch.serializer()), _watches.value))
    private fun saveEvents() = store.write(EVENTS_KEY, json.encodeToString(ListSerializer(SerializdSyncEvent.serializer()), _events.value))

    // ------------------------------------------------------------------ small persisted sets and maps

    /** Kept in memory once read: an import adds thousands, and every completion asks. */
    private var syncedCache: MutableSet<String>? = null

    private fun readSynced(): MutableSet<String> = syncedCache ?: (
        store.read(SYNCED_KEY)?.let { runCatching { json.decodeFromString(SetSerializer(String.serializer()), it) }.getOrNull() }.orEmpty().toMutableSet()
        ).also { syncedCache = it }

    private fun writeSynced(set: Set<String>) {
        syncedCache = set.toMutableSet()
        store.write(SYNCED_KEY, json.encodeToString(SetSerializer(String.serializer()), set))
    }

    private fun readIntMap(key: String): MutableMap<String, Int> =
        store.read(key)?.let { runCatching { json.decodeFromString(MapSerializer(String.serializer(), Int.serializer()), it) }.getOrNull() }.orEmpty().toMutableMap()

    private fun writeIntMap(key: String, map: Map<String, Int>) = store.write(key, json.encodeToString(MapSerializer(String.serializer(), Int.serializer()), map))

    /** Whether an episode is known to be marked watched on this account (by BannerTV, or read from Serializd). */
    fun isMarkerKnown(account: String, target: SerializdTarget): Boolean = readSynced().contains(markerKey(account, target))

    private fun readCoverages(): MutableMap<String, WatchedCoverage> =
        store.read(COVERAGE_KEY)?.let { runCatching { json.decodeFromString(ListSerializer(StoredCoverage.serializer()), it) }.getOrNull() }
            .orEmpty().associate { it.key to it.coverage }.toMutableMap()

    suspend fun saveCoverage(profileId: Int, key: String, coverage: WatchedCoverage) = stateLock.withLock {
        val map = readCoverages()
        map.remove("$profileId|$key")
        if (coverage.ranges.isNotEmpty()) map["$profileId|$key"] = coverage
        val keep = map.entries.toList().takeLast(200)
        store.write(COVERAGE_KEY, json.encodeToString(ListSerializer(StoredCoverage.serializer()), keep.map { StoredCoverage(it.key, it.value) }))
    }

    /** What has been watched so far of an episode, read without waiting (the player samples about once a second). */
    fun coverageNow(profileId: Int, key: String): WatchedCoverage = readCoverages()["$profileId|$key"] ?: WatchedCoverage()

    // ------------------------------------------------------------------ completion

    /**
     * Records a finished episode and queues what goes to Serializd. Safe to call twice for the same session, and for a repeated finish
     * a moment later: the first viewing is returned and nothing more is queued. A viewing of an episode already watched is a rewatch.
     * Returns the viewing of the first episode, or null when there is no account.
     */
    suspend fun onCompletion(c: SerializdCompletion, posterUrl: String?, liked: Boolean): SerializdWatch? = stateLock.withLock {
        val account = host.accountOf(c.profileId) ?: return@withLock null
        val settings = host.settingsOf(c.profileId)
        var first: SerializdWatch? = null
        val newWatches = ArrayList<SerializdWatch>()
        c.episodeNumbers.distinct().sorted().forEachIndexed { index, episode ->
            val id = if (index == 0) "w-${c.sessionId}" else "w-${c.sessionId}-$episode"
            val target = SerializdTarget(c.showTmdbId, c.seasonNumber, episode)
            _watches.value.firstOrNull { it.id == id }?.let { if (first == null) first = it; return@forEachIndexed }
            val sameEpisode = (_watches.value + newWatches).filter { it.profileId == c.profileId && it.account.equals(account, true) && it.target == target }
            // A finish within a few minutes of one already recorded is the player or the app calling twice, not a second viewing.
            val repeat = sameEpisode.filter { it.source != SerializdWatch.SOURCE_IMPORT && abs(c.completedAtMs - it.completedAtMs) <= FINISH_WINDOW_MS }
                .maxByOrNull { it.completedAtMs }
            if (repeat != null) {
                if (first == null) first = repeat
                record(c.profileId, account, c.showTmdbId, c.showName, c.seasonNumber, episode, SerializdOperationType.CreateDiaryEntry, SerializdOperationStatus.Skipped,
                    note = "A repeated finish for this episode a moment ago was ignored", rewatch = false)
                return@forEachIndexed
            }
            val rewatch = sameEpisode.isNotEmpty() || isMarkerKnown(account, target)
            val watch = SerializdWatch(
                id = id, profileId = c.profileId, account = account, showTmdbId = c.showTmdbId, showName = c.showName,
                seasonNumber = c.seasonNumber, episodeNumber = episode, episodeTitle = c.episodeTitle.takeIf { index == 0 }, posterUrl = posterUrl,
                completedAtMs = c.completedAtMs, rewatch = rewatch, liked = liked,
            )
            newWatches += watch
            if (first == null) first = watch
        }
        if (newWatches.isNotEmpty()) {
            _watches.value = trimWatches(_watches.value + newWatches); saveWatches()
        }
        if (newWatches.isEmpty() || !settings.autoTrackEpisodes) return@withLock first
        // The watched marker: one request for the whole file, and none for an episode already known to be marked.
        val toMark = newWatches.filter { !isMarkerKnown(account, it.target) }
        if (toMark.isNotEmpty()) {
            val head = toMark.first()
            enqueue(
                SerializdOperation(
                    id = "op-m-${head.id}", profileId = c.profileId, account = account, type = SerializdOperationType.MarkEpisodeWatched,
                    showTmdbId = head.showTmdbId, seasonNumber = head.seasonNumber, episodeNumber = head.episodeNumber,
                    extraEpisodes = toMark.drop(1).map { it.episodeNumber }, title = head.showName,
                    dedupeKey = "m|${account.lowercase()}|${head.showTmdbId}|${head.seasonNumber}|${toMark.joinToString(",") { it.episodeNumber.toString() }}",
                    watchId = head.id, watchedAtMs = head.completedAtMs, createdAtMs = now(),
                ),
            )
        }
        // The dated diary entry, one per episode, each with its own id so a genuine rewatch makes its own.
        for (w in newWatches) {
            when {
                !settings.createDiaryEntries -> Unit
                w.rewatch && !settings.logRewatches -> record(c.profileId, account, w.showTmdbId, w.showName, w.seasonNumber, w.episodeNumber,
                    SerializdOperationType.CreateDiaryEntry, SerializdOperationStatus.Skipped, note = "Rewatch logging is off", rewatch = true)
                else -> enqueue(
                    SerializdOperation(
                        id = "op-d-${w.id}", profileId = c.profileId, account = account, type = SerializdOperationType.CreateDiaryEntry,
                        showTmdbId = w.showTmdbId, seasonNumber = w.seasonNumber, episodeNumber = w.episodeNumber, title = w.showName,
                        dedupeKey = "d|${account.lowercase()}|${w.id}", watchId = w.id, watchedAtMs = w.completedAtMs, rewatch = w.rewatch,
                        liked = settings.syncFavorites && liked, createdAtMs = now(),
                    ),
                )
            }
        }
        first
    }

    /**
     * The member's own "Log viewing": a viewing on the date they give (never an invented one), sent as a dated entry and a watched
     * marker. [watchedAtMs] is when it was watched. Rewatch is worked out unless [rewatch] says.
     */
    suspend fun logViewingManually(profileId: Int, target: SerializdTarget, title: String, posterUrl: String?, watchedAtMs: Long, stars: Double?, rewatch: Boolean? = null): SerializdWatch? = stateLock.withLock {
        val account = host.accountOf(profileId) ?: return@withLock null
        val season = target.seasonNumber ?: return@withLock null
        val episode = target.episodeNumber ?: return@withLock null
        val settings = host.settingsOf(profileId)
        val prior = _watches.value.any { it.profileId == profileId && it.account.equals(account, true) && it.target == target } || isMarkerKnown(account, target)
        val id = "w-manual-${newId()}"
        val snapped = SerializdRating.snap(stars)
        val watch = SerializdWatch(id, profileId, account, target.showTmdbId, title, season, episode, null, posterUrl, watchedAtMs, rewatch ?: prior, snapped, source = SerializdWatch.SOURCE_MANUAL)
        _watches.value = trimWatches(_watches.value + watch); saveWatches()
        if (!isMarkerKnown(account, target)) {
            enqueue(SerializdOperation("op-m-$id", profileId, account, SerializdOperationType.MarkEpisodeWatched, target.showTmdbId, season, episode, title = title,
                dedupeKey = markerKey(account, target), watchId = id, watchedAtMs = watchedAtMs, createdAtMs = now()))
        }
        enqueue(SerializdOperation("op-d-$id", profileId, account, SerializdOperationType.CreateDiaryEntry, target.showTmdbId, season, episode, title = title,
            dedupeKey = "d|${account.lowercase()}|$id", watchId = id, watchedAtMs = watchedAtMs, rewatch = rewatch ?: prior,
            stars = if (settings.syncRatings) snapped else null, createdAtMs = now()))
        watch
    }

    // ------------------------------------------------------------------ ratings

    /**
     * Saves a rating at once and queues it. Rapid changes keep only the last (held [RATING_DEBOUNCE_MS] before sending), and a rating on
     * a viewing whose diary entry has not gone out yet rides on that entry. Where the entry is already on Serializd it is edited:
     * a rating never makes a second diary entry.
     */
    suspend fun setRating(profileId: Int, target: SerializdTarget, title: String, stars: Double?, watchId: String? = null, liked: Boolean = false) {
        stateLock.withLock {
            val snapped = SerializdRating.snap(stars)
            val account = host.accountOf(profileId)
            val watch = watchFor(profileId, account, target, watchId)
            if (watch != null) { _watches.value = _watches.value.map { if (it.id == watch.id) it.copy(stars = snapped) else it }; saveWatches() }
            // Taking a rating back off is not something this session can do on Serializd, so an unrated choice stays here.
            if (account == null || !host.settingsOf(profileId).syncRatings || snapped == null) return@withLock
            val pendingDiary = watch?.let { w -> _operations.value.firstOrNull { it.watchId == w.id && it.type == SerializdOperationType.CreateDiaryEntry && it.status in OPEN_BEFORE_SEND } }
            if (pendingDiary != null) { replace(pendingDiary.copy(stars = snapped)); return@withLock }
            val existing = _operations.value.firstOrNull {
                it.profileId == profileId && it.account == account && it.type == SerializdOperationType.SubmitRating && it.target == target && it.status in OPEN_BEFORE_SEND
            }
            val base = existing ?: SerializdOperation(
                id = "op-rate-${newId()}", profileId = profileId, account = account, type = SerializdOperationType.SubmitRating,
                showTmdbId = target.showTmdbId, seasonNumber = target.seasonNumber, episodeNumber = target.episodeNumber, title = title,
                dedupeKey = "rate|${account.lowercase()}|${target.key}|${newId()}", watchId = watch?.id, createdAtMs = now(),
            )
            val op = base.copy(stars = snapped, liked = liked, watchedAtMs = now(), notBeforeMs = now() + RATING_DEBOUNCE_MS,
                status = SerializdOperationStatus.Pending, attempts = 0, nextAttemptAtMs = 0, error = SerializdErrorCategory.None, note = null)
            if (existing != null) replace(op) else enqueue(op)
        }
    }

    /**
     * A favourite on a whole show, sent as the like flag together with the rating the member already has (a like sent alone would
     * clear it). Only when the member has turned favourites on. Held for the debounce, so a quick on and off sends only the last.
     */
    suspend fun setShowLike(profileId: Int, showTmdbId: Int, title: String, liked: Boolean) = stateLock.withLock {
        val account = host.accountOf(profileId) ?: return@withLock
        if (!host.settingsOf(profileId).syncFavorites) return@withLock
        val target = SerializdTarget(showTmdbId)
        val current = readIntMap(PUSHED_KEY)[pushedKey(account, target)]
        val existing = _operations.value.firstOrNull { it.profileId == profileId && it.account == account && it.type == SerializdOperationType.SubmitRating && it.target == target && it.status in OPEN_BEFORE_SEND }
        val base = existing ?: SerializdOperation(
            id = "op-like-${newId()}", profileId = profileId, account = account, type = SerializdOperationType.SubmitRating,
            showTmdbId = showTmdbId, title = title, dedupeKey = "like|${account.lowercase()}|$showTmdbId|${newId()}", createdAtMs = now(),
        )
        val op = base.copy(stars = SerializdRating.fromSerializd(current) ?: base.stars, liked = liked, watchedAtMs = now(), notBeforeMs = now() + RATING_DEBOUNCE_MS,
            status = SerializdOperationStatus.Pending, attempts = 0, nextAttemptAtMs = 0, error = SerializdErrorCategory.None, note = null)
        if (existing != null) replace(op) else enqueue(op)
    }

    // ------------------------------------------------------------------ reviews

    suspend fun saveReviewDraft(watchId: String, text: String, spoilers: Boolean) = stateLock.withLock {
        _watches.value = _watches.value.map { if (it.id == watchId) it.copy(reviewDraft = text, reviewSpoilers = spoilers) else it }; saveWatches()
    }

    /**
     * Publishes a review. The text is always kept on the viewing first, so an error never loses it. For an episode with a viewing:
     * it joins the diary entry still waiting to be sent, or edits the entry that exists, or makes the entry when there is none.
     * For a season or a whole show it is a review entry of its own, edited when one is known.
     */
    suspend fun publishReview(profileId: Int, target: SerializdTarget, title: String, text: String, spoilers: Boolean, stars: Double?, watchId: String? = null): SerializdReviewOutcome = stateLock.withLock {
        val account = host.accountOf(profileId) ?: return@withLock SerializdReviewOutcome.NotConnected
        val watch = watchFor(profileId, account, target, watchId)
        val snapped = SerializdRating.snap(stars ?: watch?.stars)
        if (watch != null) {
            _watches.value = _watches.value.map { if (it.id == watch.id) it.copy(reviewDraft = text, reviewSpoilers = spoilers, stars = snapped) else it }; saveWatches()
        }
        if (watch != null) {
            val ops = _operations.value.filter { it.watchId == watch.id && it.type in DIARY_TYPES }
            val pending = ops.firstOrNull { it.type == SerializdOperationType.CreateDiaryEntry && it.status in OPEN_BEFORE_SEND }
            if (pending != null) { replace(pending.copy(reviewText = text, containsSpoilers = spoilers, stars = snapped ?: pending.stars)); return@withLock SerializdReviewOutcome.Queued }
            val inDoubt = ops.any { it.status == SerializdOperationStatus.ReconciliationRequired || it.status == SerializdOperationStatus.InProgress }
            if (inDoubt) { return@withLock SerializdReviewOutcome.DraftKeptOpenSerializd(SerializdApiConstants.showUrl(target.showTmdbId)) }
        }
        enqueue(
            SerializdOperation(
                id = "op-review-${newId()}", profileId = profileId, account = account, type = SerializdOperationType.SubmitReview,
                showTmdbId = target.showTmdbId, seasonNumber = target.seasonNumber, episodeNumber = target.episodeNumber, title = title,
                dedupeKey = "review|${account.lowercase()}|${target.key}|${newId()}", watchId = watch?.id, watchedAtMs = watch?.completedAtMs ?: now(),
                rewatch = watch?.rewatch == true, stars = snapped, reviewText = text, containsSpoilers = spoilers, createdAtMs = now(),
            ),
        )
        SerializdReviewOutcome.Queued
    }

    private fun watchFor(profileId: Int, account: String?, target: SerializdTarget, watchId: String?): SerializdWatch? {
        if (watchId != null) return _watches.value.firstOrNull { it.id == watchId }
        if (account == null || target.scope != SerializdScope.Episode) return null
        return _watches.value.filter { it.profileId == profileId && it.account.equals(account, true) && it.target == target }.maxByOrNull { it.completedAtMs }
    }

    // ------------------------------------------------------------------ watched markers

    /** Takes the watched marker off an episode on Serializd. The dated diary entry stays: it is a separate record. */
    suspend fun unmarkEpisode(profileId: Int, target: SerializdTarget, title: String) = stateLock.withLock {
        val account = host.accountOf(profileId) ?: return@withLock
        val season = target.seasonNumber ?: return@withLock
        val episode = target.episodeNumber ?: return@withLock
        enqueue(SerializdOperation("op-u-${newId()}", profileId, account, SerializdOperationType.RemoveWatchedMarker, target.showTmdbId, season, episode, title = title,
            dedupeKey = "u|${account.lowercase()}|${target.key}|${newId()}", createdAtMs = now()))
    }

    /**
     * The optional historical backfill: sends BannerTV's own watched history to Serializd, only when the member asks. Watched markers
     * go season by season; a dated entry is made only for an episode with a real date. Episodes already known on Serializd (sent
     * before, or read from it) are skipped. At most [maxDiary] dated entries are queued per run; running it again continues.
     * Returns (marker requests queued, dated entries queued, skipped as already known).
     */
    suspend fun enqueueBackfill(profileId: Int, episodes: List<SerializdBackfillEpisode>, withDiary: Boolean, maxDiary: Int = MAX_BACKFILL_DIARY): Triple<Int, Int, Int> = stateLock.withLock {
        val account = host.accountOf(profileId) ?: return@withLock Triple(0, 0, 0)
        val synced = readSynced()
        var markers = 0; var diary = 0; var skipped = 0
        val fresh = episodes.filter { e -> (markerKey(account, SerializdTarget(e.showTmdbId, e.seasonNumber, e.episodeNumber)) !in synced).also { if (!it) skipped++ } }
        fresh.groupBy { it.showTmdbId to it.seasonNumber }.forEach { (key, list) ->
            val eps = list.map { it.episodeNumber }.distinct().sorted()
            val head = list.first()
            if (enqueue(SerializdOperation(
                    id = "op-bm-${newId()}", profileId = profileId, account = account, type = SerializdOperationType.MarkEpisodeWatched,
                    showTmdbId = key.first, seasonNumber = key.second, episodeNumber = eps.first(), extraEpisodes = eps.drop(1), title = head.showName,
                    dedupeKey = "bm|${account.lowercase()}|${key.first}|${key.second}|${eps.joinToString(",")}", createdAtMs = now(),
                ))) markers++
        }
        if (withDiary) {
            // Newest first, and only dates that are real: an undated or epoch-adjacent time is not a watch date.
            for (e in fresh.filter { (it.watchedAtMs ?: 0L) >= PLAUSIBLE_WATCH_DATE_MS }.sortedByDescending { it.watchedAtMs }) {
                if (diary >= maxDiary) break
                val t = SerializdTarget(e.showTmdbId, e.seasonNumber, e.episodeNumber)
                if (enqueue(SerializdOperation(
                        id = "op-bd-${newId()}", profileId = profileId, account = account, type = SerializdOperationType.CreateDiaryEntry,
                        showTmdbId = e.showTmdbId, seasonNumber = e.seasonNumber, episodeNumber = e.episodeNumber, title = e.showName,
                        dedupeKey = "bd|${account.lowercase()}|${t.key}", watchedAtMs = e.watchedAtMs ?: 0L, createdAtMs = now(),
                    ))) diary++
            }
        }
        record(profileId, account, 0, "Backfill", null, null, SerializdOperationType.ImportHistory, if (markers + diary > 0) SerializdOperationStatus.Pending else SerializdOperationStatus.Skipped,
            note = "$markers watched requests and $diary dated entries queued, $skipped episodes already on Serializd")
        Triple(markers, diary, skipped)
    }

    // ------------------------------------------------------------------ queue plumbing

    private fun markerKey(account: String, t: SerializdTarget) = "m|${account.lowercase()}|${t.showTmdbId}|${t.seasonNumber}|${t.episodeNumber}"
    private fun pushedKey(account: String, t: SerializdTarget) = "${account.lowercase()}|${t.key}"
    private fun slotKey(account: String, kind: String, t: SerializdTarget) = "${account.lowercase()}|$kind|${t.key}"

    private fun enqueue(op: SerializdOperation): Boolean {
        if (_operations.value.any { it.id == op.id || (it.dedupeKey == op.dedupeKey && it.status != SerializdOperationStatus.FailedPermanent) }) return false
        _operations.value = trim(_operations.value + op); saveOps()
        record(op, op.status)
        return true
    }

    private fun replace(op: SerializdOperation) {
        _operations.value = _operations.value.map { if (it.id == op.id) op else it }; saveOps()
    }

    private fun trim(ops: List<SerializdOperation>): List<SerializdOperation> {
        val finished = ops.filter { it.status in FINISHED }
        if (finished.size <= KEEP_FINISHED_OPS) return ops
        val drop = finished.take(finished.size - KEEP_FINISHED_OPS).map { it.id }.toSet()
        return ops.filterNot { it.id in drop }
    }

    private fun trimWatches(list: List<SerializdWatch>): List<SerializdWatch> {
        if (list.size <= MAX_WATCHES) return list
        // Imports are the cheapest to read again; viewings made here are kept longest.
        val drop = list.filter { it.source == SerializdWatch.SOURCE_IMPORT }.sortedBy { it.completedAtMs }.take(list.size - MAX_WATCHES).map { it.id }.toSet()
        return list.filterNot { it.id in drop }.takeLast(MAX_WATCHES)
    }

    private fun record(op: SerializdOperation, status: SerializdOperationStatus, error: SerializdErrorCategory = SerializdErrorCategory.None, note: String? = null) {
        if (status == SerializdOperationStatus.Pending) return
        record(op.profileId, op.account, op.showTmdbId, op.title, op.seasonNumber, op.episodeNumber, op.type, status, error, note, op.rewatch)
    }

    private fun record(profileId: Int, account: String, showTmdbId: Int, title: String, season: Int?, episode: Int?, type: SerializdOperationType,
                       status: SerializdOperationStatus, error: SerializdErrorCategory = SerializdErrorCategory.None, note: String? = null, rewatch: Boolean = false) {
        val e = SerializdSyncEvent(newId(), now(), profileId, account, showTmdbId, title, season, episode, type, status, error, note, rewatch)
        _events.value = (_events.value + e).takeLast(MAX_EVENTS); saveEvents()
    }

    /** Records a sync event of the member's own (an import, a check, a backfill) in the history. */
    fun recordEvent(profileId: Int, account: String, title: String, type: SerializdOperationType, status: SerializdOperationStatus, note: String?) =
        record(profileId, account, 0, title, null, null, type, status, SerializdErrorCategory.None, note)

    // ------------------------------------------------------------------ processing

    /** Sends what is due, one operation at a time. Called when the app opens, when the network returns and after each completion. */
    suspend fun processPending() {
        if (!processLock.tryLock()) return
        try {
            var consecutiveServiceFailures = 0
            while (true) {
                val op = stateLock.withLock {
                    val t = now()
                    val due = _operations.value
                        .filter { it.isRunnable(t) && host.accountOf(it.profileId)?.equals(it.account, true) == true && !breaker(it.profileId).isOpen }
                        .minByOrNull { it.createdAtMs } ?: return@withLock null
                    val started = due.copy(status = SerializdOperationStatus.InProgress, lastAttemptAtMs = t, attempts = due.attempts + 1)
                    replace(started); started
                } ?: break
                runOne(op)
                // A service that keeps failing is left alone for now: the rest waits for the next run instead of being hammered.
                val after = _operations.value.firstOrNull { it.id == op.id }
                if (after != null && after.status == SerializdOperationStatus.RetryScheduled && after.error in SERVICE_FAILURES) {
                    if (++consecutiveServiceFailures >= PAUSE_AFTER_FAILURES) break
                } else consecutiveServiceFailures = 0
            }
        } finally {
            processLock.unlock()
        }
    }

    private fun SerializdOperation.isRunnable(t: Long): Boolean = when (status) {
        SerializdOperationStatus.Pending -> notBeforeMs <= t
        SerializdOperationStatus.RetryScheduled, SerializdOperationStatus.ReconciliationRequired -> nextAttemptAtMs <= t
        // An operation left in progress by a closed app is picked up again, and checked first when it had sent its write.
        SerializdOperationStatus.InProgress -> lastAttemptAtMs + STUCK_AFTER_MS <= t
        else -> false
    }

    private fun breaker(profileId: Int) = synchronized(breakerLock) { breakers.getOrPut(profileId) { SerializdAuthBreaker() } }

    /** How long to wait before retry number [attempts]: 30 s, 1 min, 2 min... up to 30 min. */
    internal fun backoffMs(attempts: Int): Long = minOf(30_000L shl (attempts - 1).coerceIn(0, 10), MAX_BACKOFF_MS)

    /** Metadata that is not on Serializd yet (a new season) is tried again slowly: 10 min, 30 min, 90 min, 4 h. */
    internal fun metadataBackoffMs(attempts: Int): Long = minOf(10 * 60_000L * pow3((attempts - 1).coerceIn(0, 5)), 4 * 3_600_000L)

    private fun pow3(n: Int): Long { var r = 1L; repeat(n) { r *= 3 }; return r }

    private suspend fun runOne(op: SerializdOperation) {
        val service = host.serviceOf(op.profileId)
        if (service == null) {
            host.onConnectionState(op.profileId, SerializdConnectionState.ReconnectionRequired)
            finish(op, SerializdOperationStatus.NeedsReconnect, SerializdErrorCategory.ReconnectionRequired); return
        }
        var writeStarted = false
        try {
            when (op.type) {
                SerializdOperationType.MarkEpisodeWatched -> runMarker(op, service)
                SerializdOperationType.RemoveWatchedMarker -> runUnmark(op, service)
                SerializdOperationType.CreateDiaryEntry -> runDiary(op, service) { writeStarted = true }
                SerializdOperationType.SubmitRating, SerializdOperationType.SubmitReview -> runReview(op, service) { writeStarted = true }
                else -> finish(op, SerializdOperationStatus.Skipped, note = "Not a queued operation")
            }
            breaker(op.profileId).recordSuccess()
            host.onConnectionState(op.profileId, SerializdConnectionState.Connected)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: SerializdException) {
            handleFailure(op, e, writeStarted)
        } catch (e: Throwable) {
            handleFailure(op, SerializdException.Unexpected("Unexpected error"), writeStarted)
        }
    }

    /** Where the episodes land on Serializd: its season id, and each episode's number there. Throws when that is not certain. */
    private data class Placed(val seasonId: Int?, val episodes: List<Int>)

    private suspend fun place(service: SerializdService, t: SerializdTarget, episodes: List<Int>): Placed {
        val season = t.seasonNumber ?: return Placed(null, emptyList())
        if (service.seasons.show(t.showTmdbId) == null) throw SerializdException.NotFound("Serializd does not have this show")
        suspend fun resolve() = service.seasons.target(t.showTmdbId, season) { host.seasonLengths(t.showTmdbId) }
        var target = resolve() ?: throw SerializdException.NotFound("Serializd has no season $season for this show")
        if (episodes.isEmpty()) return Placed(target.seasonId, emptyList())
        var mapped = episodes.map { target.episodeFor(it) }
        if (mapped.any { it == null }) {
            // Serializd's episode count can lag a season that is still airing: look once more before deciding the numbering differs.
            service.seasons.show(t.showTmdbId, forceRefresh = true)
            target = resolve() ?: throw SerializdException.NotFound("Serializd has no season $season for this show")
            mapped = episodes.map { target.episodeFor(it) }
            if (mapped.any { it == null }) throw SerializdException.MetadataMismatch("Serializd's numbering of this show does not match, so the episode was not logged")
        }
        return Placed(target.seasonId, mapped.filterNotNull())
    }

    private suspend fun runMarker(op: SerializdOperation, service: SerializdService) {
        val placed = place(service, op.target, op.episodes)
        service.api.logEpisodes(op.showTmdbId, placed.seasonId!!, placed.episodes)
        stateLock.withLock {
            val synced = readSynced()
            op.episodes.forEach { synced += markerKey(op.account, SerializdTarget(op.showTmdbId, op.seasonNumber, it)) }
            writeSynced(synced)
            val ids = _watches.value.filter { it.profileId == op.profileId && it.account.equals(op.account, true) && it.showTmdbId == op.showTmdbId && it.seasonNumber == op.seasonNumber && it.episodeNumber in op.episodes }.map { it.id }.toSet()
            if (ids.isNotEmpty()) { _watches.value = _watches.value.map { if (it.id in ids) it.copy(markedWatched = true) else it }; saveWatches() }
        }
        finish(op, SerializdOperationStatus.Synced)
    }

    private suspend fun runUnmark(op: SerializdOperation, service: SerializdService) {
        val placed = place(service, op.target, op.episodes)
        service.api.unlogEpisodes(op.showTmdbId, placed.seasonId!!, placed.episodes)
        stateLock.withLock {
            val synced = readSynced()
            op.episodes.forEach { synced -= markerKey(op.account, SerializdTarget(op.showTmdbId, op.seasonNumber, it)) }
            writeSynced(synced)
            _watches.value = _watches.value.map { w -> if (w.profileId == op.profileId && w.account.equals(op.account, true) && w.showTmdbId == op.showTmdbId && w.seasonNumber == op.seasonNumber && w.episodeNumber in op.episodes) w.copy(markedWatched = false) else w }
            saveWatches()
        }
        finish(op, SerializdOperationStatus.Synced, note = "Watched marker removed; the diary entry, if any, is unchanged")
    }

    private suspend fun runDiary(op: SerializdOperation, service: SerializdService, markWrite: () -> Unit) {
        val placed = place(service, op.target, listOf(op.episodeNumber ?: 0))
        val seasonId = placed.seasonId!!
        val serEpisode = placed.episodes.first()
        val payload = SerializdReviewPayload(
            showTmdbId = op.showTmdbId, seasonId = seasonId, episodeNumber = serEpisode, rating = SerializdRating.toSerializd(op.stars),
            reviewText = op.reviewText.orEmpty(), containsSpoiler = op.containsSpoilers, backdateMs = op.watchedAtMs, isLog = true,
            isRewatch = op.rewatch, like = op.liked,
        )
        if (!reconcile(op, service, seasonId, serEpisode, onlyLogs = true)) return
        markWrite()
        markSent(op)
        val ack = service.api.addReview(payload)
        landed(op, ack.reviewId, payload.rating, diary = true, text = payload.reviewText)
        finish(op, SerializdOperationStatus.Synced, note = if (op.rewatch) "Logged as a rewatch" else null)
    }

    /**
     * Before a write that was already sent once: reads the diary and finishes the operation if the entry is there. Returns true when
     * the write may (still) be sent; false when this call has finished the operation or is waiting. A failed diary read throws, so it
     * is never taken as "no entry".
     */
    private suspend fun reconcile(op: SerializdOperation, service: SerializdService, seasonId: Int?, serEpisode: Int?, onlyLogs: Boolean): Boolean {
        if (!op.reconciling) return true
        val found = findOnDiary(service, op.showTmdbId, seasonId, serEpisode, op.watchedAtMs, onlyLogs, SerializdRating.toSerializd(op.stars))
        if (found != null) {
            landed(op, found.id, SerializdRating.toSerializd(op.stars), diary = op.type != SerializdOperationType.SubmitRating && op.watchId != null, text = op.reviewText.orEmpty())
            finish(op, SerializdOperationStatus.Synced, note = "Confirmed on your Serializd diary"); return false
        }
        val waitedMs = now() - op.writeSentAtMs
        if (op.noReply && waitedMs < RESEND_AFTER_MS) {
            finish(op, SerializdOperationStatus.ReconciliationRequired, SerializdErrorCategory.Ambiguous, "Waiting to see whether the entry appears on your diary",
                nextAttemptAtMs = op.writeSentAtMs + RESEND_AFTER_MS, reconciling = true, noReply = true); return false
        }
        return true // the diary was read, the entry is not on it, and enough time has passed
    }

    private suspend fun markSent(op: SerializdOperation) = stateLock.withLock {
        _operations.value.firstOrNull { it.id == op.id }?.let { replace(it.copy(reconciling = true, writeSentAtMs = now(), noReply = false)) }
    }

    /**
     * The write is known to be on Serializd. A dated entry of a viewing marks that viewing as on the diary and remembers the entry's id
     * (what an edit goes to); a rating or review of its own (a season, a show) remembers its id in its slot. Either way the rating is
     * noted as already there.
     */
    private suspend fun landed(op: SerializdOperation, reviewId: Int?, rating10: Int, diary: Boolean, text: String) = stateLock.withLock {
        val watchId = op.watchId
        if (diary) {
            // A dated entry belongs to its viewing. (A backfilled one has no local viewing and is not anyone's rating slot either.)
            if (watchId != null) {
                _watches.value = _watches.value.map { w ->
                    if (w.id == watchId) w.copy(
                        onDiary = true, remoteReviewId = reviewId ?: w.remoteReviewId, reviewPublished = w.reviewPublished || text.isNotBlank(),
                        stars = SerializdRating.fromSerializd(rating10) ?: w.stars,
                    ) else w
                }; saveWatches()
            }
        } else {
            val kind = if (op.type == SerializdOperationType.SubmitReview) "l" else "r"
            writeIntMap(SLOT_KEY, readIntMap(SLOT_KEY).also { it[slotKey(op.account, kind, op.target)] = reviewId ?: 0 })
        }
        if (rating10 in 1..10) writeIntMap(PUSHED_KEY, readIntMap(PUSHED_KEY).also { it[pushedKey(op.account, op.target)] = rating10 })
    }

    private suspend fun runReview(op: SerializdOperation, service: SerializdService, markWrite: () -> Unit) {
        val isReview = op.type == SerializdOperationType.SubmitReview
        val rating10 = SerializdRating.toSerializd(op.stars)
        val pushedNow = readIntMap(PUSHED_KEY)[pushedKey(op.account, op.target)]
        // A show-level entry with no rating is a like being switched, which has to go out; anywhere else nothing is left to send.
        if (!isReview && rating10 == 0 && !op.liked && op.target.scope != SerializdScope.Show) { finish(op, SerializdOperationStatus.Skipped, note = "No rating to send"); return }
        if (!isReview && rating10 > 0 && pushedNow == rating10 && !op.liked && op.reviewId == null && op.target.scope != SerializdScope.Show) {
            finish(op, SerializdOperationStatus.Skipped, note = "Already ${SerializdRating.label(op.stars)} stars on Serializd"); return
        }
        val watch = op.watchId?.let { id -> _watches.value.firstOrNull { it.id == id } }
        val placed = place(service, op.target, listOfNotNull(op.episodeNumber))
        val seasonId = placed.seasonId
        val serEpisode = placed.episodes.firstOrNull()
        // Which entry this goes to. A viewing already on the diary is edited in place; otherwise it is a rating or review of its own.
        val onDiary = watch?.onDiary == true
        var editId: Int? = op.reviewId
        var isLog = isReview
        var backdate = if (op.watchedAtMs > 0) op.watchedAtMs else op.createdAtMs
        var rewatch = op.rewatch
        var text = op.reviewText.orEmpty()
        var spoiler = op.containsSpoilers
        var like = op.liked
        if (watch != null && onDiary) {
            editId = editId ?: watch.remoteReviewId ?: findOnDiary(service, op.showTmdbId, seasonId, serEpisode, watch.completedAtMs, true, null)?.id
            isLog = true; backdate = watch.completedAtMs; rewatch = watch.rewatch; like = like || watch.liked
            if (op.reviewText == null) { text = watch.reviewDraft.takeIf { watch.reviewPublished }.orEmpty(); spoiler = watch.reviewSpoilers }
            if (editId == null) {
                finish(op, SerializdOperationStatus.ActionRequired, SerializdErrorCategory.Unsupported,
                    "This entry is on Serializd but could not be found to edit. Your text is kept here; open Serializd to change it")
                return
            }
        } else {
            val known = readIntMap(SLOT_KEY)[slotKey(op.account, if (isReview) "l" else "r", op.target)]
            if (known == 0) {
                finish(op, SerializdOperationStatus.ActionRequired, SerializdErrorCategory.Unsupported,
                    "Serializd already has this ${if (isReview) "review" else "rating"} from this device and it can not be edited here. Open Serializd to change it")
                return
            }
            editId = editId ?: known
        }
        val payload = SerializdReviewPayload(
            showTmdbId = op.showTmdbId, seasonId = seasonId, episodeNumber = serEpisode,
            rating = if (rating10 > 0) rating10 else if (watch != null) SerializdRating.toSerializd(watch.stars) else (pushedNow ?: 0),
            reviewText = text, containsSpoiler = spoiler, backdateMs = backdate, isLog = isLog, isRewatch = rewatch, like = like,
        )
        if (editId == null && !reconcile(op, service, seasonId, serEpisode, onlyLogs = false)) return
        markWrite()
        markSent(op)
        val ack = if (editId != null) service.api.updateReview(editId, payload) else service.api.addReview(payload)
        landed(op, ack.reviewId ?: editId, payload.rating, diary = isLog && watch != null, text = text)
        finish(op, SerializdOperationStatus.Synced, note = if (editId != null) "Updated the existing entry" else null)
    }

    /** Reads the newest diary pages for an entry like this one. [onlyLogs] limits it to dated entries. A failed read throws. */
    private suspend fun findOnDiary(service: SerializdService, showTmdbId: Int, seasonId: Int?, episode: Int?, atMs: Long, onlyLogs: Boolean, rating10: Int?): SerializdDiaryEntry? {
        val username = service.session.ensureUsername()
        var page = 1
        while (page <= RECONCILE_PAGES) {
            val result = service.api.diaryPage(username, page)
            result.entries.firstOrNull { e ->
                e.showTmdbId == showTmdbId && e.seasonId == seasonId && e.episodeNumber == episode && (!onlyLogs || e.isLog) &&
                    (rating10 == null || rating10 == 0 || e.rating == rating10 || e.rating == null) && timeMatches(e, atMs)
            }?.let { return it }
            if (result.rawCount == 0 || (result.totalPages != null && page >= result.totalPages)) break
            page++
        }
        return null
    }

    private fun timeMatches(e: SerializdDiaryEntry, atMs: Long): Boolean {
        val back = e.backdateMs ?: return false
        return if (e.backdateDateOnly) SerializdDates.utcDate(back) == SerializdDates.utcDate(atMs) else abs(back - atMs) <= MATCH_WINDOW_MS
    }

    private suspend fun finish(
        op: SerializdOperation, status: SerializdOperationStatus, error: SerializdErrorCategory = SerializdErrorCategory.None,
        note: String? = null, nextAttemptAtMs: Long = 0L, reconciling: Boolean = false, noReply: Boolean = false,
    ) = stateLock.withLock {
        val current = _operations.value.firstOrNull { it.id == op.id } ?: op
        val keepReconciling = reconciling || (current.reconciling && status == SerializdOperationStatus.NeedsReconnect)
        val done = status in FINISHED
        val updated = current.copy(
            status = status, error = error, note = note, nextAttemptAtMs = nextAttemptAtMs,
            reconciling = if (done) false else keepReconciling, noReply = if (done) false else noReply || (keepReconciling && current.noReply),
            // A review that is on Serializd is not kept in the queue as well: the viewing holds the member's text.
            reviewText = if (status == SerializdOperationStatus.Synced) null else current.reviewText,
        )
        replace(updated)
        record(updated, status, error, note)
    }

    private suspend fun handleFailure(op: SerializdOperation, e: SerializdException, writeStarted: Boolean) {
        val attempts = op.attempts
        // A write that may have landed is reconciled, never retried blind. A failure before anything reached Serializd (no connection,
        // a rate limit, a refusal) means it did not land; a server error, a lost reply or an odd answer might have.
        val mayHaveLanded = writeStarted && (e is SerializdException.Server || e is SerializdException.NoReplyAfterSend || e is SerializdException.Unexpected)
        val sentBefore = mayHaveLanded || op.reconciling
        val lostReply = e is SerializdException.NoReplyAfterSend || (op.noReply && e !is SerializdException.Rejected)
        when (e) {
            is SerializdException.NoReplyAfterSend ->
                finish(op, SerializdOperationStatus.ReconciliationRequired, SerializdErrorCategory.Ambiguous, "No answer after sending; your diary is checked before anything is sent again",
                    nextAttemptAtMs = now() + RECONCILE_AFTER_MS, reconciling = true, noReply = true)
            is SerializdException.SessionExpired -> {
                val opened = breaker(op.profileId).recordFailure()
                host.onConnectionState(op.profileId, if (opened) SerializdConnectionState.ReconnectionRequired else SerializdConnectionState.SessionExpired)
                finish(op, SerializdOperationStatus.NeedsReconnect, e.category, reconciling = sentBefore)
            }
            is SerializdException.ReconnectRequired, is SerializdException.BadCredentials -> {
                host.onConnectionState(op.profileId, SerializdConnectionState.ReconnectionRequired)
                finish(op, SerializdOperationStatus.NeedsReconnect, SerializdErrorCategory.ReconnectionRequired, reconciling = sentBefore)
            }
            is SerializdException.RateLimited -> retryOrFail(op, e, attempts, sentBefore, minDelay = e.retryAfterMs ?: SerializdSession.DEFAULT_RETRY_AFTER_MS, noReply = lostReply)
            is SerializdException.Network, is SerializdException.Server -> retryOrFail(op, e, attempts, sentBefore, noReply = lostReply)
            is SerializdException.NotFound ->
                if (attempts >= MAX_METADATA_ATTEMPTS) finish(op, SerializdOperationStatus.FailedPermanent, e.category, "${e.message}; tried $attempts times")
                else finish(op, SerializdOperationStatus.RetryScheduled, e.category, e.message?.let(::sanitize), nextAttemptAtMs = now() + metadataBackoffMs(attempts))
            is SerializdException.MetadataMismatch, is SerializdException.Rejected, is SerializdException.Unsupported ->
                finish(op, SerializdOperationStatus.FailedPermanent, e.category, e.message?.let(::sanitize))
            is SerializdException.Unexpected ->
                if (writeStarted) finish(op, SerializdOperationStatus.ReconciliationRequired, SerializdErrorCategory.Ambiguous, "Unexpected answer to a write; checking your diary",
                    nextAttemptAtMs = now() + RECONCILE_AFTER_MS, reconciling = true)
                else retryOrFail(op, e, attempts, sentBefore, noReply = false)
        }
    }

    private suspend fun retryOrFail(op: SerializdOperation, e: SerializdException, attempts: Int, sentBefore: Boolean, minDelay: Long = 0L, noReply: Boolean) {
        if (attempts >= MAX_ATTEMPTS) {
            finish(op, SerializdOperationStatus.FailedPermanent, e.category, e.message?.let(::sanitize), reconciling = sentBefore, noReply = noReply); return
        }
        finish(op, SerializdOperationStatus.RetryScheduled, e.category, null, nextAttemptAtMs = now() + maxOf(backoffMs(attempts), minDelay), reconciling = sentBefore, noReply = noReply)
    }

    /** Error text for the history: whatever Serializd sent, flattened and short. It never carries the member's review. */
    private fun sanitize(text: String): String = text.replace(Regex("\\s+"), " ").take(160)

    // ------------------------------------------------------------------ controls

    /** Puts a stopped operation back in the queue (the member's Retry). An operation that sent a write is still checked first. */
    suspend fun retry(opId: String) = stateLock.withLock {
        _operations.value.firstOrNull { it.id == opId }?.let {
            if (it.status in RETRYABLE) replace(it.copy(status = SerializdOperationStatus.Pending, attempts = 0, nextAttemptAtMs = 0, error = SerializdErrorCategory.None, note = null))
        }
    }

    /** Puts every stopped operation of a profile back in the queue. */
    suspend fun retryAll(profileId: Int) = stateLock.withLock {
        _operations.value = _operations.value.map {
            if (it.profileId == profileId && it.status in RETRYABLE && it.status != SerializdOperationStatus.ActionRequired) it.copy(status = SerializdOperationStatus.Pending, attempts = 0, nextAttemptAtMs = 0, error = SerializdErrorCategory.None, note = null) else it
        }; saveOps()
    }

    /** The session works again: held operations go back in the queue, safely, and the breaker closes. */
    suspend fun onReconnected(profileId: Int) = stateLock.withLock {
        breaker(profileId).reset()
        _operations.value = _operations.value.map {
            if (it.profileId == profileId && it.status == SerializdOperationStatus.NeedsReconnect) it.copy(status = SerializdOperationStatus.Pending, error = SerializdErrorCategory.None, attempts = 0) else it
        }; saveOps()
    }

    /** Disconnecting stops every remote write for the account and touches no other account. [deleteLocal] also removes the profile's local Serializd history. */
    suspend fun onDisconnected(profileId: Int, account: String, deleteLocal: Boolean) = stateLock.withLock {
        _operations.value = _operations.value.filterNot { it.profileId == profileId && it.account.equals(account, true) && it.status !in FINISHED }; saveOps()
        synchronized(breakerLock) { breakers.remove(profileId) }
        val prefix = account.lowercase()
        if (deleteLocal) {
            _watches.value = _watches.value.filterNot { it.profileId == profileId }; saveWatches()
            _operations.value = _operations.value.filterNot { it.profileId == profileId }; saveOps()
            _events.value = _events.value.filterNot { it.profileId == profileId }; saveEvents()
            writeSynced(readSynced().filterNot { it.startsWith("m|$prefix|") }.toSet())
            writeIntMap(PUSHED_KEY, readIntMap(PUSHED_KEY).filterKeys { !it.startsWith("$prefix|") })
            writeIntMap(SLOT_KEY, readIntMap(SLOT_KEY).filterKeys { !it.startsWith("$prefix|") })
        }
    }

    /** Removes everything this engine keeps, for every profile (an account wipe or a sign-out of the app). */
    suspend fun wipeEverything() = stateLock.withLock {
        _operations.value = emptyList(); _watches.value = emptyList(); _events.value = emptyList()
        listOf(OPS_KEY, WATCHES_KEY, EVENTS_KEY, SYNCED_KEY, PUSHED_KEY, SLOT_KEY, COVERAGE_KEY).forEach { store.write(it, null) }
        synchronized(breakerLock) { breakers.clear() }
    }

    // ------------------------------------------------------------------ import

    /**
     * Adds what was read from the member's Serializd history. Safe to run again: a viewing with an id already held is skipped. Everything
     * added is marked as known on Serializd, so it is never sent back (the import/export loop guard), and the ratings read are remembered
     * as already there. Returns how many viewings were new.
     */
    suspend fun addImported(profileId: Int, account: String, imported: List<SerializdWatch>, markerTargets: Collection<SerializdTarget>, remoteIds: Map<String, Int>, ratings: Map<String, Int>): Int = stateLock.withLock {
        val known = _watches.value.map { it.id }.toHashSet()
        val fresh = imported.filter { known.add(it.id) }
        if (fresh.isNotEmpty()) { _watches.value = trimWatches(_watches.value + fresh); saveWatches() }
        val synced = readSynced()
        markerTargets.forEach { synced += markerKey(account, it) }
        fresh.forEach { synced += markerKey(account, it.target) }
        writeSynced(synced)
        if (remoteIds.isNotEmpty()) writeIntMap(SLOT_KEY, readIntMap(SLOT_KEY).also { it.putAll(remoteIds) })
        if (ratings.isNotEmpty()) writeIntMap(PUSHED_KEY, readIntMap(PUSHED_KEY).also { it.putAll(ratings) })
        fresh.size
    }

    /** Marks episodes as already marked watched on Serializd (read from it), without making viewings. */
    suspend fun noteMarkers(account: String, targets: Collection<SerializdTarget>) = stateLock.withLock {
        val synced = readSynced(); targets.forEach { synced += markerKey(account, it) }; writeSynced(synced)
    }

    fun slotKeyFor(account: String, review: Boolean, target: SerializdTarget) = slotKey(account, if (review) "l" else "r", target)
    fun pushedKeyFor(account: String, target: SerializdTarget) = pushedKey(account, target)

    // ------------------------------------------------------------------ queries

    /** Viewings of one episode for a profile, newest first. */
    fun watchesFor(profileId: Int, target: SerializdTarget): List<SerializdWatch> =
        _watches.value.filter { it.profileId == profileId && it.target == target }.sortedByDescending { it.completedAtMs }

    /** The rating Serializd is known to hold for this episode, season or show (a value 1 to 10), or null. */
    fun knownRating(account: String, target: SerializdTarget): Double? = SerializdRating.fromSerializd(readIntMap(PUSHED_KEY)[pushedKey(account, target)])

    /** How many episodes of a show (or of one of its seasons) are known to be marked watched on this account, from BannerTV or read from Serializd. */
    fun watchedEpisodeCount(account: String, showTmdbId: Int, season: Int? = null): Int {
        val prefix = "m|${account.lowercase()}|$showTmdbId|" + (season?.let { "$it|" } ?: "")
        return readSynced().count { it.startsWith(prefix) }
    }

    /** How many episodes are known to be marked watched on this account in all (from BannerTV or read from Serializd). */
    fun trackedEpisodeCount(account: String): Int {
        val prefix = "m|${account.lowercase()}|"
        return readSynced().count { it.startsWith(prefix) }
    }

    fun pendingCount(profileId: Int): Int = _operations.value.count { it.profileId == profileId && it.status in WAITING }
    fun failedCount(profileId: Int): Int = _operations.value.count { it.profileId == profileId && it.status in STOPPED }

    companion object {
        /** A finish within this long of one already recorded for the same episode is a repeated callback, not a second viewing. */
        const val FINISH_WINDOW_MS = 5 * 60_000L
        const val RATING_DEBOUNCE_MS = 10_000L
        const val MAX_ATTEMPTS = 6
        const val MAX_METADATA_ATTEMPTS = 4
        const val MAX_BACKOFF_MS = 30 * 60_000L
        const val RECONCILE_AFTER_MS = 2 * 60_000L
        /** A write that got no answer is not sent again until this long after it was sent, and only once the diary is readable and lacks it. */
        const val RESEND_AFTER_MS = 10 * 60_000L
        const val STUCK_AFTER_MS = 5 * 60_000L
        const val RECONCILE_PAGES = 3
        const val MATCH_WINDOW_MS = 2 * 60_000L
        /** After this many failures of the service itself in a row the rest of the queue waits for the next run. */
        const val PAUSE_AFTER_FAILURES = 5
        const val MAX_BACKFILL_DIARY = 400
        /** 2001-01-01: anything earlier is a placeholder, not a day somebody watched an episode. */
        const val PLAUSIBLE_WATCH_DATE_MS = 978_307_200_000L
        private const val KEEP_FINISHED_OPS = 40
        private const val MAX_WATCHES = 3000
        private const val MAX_EVENTS = 300
        private const val OPS_KEY = "serializd_ops_v1"
        private const val WATCHES_KEY = "serializd_watches_v1"
        private const val EVENTS_KEY = "serializd_events_v1"
        private const val SYNCED_KEY = "serializd_synced_v1"
        private const val PUSHED_KEY = "serializd_rating_pushed_v1"
        private const val SLOT_KEY = "serializd_review_ids_v1"
        private const val COVERAGE_KEY = "serializd_coverage_v1"
        private val DIARY_TYPES = setOf(SerializdOperationType.CreateDiaryEntry, SerializdOperationType.SubmitReview)
        private val OPEN_BEFORE_SEND = setOf(SerializdOperationStatus.Pending, SerializdOperationStatus.RetryScheduled, SerializdOperationStatus.NeedsReconnect)
        private val FINISHED = setOf(SerializdOperationStatus.Synced, SerializdOperationStatus.Skipped)
        private val WAITING = setOf(SerializdOperationStatus.Pending, SerializdOperationStatus.InProgress, SerializdOperationStatus.RetryScheduled, SerializdOperationStatus.ReconciliationRequired)
        private val STOPPED = setOf(SerializdOperationStatus.FailedPermanent, SerializdOperationStatus.NeedsReconnect, SerializdOperationStatus.ActionRequired)
        private val RETRYABLE = setOf(SerializdOperationStatus.FailedPermanent, SerializdOperationStatus.NeedsReconnect, SerializdOperationStatus.RetryScheduled, SerializdOperationStatus.ActionRequired, SerializdOperationStatus.ReconciliationRequired)
        private val SERVICE_FAILURES = setOf(SerializdErrorCategory.Offline, SerializdErrorCategory.ServerError, SerializdErrorCategory.RateLimited)
    }
}
