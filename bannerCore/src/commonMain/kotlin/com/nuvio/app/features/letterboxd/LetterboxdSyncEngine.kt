package com.nuvio.app.features.letterboxd

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
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** What the sync engine needs from the app around it. */
interface LetterboxdEngineHost {
    /** The connected Letterboxd username for [profileId], or null when none is connected. */
    fun accountOf(profileId: Int): String?
    fun settingsOf(profileId: Int): LetterboxdSettings
    /** A service on the profile's session, or null when it must reconnect first. */
    fun serviceOf(profileId: Int): LetterboxdWebService?
    fun onConnectionState(profileId: Int, state: LetterboxdConnectionState)
}

/** What happened when a review was asked to be published. */
sealed interface LetterboxdReviewOutcome {
    /** Queued with a new diary entry (or folded into the entry still waiting to be sent). */
    data object Queued : LetterboxdReviewOutcome
    /** This viewing is already on the diary and the site flow cannot edit an entry: the draft is kept and the entry can be opened to edit. */
    data class DraftKeptOpenLetterboxd(val url: String) : LetterboxdReviewOutcome
}

@Serializable
private data class StoredCoverage(val key: String, val coverage: WatchedCoverage)

/**
 * The persistent queue behind every Letterboxd write, plus the local record of viewings. Ported from the ideas of
 * Jellyscribe's SyncHistory, FilmSyncLock, RatingSyncHandler and LetterboxdSyncRunner:
 *  - every write has a persisted operation id and viewing id, so a repeated player callback never makes a second diary
 *    entry, and writes are handled one at a time;
 *  - local history, an in-flight check and the remote diary are all consulted before a diary entry is sent, and a failed
 *    diary read is never taken as "no entry";
 *  - a lost reply after a write is reconciled against the diary, never blindly resent;
 *  - ratings are debounced and an unchanged value is not sent again;
 *  - login-type failures stop the account instead of retrying (see [LetterboxdAuthBreaker]).
 * Nothing here runs on the player's thread and nothing blocks playback.
 */
class LetterboxdSyncEngine(
    private val store: LetterboxdKeyValue,
    private val host: LetterboxdEngineHost,
    private val now: () -> Long = { kotlin.time.Clock.System.now().toEpochMilliseconds() },
    private val localDate: (Long) -> String,
    private val newId: () -> String,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val stateLock = Mutex()
    private val processLock = Mutex()
    private val breakers = HashMap<Int, LetterboxdAuthBreaker>()
    private val breakerLock = SynchronizedObject()

    private val _operations = MutableStateFlow(loadList(OPS_KEY, LetterboxdOperation.serializer()))
    private val _viewings = MutableStateFlow(loadList(VIEWINGS_KEY, LetterboxdViewing.serializer()))
    private val _events = MutableStateFlow(loadList(EVENTS_KEY, LetterboxdSyncEvent.serializer()))
    val operations: StateFlow<List<LetterboxdOperation>> = _operations.asStateFlow()
    val viewings: StateFlow<List<LetterboxdViewing>> = _viewings.asStateFlow()
    val events: StateFlow<List<LetterboxdSyncEvent>> = _events.asStateFlow()

    private fun <T> loadList(key: String, s: kotlinx.serialization.KSerializer<T>): List<T> =
        store.read(key)?.let { runCatching { json.decodeFromString(ListSerializer(s), it) }.getOrNull() }.orEmpty()

    private fun saveOps() = store.write(OPS_KEY, json.encodeToString(ListSerializer(LetterboxdOperation.serializer()), _operations.value))
    private fun saveViewings() = store.write(VIEWINGS_KEY, json.encodeToString(ListSerializer(LetterboxdViewing.serializer()), _viewings.value))
    private fun saveEvents() = store.write(EVENTS_KEY, json.encodeToString(ListSerializer(LetterboxdSyncEvent.serializer()), _events.value))

    // ------------------------------------------------------------------ small persisted maps

    private fun pushedKey(account: String, tmdbId: Int) = "${account.lowercase()}|$tmdbId"
    private fun readPushed(): MutableMap<String, Double> =
        store.read(PUSHED_KEY)?.let { runCatching { json.decodeFromString(MapSerializer(String.serializer(), Double.serializer()), it) }.getOrNull() }.orEmpty().toMutableMap()

    private fun writePushed(map: Map<String, Double>) = store.write(PUSHED_KEY, json.encodeToString(MapSerializer(String.serializer(), Double.serializer()), map))

    private fun readCoverages(): MutableMap<String, WatchedCoverage> =
        store.read(COVERAGE_KEY)?.let { runCatching { json.decodeFromString(ListSerializer(StoredCoverage.serializer()), it) }.getOrNull() }
            .orEmpty().associate { it.key to it.coverage }.toMutableMap()

    /** What has really been watched of a film in the viewing in progress (kept between player sessions). */
    suspend fun coverageFor(profileId: Int, tmdbId: Int): WatchedCoverage = stateLock.withLock { readCoverages()["$profileId|$tmdbId"] ?: WatchedCoverage() }

    suspend fun saveCoverage(profileId: Int, tmdbId: Int, coverage: WatchedCoverage) = stateLock.withLock {
        val map = readCoverages()
        map.remove("$profileId|$tmdbId")
        if (coverage.ranges.isNotEmpty()) map["$profileId|$tmdbId"] = coverage
        // Bounded: only the most recent films' progress is kept.
        val keep = map.entries.toList().takeLast(200)
        store.write(COVERAGE_KEY, json.encodeToString(ListSerializer(StoredCoverage.serializer()), keep.map { StoredCoverage(it.key, it.value) }))
    }

    // ------------------------------------------------------------------ completion

    /**
     * Records a finished film and queues its diary entry. Safe to call twice for the same session: the second call returns
     * the first viewing and queues nothing. A second viewing on the same day is kept here and is not sent unless asked for.
     */
    suspend fun onCompletion(c: LetterboxdCompletion, posterUrl: String?, liked: Boolean): LetterboxdViewing = stateLock.withLock {
        val viewingId = "v-${c.sessionId}"
        _viewings.value.firstOrNull { it.id == viewingId }?.let { return@withLock it }
        val date = localDate(c.completedAtMs)
        val priorToday = _viewings.value.any { it.profileId == c.profileId && it.tmdbId == c.tmdbId && it.localDate == date && !it.localOnly }
        val priorEver = _viewings.value.any { it.profileId == c.profileId && it.tmdbId == c.tmdbId && it.localDate.isNotEmpty() && it.localDate < date }
        val viewing = LetterboxdViewing(
            id = viewingId, profileId = c.profileId, tmdbId = c.tmdbId, title = c.title, posterUrl = posterUrl,
            completedAtMs = c.completedAtMs, localDate = date, rewatch = priorEver, liked = liked, localOnly = priorToday,
        )
        _viewings.value = (_viewings.value + viewing).takeLast(MAX_VIEWINGS)
        saveViewings()
        val account = host.accountOf(c.profileId)
        val settings = host.settingsOf(c.profileId)
        if (priorToday) {
            record(c.profileId, account.orEmpty(), c.tmdbId, c.title, LetterboxdOperationType.CreateDiaryEntry, LetterboxdOperationStatus.Skipped, date,
                note = "A second viewing on the same day is kept here and not sent to Letterboxd unless you log it")
        } else if (account != null && settings.autoLogMovies) {
            enqueue(
                LetterboxdOperation(
                    id = "op-$viewingId", profileId = c.profileId, account = account, tmdbId = c.tmdbId, title = c.title,
                    type = LetterboxdOperationType.CreateDiaryEntry, viewingId = viewingId, viewingDate = date,
                    liked = settings.syncFavorites && liked, createdAtMs = now(),
                ),
            )
        }
        viewing
    }

    /** The member's explicit "Log Viewing": sent even when this film is already on the diary that day. */
    suspend fun logViewingManually(profileId: Int, tmdbId: Int, title: String, posterUrl: String?, stars: Double?, liked: Boolean): LetterboxdViewing? = stateLock.withLock {
        val account = host.accountOf(profileId) ?: return@withLock null
        val at = now()
        val id = "v-manual-${newId()}"
        val date = localDate(at)
        val snapped = LetterboxdRating.snap(stars)
        val viewing = LetterboxdViewing(id, profileId, tmdbId, title, posterUrl, at, date, stars = snapped, liked = liked, source = "manual")
        _viewings.value = (_viewings.value + viewing).takeLast(MAX_VIEWINGS); saveViewings()
        enqueue(
            LetterboxdOperation(
                id = "op-$id", profileId = profileId, account = account, tmdbId = tmdbId, title = title, type = LetterboxdOperationType.CreateDiaryEntry,
                viewingId = id, viewingDate = date, stars = snapped, liked = liked, forceSameDay = true, createdAtMs = at,
            ),
        )
        viewing
    }

    // ------------------------------------------------------------------ ratings

    /**
     * Saves a rating at once and queues it. Rapid changes keep only the last (held [RATING_DEBOUNCE_MS] before sending), and a
     * rating on a viewing whose diary entry has not gone out yet rides on that entry instead.
     */
    suspend fun setRating(profileId: Int, tmdbId: Int, title: String, stars: Double?, viewingId: String?) {
        stateLock.withLock {
            val snapped = LetterboxdRating.snap(stars)
            val target = viewingId ?: _viewings.value.lastOrNull { it.profileId == profileId && it.tmdbId == tmdbId }?.id
            if (target != null) { _viewings.value = _viewings.value.map { if (it.id == target) it.copy(stars = snapped) else it }; saveViewings() }
            val account = host.accountOf(profileId)
            // Clearing a rating on the site is not something this session can verify, so an unrated choice stays local.
            if (account == null || !host.settingsOf(profileId).syncRatings || snapped == null) return@withLock
            val pendingCreate = _operations.value.firstOrNull {
                it.profileId == profileId && it.tmdbId == tmdbId && it.type != LetterboxdOperationType.SetRating && it.viewingId == target &&
                    it.status in OPEN_BEFORE_SEND && it.type in DIARY_TYPES
            }
            if (pendingCreate != null) { replace(pendingCreate.copy(stars = snapped)); return@withLock }
            val existing = _operations.value.firstOrNull { it.profileId == profileId && it.tmdbId == tmdbId && it.type == LetterboxdOperationType.SetRating && it.status in OPEN_BEFORE_SEND }
            val base = existing ?: LetterboxdOperation(
                id = "op-rate-${newId()}", profileId = profileId, account = account, tmdbId = tmdbId, title = title,
                type = LetterboxdOperationType.SetRating, createdAtMs = now(),
            )
            val op = base.copy(stars = snapped, notBeforeMs = now() + RATING_DEBOUNCE_MS, status = LetterboxdOperationStatus.Pending, attempts = 0, nextAttemptAtMs = 0)
            if (existing != null) replace(op) else enqueue(op)
        }
    }

    // ------------------------------------------------------------------ reviews

    suspend fun saveReviewDraft(viewingId: String, text: String, spoilers: Boolean) = stateLock.withLock {
        _viewings.value = _viewings.value.map { if (it.id == viewingId) it.copy(reviewDraft = text, reviewSpoilers = spoilers) else it }; saveViewings()
    }

    /**
     * Publishes a review the member wrote. It goes with a new diary entry, or joins the entry still waiting to be sent. When
     * the viewing is already on the diary, nothing is sent: an edit this session cannot verify is not attempted (it would
     * make a second viewing), the draft is kept and the entry's page is offered instead.
     */
    suspend fun publishReview(viewingId: String, text: String, spoilers: Boolean, stars: Double?): LetterboxdReviewOutcome? = stateLock.withLock {
        val viewing = _viewings.value.firstOrNull { it.id == viewingId } ?: return@withLock null
        val account = host.accountOf(viewing.profileId)
        val snapped = LetterboxdRating.snap(stars ?: viewing.stars)
        _viewings.value = _viewings.value.map { if (it.id == viewingId) it.copy(reviewDraft = text, reviewSpoilers = spoilers, stars = snapped) else it }; saveViewings()
        if (account == null) return@withLock LetterboxdReviewOutcome.DraftKeptOpenLetterboxd("https://letterboxd.com/")
        val ops = _operations.value.filter { it.viewingId == viewingId && it.type in DIARY_TYPES }
        val pending = ops.firstOrNull { it.status in OPEN_BEFORE_SEND }
        val inDoubt = ops.any { it.status == LetterboxdOperationStatus.NeedsReconciliation || it.status == LetterboxdOperationStatus.InProgress }
        val onDiary = viewing.onDiary || ops.any { it.status == LetterboxdOperationStatus.Succeeded || it.status == LetterboxdOperationStatus.Skipped }
        when {
            pending != null -> { replace(pending.copy(reviewText = text, containsSpoilers = spoilers, stars = snapped ?: pending.stars)); LetterboxdReviewOutcome.Queued }
            onDiary || inDoubt -> LetterboxdReviewOutcome.DraftKeptOpenLetterboxd(entryUrl(account, viewing))
            else -> {
                // Never sent for this viewing (automatic logging off, or a local-only repeat): the review makes its own entry.
                enqueue(
                    LetterboxdOperation(
                        id = "op-review-${newId()}", profileId = viewing.profileId, account = account, tmdbId = viewing.tmdbId, title = viewing.title,
                        type = LetterboxdOperationType.PublishReview, viewingId = viewingId, viewingDate = viewing.localDate, stars = snapped,
                        liked = viewing.liked && host.settingsOf(viewing.profileId).syncFavorites, reviewText = text, containsSpoilers = spoilers,
                        forceSameDay = viewing.localOnly, createdAtMs = now(),
                    ),
                )
                LetterboxdReviewOutcome.Queued
            }
        }
    }

    private fun entryUrl(account: String, viewing: LetterboxdViewing): String {
        val slug = _operations.value.firstOrNull { it.viewingId == viewing.id && it.filmSlug != null }?.filmSlug
        return if (slug != null) "https://letterboxd.com/$account/film/$slug/" else "https://letterboxd.com/$account/films/diary/"
    }

    // ------------------------------------------------------------------ queue plumbing

    private fun enqueue(op: LetterboxdOperation) {
        if (_operations.value.any { it.id == op.id }) return
        _operations.value = trim(_operations.value + op); saveOps()
        record(op, op.status)
    }

    private fun replace(op: LetterboxdOperation) {
        _operations.value = _operations.value.map { if (it.id == op.id) op else it }; saveOps()
    }

    private fun trim(ops: List<LetterboxdOperation>): List<LetterboxdOperation> {
        if (ops.size <= MAX_OPS) return ops
        val drop = ops.filter { it.status in FINISHED }.take(ops.size - MAX_OPS).map { it.id }.toSet()
        return ops.filterNot { it.id in drop }.takeLast(MAX_OPS)
    }

    private fun record(op: LetterboxdOperation, status: LetterboxdOperationStatus, error: LetterboxdErrorCategory = LetterboxdErrorCategory.None, note: String? = null) {
        if (status == LetterboxdOperationStatus.Pending) return
        record(op.profileId, op.account, op.tmdbId, op.title, op.type, status, op.viewingDate, error, note)
    }

    private fun record(profileId: Int, account: String, tmdbId: Int, title: String, type: LetterboxdOperationType, status: LetterboxdOperationStatus,
                       date: String?, error: LetterboxdErrorCategory = LetterboxdErrorCategory.None, note: String? = null) {
        val e = LetterboxdSyncEvent(newId(), now(), profileId, account, tmdbId, title, type, status, date, error, note)
        _events.value = (_events.value + e).takeLast(MAX_EVENTS); saveEvents()
    }

    // ------------------------------------------------------------------ processing

    /** Sends what is due, one operation at a time. Called when the app opens, when the network returns and after each completion. */
    suspend fun processPending() {
        if (!processLock.tryLock()) return
        try {
            while (true) {
                val op = stateLock.withLock {
                    val t = now()
                    val due = _operations.value
                        .filter { it.isRunnable(t) && host.accountOf(it.profileId) == it.account && !breaker(it.profileId).isOpen }
                        .minByOrNull { it.createdAtMs } ?: return@withLock null
                    val started = due.copy(status = LetterboxdOperationStatus.InProgress, lastAttemptAtMs = t, attempts = due.attempts + 1)
                    replace(started); started
                } ?: break
                runOne(op)
            }
        } finally {
            processLock.unlock()
        }
    }

    private fun LetterboxdOperation.isRunnable(t: Long): Boolean = when (status) {
        LetterboxdOperationStatus.Pending -> notBeforeMs <= t
        LetterboxdOperationStatus.RetryScheduled -> nextAttemptAtMs <= t
        LetterboxdOperationStatus.NeedsReconciliation -> lastAttemptAtMs + RECONCILE_AFTER_MS <= t
        // An operation left in progress by a closed app is picked up again, and checked first when it had sent its write.
        LetterboxdOperationStatus.InProgress -> lastAttemptAtMs + STUCK_AFTER_MS <= t
        else -> false
    }

    private fun breaker(profileId: Int) = synchronized(breakerLock) { breakers.getOrPut(profileId) { LetterboxdAuthBreaker() } }

    /** How long to wait before retry number [attempts]: 30 s, 1 min, 2 min... up to 30 min. */
    internal fun backoffMs(attempts: Int): Long = minOf(30_000L shl (attempts - 1).coerceIn(0, 10), MAX_BACKOFF_MS)

    private suspend fun runOne(op: LetterboxdOperation) {
        val service = host.serviceOf(op.profileId)
        if (service == null) {
            // No usable session is stored for this account: nothing can be sent until the member signs in again.
            host.onConnectionState(op.profileId, LetterboxdConnectionState.ReconnectionRequired)
            finish(op, LetterboxdOperationStatus.NeedsReconnect, LetterboxdErrorCategory.ReconnectionRequired); return
        }
        var writeStarted = false
        try {
            when (op.type) {
                in DIARY_TYPES -> createDiary(op, service) { writeStarted = true }
                LetterboxdOperationType.SetRating -> setRating(op, service)
                else -> finish(op, LetterboxdOperationStatus.Skipped, note = "Not a queued operation")
            }
            breaker(op.profileId).recordSuccess()
            host.onConnectionState(op.profileId, LetterboxdConnectionState.Connected)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: LetterboxdException) {
            handleFailure(op, e, writeStarted)
        } catch (e: Throwable) {
            handleFailure(op, LetterboxdException.Unexpected("Unexpected error"), writeStarted)
        }
    }

    private suspend fun createDiary(op: LetterboxdOperation, service: LetterboxdWebService, markWrite: () -> Unit) {
        val date = op.viewingDate ?: localDate(op.createdAtMs)
        val settings = host.settingsOf(op.profileId)
        val film = service.resolveFilm(op.tmdbId)
        withFilm(op, film)
        val review = op.reviewText

        // An operation whose write was sent before: check the diary, send nothing, until it is clear the entry is not there.
        var reconciling = op.reconciling
        if (reconciling) {
            val diary = service.diaryInfo(film)
            if (diary.hasDate(date)) { markOnDiary(op, !review.isNullOrBlank()); finish(op, LetterboxdOperationStatus.Succeeded, externalDate = date, note = "Confirmed on the diary"); return }
            if (now() - op.writeSentAtMs < RESEND_AFTER_MS) {
                finish(op, LetterboxdOperationStatus.NeedsReconciliation, LetterboxdErrorCategory.Ambiguous, "Waiting to see whether the entry appears on your diary", reconciling = true, keepWriteSentAt = true); return
            }
            reconciling = false // the diary was read, the entry is not on it, and enough time has passed
        }

        // Local record first: this device already confirmed this film on this day.
        val syncedHere = _viewings.value.filter { it.profileId == op.profileId && it.tmdbId == op.tmdbId && it.onDiary && it.id != op.viewingId }.map { it.localDate }
        if (!op.forceSameDay && date in syncedHere) { alreadyThere(op, date, "Already synced from this device for $date"); return }
        // Then the remote diary. A failed read throws and the op is retried: it is never read as "no entry".
        val diary = service.diaryInfo(film)
        if (!op.forceSameDay && diary.hasDate(date)) { alreadyThere(op, date, "Already on your Letterboxd diary for $date"); return }
        val prior = diary.dates.filter { it < date } + syncedHere.filter { it < date }
        val rewatch = LetterboxdDates.isRewatch(prior.maxOrNull(), date)
        if (rewatch && !settings.logRewatches && !op.forceSameDay) { finish(op, LetterboxdOperationStatus.Skipped, note = "Rewatch logging is off"); return }

        markWrite()
        stateLock.withLock { _operations.value.firstOrNull { it.id == op.id }?.let { replace(it.copy(reconciling = true, writeSentAtMs = now())) } }
        service.writeDiary(LetterboxdDiaryWrite(film, date, rewatch, op.liked, LetterboxdRating.snap(op.stars), review, op.containsSpoilers))
        // Accepted is not confirmed: read the diary back.
        val after = try { service.diaryInfo(film) } catch (e: LetterboxdException) {
            finish(op, LetterboxdOperationStatus.NeedsReconciliation, LetterboxdErrorCategory.Ambiguous, "The site accepted the entry; confirming it on the diary", reconciling = true, keepWriteSentAt = true)
            return
        }
        if (after.hasDate(date)) {
            markOnDiary(op, !review.isNullOrBlank())
            finish(op, LetterboxdOperationStatus.Succeeded, externalDate = date, note = if (rewatch) "Logged as a rewatch" else null)
        } else {
            finish(op, LetterboxdOperationStatus.NeedsReconciliation, LetterboxdErrorCategory.Ambiguous, "The site accepted the entry but it is not on the diary yet", reconciling = true, keepWriteSentAt = true)
        }
    }

    /**
     * The viewing is already on the diary, so nothing is sent. A review waiting on this operation is not lost and not sent
     * as a second entry: the draft stays on the viewing and the member is told to add it on Letterboxd.
     */
    private suspend fun alreadyThere(op: LetterboxdOperation, date: String, why: String) {
        markOnDiary(op)
        if (!op.reviewText.isNullOrBlank()) {
            finish(op, LetterboxdOperationStatus.ActionRequired, LetterboxdErrorCategory.Unsupported,
                "$why. Your review is saved here; open Letterboxd to add it to that entry")
        } else {
            finish(op, LetterboxdOperationStatus.Skipped, note = why)
        }
    }

    private suspend fun setRating(op: LetterboxdOperation, service: LetterboxdWebService) {
        val stars = LetterboxdRating.snap(op.stars) ?: run { finish(op, LetterboxdOperationStatus.Skipped, note = "No rating to send"); return }
        val key = pushedKey(op.account, op.tmdbId)
        if (readPushed()[key] == stars) { finish(op, LetterboxdOperationStatus.Skipped, note = "Already ${LetterboxdRating.label(stars)} stars on Letterboxd"); return }
        val film = service.resolveFilm(op.tmdbId)
        withFilm(op, film)
        service.rateFilm(film, stars)
        stateLock.withLock { writePushed(readPushed().also { it[key] = stars }) }
        finish(op, LetterboxdOperationStatus.Succeeded)
    }

    private suspend fun withFilm(op: LetterboxdOperation, film: LetterboxdFilm) = stateLock.withLock {
        _operations.value.firstOrNull { it.id == op.id }?.let { replace(it.copy(filmId = film.filmId, filmSlug = film.slug)) }
    }

    private suspend fun markOnDiary(op: LetterboxdOperation, reviewPublished: Boolean = false) = stateLock.withLock {
        val id = op.viewingId ?: return@withLock
        _viewings.value = _viewings.value.map { if (it.id == id) it.copy(onDiary = true, reviewPublished = it.reviewPublished || reviewPublished) else it }; saveViewings()
    }

    private suspend fun finish(
        op: LetterboxdOperation, status: LetterboxdOperationStatus, error: LetterboxdErrorCategory = LetterboxdErrorCategory.None,
        note: String? = null, externalDate: String? = null, nextAttemptAtMs: Long = 0L, reconciling: Boolean = false, @Suppress("UNUSED_PARAMETER") keepWriteSentAt: Boolean = false,
    ) = stateLock.withLock {
        val current = _operations.value.firstOrNull { it.id == op.id } ?: op
        val updated = current.copy(
            status = status, error = error, note = note, nextAttemptAtMs = nextAttemptAtMs,
            externalEntryDate = externalDate ?: current.externalEntryDate,
            reconciling = reconciling || (current.reconciling && status == LetterboxdOperationStatus.NeedsReconnect),
        )
        replace(updated)
        record(updated, status, error, note)
    }

    private suspend fun handleFailure(op: LetterboxdOperation, e: LetterboxdException, writeStarted: Boolean) {
        val attempts = op.attempts
        // A write that may have landed is reconciled, never retried blind. A failure before anything reached the site
        // (no connection, a bot check, a rate limit) means it did not land; a server error or an odd answer might have.
        val mayHaveLanded = writeStarted && (e is LetterboxdException.Server || e is LetterboxdException.Unexpected || e is LetterboxdException.SessionExpired)
        val sentBefore = mayHaveLanded || op.reconciling
        when (e) {
            is LetterboxdException.NoReplyAfterSend ->
                finish(op, LetterboxdOperationStatus.NeedsReconciliation, LetterboxdErrorCategory.Ambiguous, "No reply after sending; checked against your diary before anything is sent again", reconciling = true, keepWriteSentAt = true)
            is LetterboxdException.SessionExpired -> {
                val opened = breaker(op.profileId).recordFailure()
                host.onConnectionState(op.profileId, if (opened) LetterboxdConnectionState.ReconnectionRequired else LetterboxdConnectionState.SessionExpired)
                finish(op, LetterboxdOperationStatus.NeedsReconnect, e.category, reconciling = sentBefore, keepWriteSentAt = true)
            }
            is LetterboxdException.ReconnectRequired -> {
                host.onConnectionState(op.profileId, LetterboxdConnectionState.ReconnectionRequired)
                finish(op, LetterboxdOperationStatus.NeedsReconnect, e.category, reconciling = sentBefore, keepWriteSentAt = true)
            }
            is LetterboxdException.Blocked -> {
                host.onConnectionState(op.profileId, LetterboxdConnectionState.TemporarilyUnavailable)
                retryOrFail(op, e, attempts, sentBefore, minDelay = BLOCKED_BACKOFF_MS)
            }
            is LetterboxdException.RateLimited -> retryOrFail(op, e, attempts, sentBefore, minDelay = e.retryAfterMs ?: LetterboxdSession.DEFAULT_RETRY_AFTER_MS)
            is LetterboxdException.Network, is LetterboxdException.Server -> retryOrFail(op, e, attempts, sentBefore)
            is LetterboxdException.FilmNotFound, is LetterboxdException.NotAFilm, is LetterboxdException.Unsupported ->
                finish(op, LetterboxdOperationStatus.Failed, e.category, e.message?.let(::sanitize))
            is LetterboxdException.Unexpected ->
                if (writeStarted) finish(op, LetterboxdOperationStatus.NeedsReconciliation, LetterboxdErrorCategory.Ambiguous, "Unexpected answer to a write; checking the diary", reconciling = true, keepWriteSentAt = true)
                else retryOrFail(op, e, attempts, sentBefore)
        }
    }

    private suspend fun retryOrFail(op: LetterboxdOperation, e: LetterboxdException, attempts: Int, sentBefore: Boolean, minDelay: Long = 0L) {
        if (attempts >= MAX_ATTEMPTS) {
            finish(op, LetterboxdOperationStatus.Failed, e.category, e.message?.let(::sanitize), reconciling = sentBefore, keepWriteSentAt = true); return
        }
        // Still reconciling: the wait is for the diary to be readable again, then the check runs before any write.
        finish(op, LetterboxdOperationStatus.RetryScheduled, e.category, null, nextAttemptAtMs = now() + maxOf(backoffMs(attempts), minDelay), reconciling = sentBefore, keepWriteSentAt = true)
    }

    /** Error text for the history: whatever the site sent, flattened and short. It never carries the member's review. */
    private fun sanitize(text: String): String = text.replace(Regex("\\s+"), " ").take(160)

    // ------------------------------------------------------------------ controls

    /** Puts a stopped operation back in the queue (the member's Retry). An operation that sent a write is still checked first. */
    suspend fun retry(opId: String) = stateLock.withLock {
        _operations.value.firstOrNull { it.id == opId }?.let {
            if (it.status in RETRYABLE) replace(it.copy(status = LetterboxdOperationStatus.Pending, attempts = 0, nextAttemptAtMs = 0, error = LetterboxdErrorCategory.None, note = null))
        }
    }

    /** The session works again: held operations go back in the queue, safely, and the breaker closes. */
    suspend fun onReconnected(profileId: Int) = stateLock.withLock {
        breaker(profileId).reset()
        _operations.value = _operations.value.map {
            if (it.profileId == profileId && it.status == LetterboxdOperationStatus.NeedsReconnect) it.copy(status = LetterboxdOperationStatus.Pending, error = LetterboxdErrorCategory.None, attempts = 0) else it
        }; saveOps()
    }

    /** Disconnecting stops every remote write for the account. [deleteLocal] also removes the profile's local Letterboxd history. */
    suspend fun onDisconnected(profileId: Int, account: String, deleteLocal: Boolean) = stateLock.withLock {
        _operations.value = _operations.value.filterNot { it.profileId == profileId && it.account == account && it.status !in FINISHED }; saveOps()
        synchronized(breakerLock) { breakers.remove(profileId) }
        if (deleteLocal) {
            _viewings.value = _viewings.value.filterNot { it.profileId == profileId }; saveViewings()
            _operations.value = _operations.value.filterNot { it.profileId == profileId }; saveOps()
            _events.value = _events.value.filterNot { it.profileId == profileId }; saveEvents()
        }
        writePushed(readPushed().filterKeys { !it.startsWith(account.lowercase() + "|") })
    }

    /** Removes everything this engine keeps, for every profile (an account wipe or a sign-out of the app). */
    suspend fun wipeEverything() = stateLock.withLock {
        _operations.value = emptyList(); _viewings.value = emptyList(); _events.value = emptyList()
        listOf(OPS_KEY, VIEWINGS_KEY, EVENTS_KEY, PUSHED_KEY, COVERAGE_KEY).forEach { store.write(it, null) }
        synchronized(breakerLock) { breakers.clear() }
    }

    /** What has been watched so far of a film, read without waiting (the player samples about once a second). */
    fun coverageNow(profileId: Int, tmdbId: Int): WatchedCoverage = readCoverages()["$profileId|$tmdbId"] ?: WatchedCoverage()

    /**
     * Adds viewings read from the member's Letterboxd diary. Safe to run again: a viewing with an id already held is skipped,
     * and the ratings read are remembered as already on Letterboxd so they are never sent back. Returns how many were new.
     */
    suspend fun addImported(profileId: Int, account: String, imported: List<LetterboxdViewing>): Int = stateLock.withLock {
        val known = _viewings.value.map { it.id }.toHashSet()
        val fresh = imported.filter { known.add(it.id) }
        if (fresh.isNotEmpty()) { _viewings.value = (_viewings.value + fresh).takeLast(MAX_VIEWINGS); saveViewings() }
        val pushed = readPushed()
        // Newest first: the most recent rated entry of a film is the rating the member has on it now.
        val seen = HashSet<Int>()
        imported.sortedByDescending { it.localDate }.forEach { v -> v.stars?.let { if (seen.add(v.tmdbId)) pushed[pushedKey(account, v.tmdbId)] = it } }
        writePushed(pushed)
        fresh.size
    }

    /** Remembers ratings read from Letterboxd (from the films page) as already there, without making viewings. */
    suspend fun noteRemoteRatings(account: String, ratings: Map<Int, Double>) = stateLock.withLock {
        val pushed = readPushed(); ratings.forEach { (tmdb, stars) -> pushed[pushedKey(account, tmdb)] = stars }; writePushed(pushed)
    }

    /** Records a sync event of the member's own (an import, a check) in the history. */
    fun recordEvent(profileId: Int, account: String, tmdbId: Int, title: String, type: LetterboxdOperationType, status: LetterboxdOperationStatus, note: String?) =
        record(profileId, account, tmdbId, title, type, status, null, LetterboxdErrorCategory.None, note)

    /** Viewings of one film for a profile, newest first. */
    fun viewingsFor(profileId: Int, tmdbId: Int): List<LetterboxdViewing> =
        _viewings.value.filter { it.profileId == profileId && it.tmdbId == tmdbId }.sortedByDescending { it.completedAtMs }

    companion object {
        const val RATING_DEBOUNCE_MS = 10_000L
        const val MAX_ATTEMPTS = 6
        const val MAX_BACKOFF_MS = 30 * 60_000L
        const val BLOCKED_BACKOFF_MS = 15 * 60_000L
        const val RECONCILE_AFTER_MS = 2 * 60_000L
        /** An unconfirmed write is not sent again until this long after it was sent, and only once the diary is readable and lacks it. */
        const val RESEND_AFTER_MS = 10 * 60_000L
        const val STUCK_AFTER_MS = 5 * 60_000L
        private const val MAX_OPS = 400
        private const val MAX_VIEWINGS = 6000
        private const val MAX_EVENTS = 300
        private const val OPS_KEY = "letterboxd_ops_v1"
        private const val VIEWINGS_KEY = "letterboxd_viewings_v1"
        private const val EVENTS_KEY = "letterboxd_events_v1"
        private const val PUSHED_KEY = "letterboxd_rating_pushed_v1"
        private const val COVERAGE_KEY = "letterboxd_coverage_v1"
        private val DIARY_TYPES = setOf(LetterboxdOperationType.CreateDiaryEntry, LetterboxdOperationType.PublishReview)
        private val OPEN_BEFORE_SEND = setOf(LetterboxdOperationStatus.Pending, LetterboxdOperationStatus.RetryScheduled, LetterboxdOperationStatus.NeedsReconnect)
        private val FINISHED = setOf(LetterboxdOperationStatus.Succeeded, LetterboxdOperationStatus.Skipped)
        private val RETRYABLE = setOf(LetterboxdOperationStatus.Failed, LetterboxdOperationStatus.NeedsReconnect, LetterboxdOperationStatus.RetryScheduled, LetterboxdOperationStatus.ActionRequired)
    }
}
