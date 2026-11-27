package com.nuvio.app.features.serializd

import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watched.isEpisode
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * The optional, explicitly started backfill: BannerTV's own watched episodes go to Serializd as watched marks, and, when the member
 * chooses, as dated diary entries for the episodes that have a real watch date. Episodes already on Serializd (sent before, or read
 * from it) are skipped by the engine, so this can never send an import back. Nothing here runs unless the member asks.
 */
internal object SerializdBackfill {
    enum class Range(val label: String, val days: Int?) {
        Month("Last 30 days", 30),
        Year("Last year", 365),
        Everything("Everything", null),
    }

    /** Returns (watched-mark requests queued, dated entries queued, episodes already on Serializd), or null when nothing can be sent. */
    suspend fun run(profileId: Int, range: Range, withDiary: Boolean): Triple<Int, Int, Int>? {
        val manager = SerializdRuntime.manager
        if (manager.accountOf(profileId) == null) return null
        val since = range.days?.let { kotlin.time.Clock.System.now().toEpochMilliseconds() - it * 86_400_000L }
        val items = WatchedRepository.uiState.value.items.filter { item ->
            item.isEpisode && !item.type.equals("movie", ignoreCase = true) && (
                since == null || item.markedAtEpochMs >= since
            )
        }
        if (items.isEmpty()) return Triple(0, 0, 0)
        val showIds = HashMap<String, Int?>()
        items.map { it.id }.distinct().chunked(8).forEach { chunk ->
            coroutineScope { chunk.map { id -> async { id to SerializdRuntime.showTmdbId(id) } }.awaitAll() }.forEach { (id, tmdb) -> showIds[id] = tmdb }
        }
        val episodes = items.mapNotNull { item ->
            val show = showIds[item.id] ?: return@mapNotNull null
            val season = item.season ?: return@mapNotNull null
            val episode = item.episode ?: return@mapNotNull null
            // A date is only passed on when it is a real one: the placeholder for "date unknown" never becomes a diary date.
            SerializdBackfillEpisode(show, item.name, season, episode, item.markedAtEpochMs.takeIf { it >= SerializdSyncEngine.PLAUSIBLE_WATCH_DATE_MS })
        }
        return manager.backfill(profileId, episodes, withDiary)
    }
}
