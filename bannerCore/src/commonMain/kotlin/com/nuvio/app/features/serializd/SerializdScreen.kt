package com.nuvio.app.features.serializd

/**
 * Everything the Serializd settings screens show, decided once here so the phone apps, the Mac app and the TV app read the same state
 * and say the same words. The platforms only draw it and call the manager's actions; none of them works out a status line itself.
 */
enum class SerializdTone { Good, Neutral, Warning, Problem }

/** The device's offset from UTC at a moment, for wording a time as "today at 2:59 PM". Each platform supplies its own. */
fun interface SerializdClock {
    fun utcOffsetMs(atMs: Long): Long
}

data class SerializdScreenState(
    /** Null when no account is connected: the screen shows the sign-in form. */
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
    val trackEpisodes: Boolean,
    val syncRatings: Boolean,
    /** On only when the watchlist is both read and added to My List. */
    val syncWatchlist: Boolean,
    val trackedEpisodes: Int,
    val watchHistoryLine: String,
    val watchlistLine: String,
    /** One short sentence about the last import, or null when none has run. */
    val importLine: String?,
    val importStats: SerializdImportStats?,
    val setupPending: Boolean,
    /** The stored preferences, untouched, for the advanced page. */
    val settings: SerializdSettings,
) {
    val connected: Boolean get() = username != null
}

object SerializdScreenText {
    private val WAITING = setOf(
        SerializdOperationStatus.Pending, SerializdOperationStatus.InProgress, SerializdOperationStatus.RetryScheduled, SerializdOperationStatus.ReconciliationRequired,
    )
    private val STOPPED = setOf(SerializdOperationStatus.FailedPermanent, SerializdOperationStatus.NeedsReconnect, SerializdOperationStatus.ActionRequired)

    fun build(
        profileId: Int,
        account: SerializdAccount?,
        connection: SerializdConnectionState,
        settings: SerializdSettings,
        operations: List<SerializdOperation>,
        events: List<SerializdSyncEvent>,
        trackedEpisodes: Int,
        watchlist: SerializdWatchlistSnapshot?,
        importStatus: String?,
        syncing: Boolean,
        nowMs: Long,
        clock: SerializdClock,
    ): SerializdScreenState {
        val pending = operations.count { it.profileId == profileId && it.status in WAITING }
        val failed = operations.count { it.profileId == profileId && it.status in STOPPED }
        val syncWatchlist = settings.importWatchlist && settings.watchlistToLibrary
        val base = SerializdScreenState(
            username = account?.username, connectionLabel = "Not connected", connectionTone = SerializdTone.Neutral,
            syncHeadline = "", syncDetail = null, syncTone = SerializdTone.Neutral, busy = false, needsReconnect = false,
            pendingCount = pending, failedCount = failed,
            trackEpisodes = settings.autoTrackEpisodes, syncRatings = settings.syncRatings, syncWatchlist = syncWatchlist,
            trackedEpisodes = trackedEpisodes, watchHistoryLine = trackedLine(trackedEpisodes),
            watchlistLine = watchlist?.let { shows(it.entries.size) } ?: if (settings.importWatchlist) "Not read yet" else "Not synced",
            importLine = account?.lastImportStats?.let(::importSentence),
            importStats = account?.lastImportStats,
            setupPending = account?.setupPending == true,
            settings = settings,
        )
        if (account == null) return base
        val lastContact = maxOf(
            account.lastValidatedAtMs, account.lastImportAtMs, account.lastWatchlistAtMs,
            events.filter { it.profileId == profileId && it.status == SerializdOperationStatus.Synced }.maxOfOrNull { it.atMs } ?: 0L,
        )
        val lastLine = if (lastContact > 0) "Last synced ${describeTime(lastContact, nowMs, clock)}" else "Nothing synced yet"
        return when {
            connection == SerializdConnectionState.SessionExpired || connection == SerializdConnectionState.ReconnectionRequired -> base.copy(
                connectionLabel = "Sign in again", connectionTone = SerializdTone.Problem, needsReconnect = true,
                syncHeadline = "Syncing is paused",
                syncDetail = if (connection == SerializdConnectionState.SessionExpired) "Your Serializd sign-in expired." else "Serializd no longer accepts the saved sign-in.",
                syncTone = SerializdTone.Problem,
            )
            connection == SerializdConnectionState.TemporarilyUnavailable -> base.copy(
                connectionLabel = "Serializd is unavailable", connectionTone = SerializdTone.Warning,
                syncHeadline = "Can't reach Serializd right now", syncDetail = "BannerTV will try again later. $lastLine", syncTone = SerializdTone.Warning,
                busy = syncing || importStatus != null,
            )
            syncing || importStatus != null -> base.copy(
                connectionLabel = "Connected to Serializd", connectionTone = SerializdTone.Good,
                syncHeadline = importStatus ?: "Syncing…", syncDetail = null, syncTone = SerializdTone.Neutral, busy = true,
            )
            failed > 0 -> base.copy(
                connectionLabel = "Connected to Serializd", connectionTone = SerializdTone.Good,
                syncHeadline = if (failed == 1) "1 item needs attention" else "$failed items need attention",
                syncDetail = "Retry them from Advanced settings. $lastLine", syncTone = SerializdTone.Warning,
            )
            pending > 0 -> base.copy(
                connectionLabel = "Connected to Serializd", connectionTone = SerializdTone.Good,
                syncHeadline = if (pending == 1) "1 item waiting to send" else "$pending items waiting to send",
                syncDetail = lastLine, syncTone = SerializdTone.Neutral,
            )
            else -> base.copy(
                connectionLabel = "Connected to Serializd", connectionTone = SerializdTone.Good,
                syncHeadline = "Everything is up to date", syncDetail = lastLine, syncTone = SerializdTone.Good,
            )
        }
    }

    fun trackedLine(episodes: Int): String = when (episodes) {
        0 -> "Nothing tracked yet"
        1 -> "1 episode tracked"
        else -> "${grouped(episodes)} episodes tracked"
    }

    fun shows(count: Int): String = if (count == 1) "1 show" else "${grouped(count)} shows"

    /** The short sentence for the main screen. The numbers behind it are in the details view. */
    fun importSentence(stats: SerializdImportStats): String {
        val episodes = if (stats.added == 1) "1 episode" else "${grouped(stats.added)} episodes"
        val unmatched = if (stats.unmatched > 0) " ${grouped(stats.unmatched)} couldn't be matched." else ""
        return when {
            stats.partial -> "Import stopped early. Run it again to continue."
            stats.added > 0 -> "$episodes imported successfully.$unmatched"
            stats.unmatched > 0 -> "Nothing new to import.$unmatched"
            else -> "Nothing new to import. Everything is already here."
        }
    }

    /** "today at 2:59 PM", "yesterday at 9:05 AM", "Nov 21 at 8:00 PM", or with the year when it is not this one. */
    fun describeTime(atMs: Long, nowMs: Long, clock: SerializdClock): String {
        val local = atMs + clock.utcOffsetMs(atMs)
        val nowLocal = nowMs + clock.utcOffsetMs(nowMs)
        val day = local.floorDiv(DAY_MS)
        val today = nowLocal.floorDiv(DAY_MS)
        val minutes = (local.mod(DAY_MS) / 60_000L).toInt()
        val hour24 = minutes / 60
        val clockText = "${if (hour24 % 12 == 0) 12 else hour24 % 12}:${(minutes % 60).toString().padStart(2, '0')} ${if (hour24 < 12) "AM" else "PM"}"
        return when (today - day) {
            0L -> "today at $clockText"
            1L -> "yesterday at $clockText"
            else -> {
                val (year, month, dayOfMonth) = civil(day)
                val (nowYear, _, _) = civil(today)
                "${MONTHS[month - 1]} $dayOfMonth${if (year != nowYear) ", $year" else ""} at $clockText"
            }
        }
    }

    /** 6506 -> "6,506". */
    fun grouped(n: Int): String {
        val s = kotlin.math.abs(n).toString()
        val out = StringBuilder()
        s.forEachIndexed { i, c -> if (i > 0 && (s.length - i) % 3 == 0) out.append(','); out.append(c) }
        return (if (n < 0) "-" else "") + out
    }

    private const val DAY_MS = 86_400_000L
    private val MONTHS = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

    /** Days since 1970-01-01 to (year, month, day), by Howard Hinnant's civil-from-days. */
    private fun civil(daysSinceEpoch: Long): Triple<Int, Int, Int> {
        val z = daysSinceEpoch + 719_468
        val era = z.floorDiv(146_097L)
        val doe = z - era * 146_097
        val yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = (doy - (153 * mp + 2) / 5 + 1).toInt()
        val m = (if (mp < 10) mp + 3 else mp - 9).toInt()
        val y = (yoe + era * 400 + if (m <= 2) 1 else 0).toInt()
        return Triple(y, m, d)
    }
}
