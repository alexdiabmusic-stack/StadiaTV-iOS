package com.nuvio.app.features.letterboxd

import com.nuvio.app.features.serializd.SerializdClock
import com.nuvio.app.features.serializd.SerializdScreenText
import com.nuvio.app.features.serializd.SerializdTone

/**
 * Everything the Letterboxd settings screens show, decided once here, in the same shape and with the same words as Serializd's
 * (`SerializdScreenState`), so the two integrations' pages look and read alike. The tone, clock and time wording are Serializd's own
 * shared helpers; nothing here is specific to a platform.
 */
data class LetterboxdScreenState(
    /** Null when no account is connected: the screen shows the sign-in step. */
    val username: String?,
    val connectionLabel: String,
    val connectionTone: SerializdTone,
    val syncHeadline: String,
    val syncDetail: String?,
    val syncTone: SerializdTone,
    /** A sync or an import is running: Sync now and Import are not offered again until it ends. */
    val busy: Boolean,
    val needsReconnect: Boolean,
    val pendingCount: Int,
    val failedCount: Int,
    val logFilms: Boolean,
    val syncRatings: Boolean,
    val syncWatchlist: Boolean,
    /** Films in the Watch Journal (finished in BannerTV or imported). */
    val journalFilms: Int,
    val watchHistoryLine: String,
    val watchlistLine: String,
    /** The stored preferences, untouched, for the advanced page. */
    val settings: LetterboxdSettings,
) {
    val connected: Boolean get() = username != null
}

object LetterboxdScreenText {
    private val WAITING = setOf(
        LetterboxdOperationStatus.Pending, LetterboxdOperationStatus.InProgress, LetterboxdOperationStatus.RetryScheduled, LetterboxdOperationStatus.NeedsReconciliation,
    )
    /** Held or stopped: the member may want to act (retry, reconnect, decide). */
    val STOPPED = setOf(LetterboxdOperationStatus.Failed, LetterboxdOperationStatus.NeedsReconnect, LetterboxdOperationStatus.ActionRequired)

    fun build(
        profileId: Int,
        account: LetterboxdAccount?,
        connection: LetterboxdConnectionState,
        settings: LetterboxdSettings,
        operations: List<LetterboxdOperation>,
        events: List<LetterboxdSyncEvent>,
        journalFilms: Int,
        watchlist: LetterboxdWatchlistSnapshot?,
        importStatus: String?,
        syncing: Boolean,
        nowMs: Long,
        clock: SerializdClock,
    ): LetterboxdScreenState {
        val pending = operations.count { it.profileId == profileId && it.status in WAITING }
        val failed = operations.count { it.profileId == profileId && it.status in STOPPED }
        val base = LetterboxdScreenState(
            username = account?.username, connectionLabel = "Not connected", connectionTone = SerializdTone.Neutral,
            syncHeadline = "", syncDetail = null, syncTone = SerializdTone.Neutral, busy = false, needsReconnect = false,
            pendingCount = pending, failedCount = failed,
            logFilms = settings.autoLogMovies, syncRatings = settings.syncRatings, syncWatchlist = settings.watchlistToLibrary,
            journalFilms = journalFilms, watchHistoryLine = journalLine(journalFilms),
            watchlistLine = watchlist?.let { films(it.films.size) } ?: if (settings.watchlistToLibrary) "Not read yet" else "Not synced",
            settings = settings,
        )
        if (account == null) return base
        val lastContact = maxOf(
            account.lastValidatedAtMs, account.lastWatchlistAtMs,
            events.filter { it.profileId == profileId && it.status == LetterboxdOperationStatus.Succeeded }.maxOfOrNull { it.atMs } ?: 0L,
        )
        val lastLine = if (lastContact > 0) "Last synced ${SerializdScreenText.describeTime(lastContact, nowMs, clock)}" else "Nothing synced yet"
        return when {
            connection == LetterboxdConnectionState.SessionExpired || connection == LetterboxdConnectionState.ReconnectionRequired -> base.copy(
                connectionLabel = "Sign in again", connectionTone = SerializdTone.Problem, needsReconnect = true,
                syncHeadline = "Syncing is paused",
                syncDetail = if (connection == LetterboxdConnectionState.SessionExpired) "Your Letterboxd sign-in expired." else "Letterboxd no longer accepts the saved sign-in.",
                syncTone = SerializdTone.Problem,
            )
            connection == LetterboxdConnectionState.TemporarilyUnavailable -> base.copy(
                connectionLabel = "Letterboxd is unavailable", connectionTone = SerializdTone.Warning,
                syncHeadline = "Can't reach Letterboxd right now", syncDetail = "BannerTV will try again later. $lastLine", syncTone = SerializdTone.Warning,
                busy = syncing || importStatus != null,
            )
            syncing || importStatus != null -> base.copy(
                connectionLabel = "Connected to Letterboxd", connectionTone = SerializdTone.Good,
                syncHeadline = importStatus ?: "Syncing…", syncDetail = null, syncTone = SerializdTone.Neutral, busy = true,
            )
            failed > 0 -> base.copy(
                connectionLabel = "Connected to Letterboxd", connectionTone = SerializdTone.Good,
                syncHeadline = if (failed == 1) "1 item needs attention" else "$failed items need attention",
                syncDetail = "Retry them from Advanced settings. $lastLine", syncTone = SerializdTone.Warning,
            )
            pending > 0 -> base.copy(
                connectionLabel = "Connected to Letterboxd", connectionTone = SerializdTone.Good,
                syncHeadline = if (pending == 1) "1 item waiting to send" else "$pending items waiting to send",
                syncDetail = lastLine, syncTone = SerializdTone.Neutral,
            )
            else -> base.copy(
                connectionLabel = "Connected to Letterboxd", connectionTone = SerializdTone.Good,
                syncHeadline = "Everything is up to date", syncDetail = lastLine, syncTone = SerializdTone.Good,
            )
        }
    }

    fun journalLine(films: Int): String = when (films) {
        0 -> "Nothing logged yet"
        1 -> "1 film in your journal"
        else -> "${SerializdScreenText.grouped(films)} films in your journal"
    }

    fun films(count: Int): String = if (count == 1) "1 film" else "${SerializdScreenText.grouped(count)} films"

    /** The short sentence for the main screen after an import, in the same words as Serializd's. */
    fun importSentence(films: Int, couldNotIdentify: Int, partial: Boolean, message: String? = null): String {
        val unmatched = if (couldNotIdentify > 0) " ${SerializdScreenText.grouped(couldNotIdentify)} couldn't be matched." else ""
        return when {
            partial && films == 0 && message != null -> message
            partial -> "Import stopped early. Run it again to continue."
            films > 0 -> "${films(films)} imported successfully.$unmatched"
            couldNotIdentify > 0 -> "Nothing new to import.$unmatched"
            else -> "Nothing new to import. Everything is already here."
        }
    }
}
