package com.nuvio.app.features.watchprogress

import com.nuvio.app.core.logging.InAppLogger
import com.nuvio.app.features.downloads.SmartDownloadsCoordinator
import com.nuvio.app.features.player.PlayerPlaybackSnapshot
import com.nuvio.app.features.player.skip.SkipInterval
import com.nuvio.app.features.player.skip.toPlaybackSegment
import com.nuvio.app.features.playback.CompletionLedger
import com.nuvio.app.features.playback.CompletionRecord
import com.nuvio.app.features.playback.CoverageStore
import com.nuvio.app.features.playback.PlaybackFeatureFlags
import com.nuvio.app.features.playback.PlaybackSegments
import com.nuvio.app.features.playback.PlaybackSessionTracker
import com.nuvio.app.features.playback.PlaybackStateStore
import com.nuvio.app.features.tmdb.CoreKeyValue
import com.nuvio.app.features.watching.domain.isProgressComplete

/**
 * The app's one live view of the unified completion policy. The player feeds it a sample about once a second; it keeps one
 * [PlaybackSessionTracker] per title being played, persists what really played, and records a completion once.
 *
 * Until `PlaybackFeatureFlags.unifiedCompletion` is switched on it only observes: the old 90% rule still decides, and any
 * disagreement between the two is written to the in-app log so the policy's defaults can be tuned on real playback.
 */
internal object PlaybackCompletionRuntime {
    private object CoreStore : PlaybackStateStore {
        override fun get(store: String, key: String): String? = CoreKeyValue.getString(store, key)
        override fun put(store: String, key: String, value: String) = CoreKeyValue.putString(store, key, value)
    }

    private val ledger by lazy { CompletionLedger(CoreStore) }
    private val coverageStore by lazy { CoverageStore(CoreStore) }

    private class Active(
        val identity: String,
        val profileId: Int,
        val mediaKey: String,
        val episodeKey: String?,
        val tracker: PlaybackSessionTracker,
    ) {
        var lastPersistMs = 0L
        var lastDivergence: Pair<Boolean, Boolean>? = null
    }

    private var active: Active? = null

    private fun mediaKeyOf(session: WatchProgressPlaybackSession): String? {
        if (session.parentMetaId.isBlank()) return null
        val kind = when (session.parentMetaType.lowercase()) {
            "movie" -> "movie"
            "series", "tv", "show" -> "series"
            else -> return null // live TV, channels, anything that is not a title with a finish line
        }
        return "$kind:${session.parentMetaId}"
    }

    private fun episodeKeyOf(session: WatchProgressPlaybackSession): String? {
        val s = session.seasonNumber; val e = session.episodeNumber
        return if (s != null && e != null) "s${s}e$e" else null
    }

    private fun activeFor(session: WatchProgressPlaybackSession): Active? {
        val mediaKey = mediaKeyOf(session) ?: return null
        val episodeKey = episodeKeyOf(session)
        val identity = "${session.profileId}|$mediaKey|${episodeKey ?: "-"}"
        active?.takeIf { it.identity == identity }?.let { return it }
        active?.let { persist(it) }
        val tracker = PlaybackSessionTracker(
            sessionId = "${WatchProgressClock.nowEpochMs()}-${identity.hashCode()}",
            profileId = session.profileId,
            mediaKey = mediaKey,
            episodeKey = episodeKey,
            viewingIndex = ledger.nextViewingIndex(session.profileId, mediaKey, episodeKey),
            initialCoverage = coverageStore.load(session.profileId, mediaKey, episodeKey),
        )
        return Active(identity, session.profileId, mediaKey, episodeKey, tracker).also { active = it }
    }

    /** One sample from the player (about once a second). Cheap when the session is not a title. */
    fun onSnapshot(session: WatchProgressPlaybackSession, snapshot: PlayerPlaybackSnapshot, skipIntervals: List<SkipInterval>) {
        val a = activeFor(session) ?: return
        val duration = snapshot.durationMs
        a.tracker.updateSegments(
            PlaybackSegments.validFor(skipIntervals.mapNotNull { it.toPlaybackSegment() }, duration),
        )
        val now = WatchProgressClock.nowEpochMs()
        val event = a.tracker.onSample(snapshot.positionMs, duration, snapshot.isPlaying, snapshot.isEnded, now)

        // Shadow comparison: record when the policy and the old rule disagree (once per change, never every second).
        val legacy = isProgressComplete(snapshot.positionMs, duration, snapshot.isEnded)
        val unified = event != null || a.tracker.assess(snapshot.positionMs, duration, snapshot.isEnded).completes
        if (legacy != unified && a.lastDivergence != (legacy to unified)) {
            a.lastDivergence = legacy to unified
            InAppLogger.info(
                "Player/Completion",
                "policy=$unified legacy=$legacy media=${a.mediaKey} ep=${a.episodeKey ?: "-"} pos=${snapshot.positionMs / 1000}s " +
                    "dur=${duration / 1000}s coverage=${(a.tracker.coverage.fraction(duration) * 100).toInt()}%",
            )
        }

        if (event != null) {
            when (ledger.record(event)) {
                is CompletionRecord.Recorded -> {
                    InAppLogger.info("Player/Completion", "completed ${event.mediaKey} ${event.episodeKey ?: ""} reason=${event.reason} viewing=${event.viewingIndex}")
                    // The next viewing starts from nothing.
                    coverageStore.clear(a.profileId, a.mediaKey, a.episodeKey)
                    // Download Next Episode reacts to the same event, not to a percentage of its own.
                    if (a.episodeKey != null && a.mediaKey.startsWith("series:")) {
                        SmartDownloadsCoordinator.onEpisodeCompleted(a.mediaKey.removePrefix("series:"))
                    }
                }
                is CompletionRecord.Duplicate -> Unit
            }
        } else if (now - a.lastPersistMs > PERSIST_INTERVAL_MS) {
            persist(a)
        }
    }

    /**
     * The policy's verdict for [session], or null when the old rule should decide (flag off, not a title, or no samples yet).
     * Called where progress is saved, so with the flag on a drag to 90% no longer completes a title.
     */
    fun verdictFor(session: WatchProgressPlaybackSession, snapshot: PlayerPlaybackSnapshot): Boolean? {
        if (!PlaybackFeatureFlags.unifiedCompletion) return null
        val a = active?.takeIf { mediaKeyOf(session) != null && it.identity.startsWith("${session.profileId}|${mediaKeyOf(session)}|") } ?: return null
        return a.tracker.assess(snapshot.positionMs, snapshot.durationMs, snapshot.isEnded).completes
    }

    /** Saves what has really played. Called when progress is flushed (pause, end, leaving the player). */
    fun flush() { active?.let { persist(it) } }

    private fun persist(a: Active) {
        a.lastPersistMs = WatchProgressClock.nowEpochMs()
        coverageStore.save(a.profileId, a.mediaKey, a.episodeKey, a.tracker.coverage)
    }

    private const val PERSIST_INTERVAL_MS = 30_000L
}
