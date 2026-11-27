package com.nuvio.app.mac

import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaVideo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/** A Continue Watching card: either a title to resume or the next episode of a series. */
class MacContinueItem(
    val contentId: String,
    val contentType: String,
    val name: String,
    val poster: String?,
    val background: String?,
    val logo: String?,
    val videoId: String,
    val season: Int?,
    val episode: Int?,
    val episodeTitle: String?,
    val positionMs: Long,
    val durationMs: Long,
    val isNextUp: Boolean,
    val lastWatched: Long,
) {
    val fraction: Double get() = if (durationMs > 0) positionMs.toDouble() / durationMs else 0.0
}

/**
 * Builds the Continue Watching row from the account's watch progress: resumable movies and episodes, and, when an
 * episode was finished, the next released one. Titles' artwork and episode lists come from the installed add-ons.
 */
object MacContinue {
    private val scope = macScope()
    private const val LIMIT = 20

    fun watch(onChange: (List<MacContinueItem>) -> Unit): MacWatch = MacWatch(scope.launch {
        combine(MacAccountData.progress, MacAccountData.watched) { progress, watched -> progress to watched }
            .mapLatest { (progress, watched) -> build(progress, watched) }
            .collect { onChange(it) }
    })

    private fun today(): String = kotlin.time.Clock.System.now().toString().take(10)

    private suspend fun build(progress: List<MacProgress>, watched: List<MacWatched>): List<MacContinueItem> {
        val latestPerTitle = progress.groupBy { it.contentId }.values
            .map { rows -> rows.maxBy { it.lastWatched } }
            .sortedByDescending { it.lastWatched }
            .take(LIMIT * 2)
        val permits = Semaphore(4)
        val watchedKeys = watched.map { it.key }.toSet()
        val built = coroutineScope {
            latestPerTitle.map { entry ->
                async {
                    permits.withPermit {
                        val isSeries = entry.contentType != "movie"
                        val needsMeta = true
                        val meta = if (needsMeta) MacContent.metaFor(entry.contentType, entry.contentId) else null
                        item(entry, meta, isSeries, watchedKeys)
                    }
                }
            }.awaitAll()
        }
        return built.filterNotNull().sortedByDescending { it.lastWatched }.take(LIMIT)
    }

    private fun item(entry: MacProgress, meta: MetaDetails?, isSeries: Boolean, watchedKeys: Set<String>): MacContinueItem? {
        val name = meta?.name ?: return null
        if (!entry.isComplete) {
            val episodeTitle = meta.videos.firstOrNull { it.season?.toInt() == entry.season && it.episode?.toInt() == entry.episode }?.title
            return make(entry, meta, entry.videoId, entry.season, entry.episode, episodeTitle, entry.position, entry.duration, nextUp = false)
        }
        if (!isSeries) return null
        val next = nextEpisode(meta.videos, entry.season, entry.episode, watchedKeys, meta.id) ?: return null
        return make(entry, meta, next.id, next.season, next.episode, next.title, 0, 0, nextUp = true)
    }

    private fun make(
        entry: MacProgress, meta: MetaDetails, videoId: String, season: Int?, episode: Int?, episodeTitle: String?,
        position: Long, duration: Long, nextUp: Boolean,
    ) = MacContinueItem(
        contentId = entry.contentId, contentType = entry.contentType, name = meta.name, poster = meta.poster,
        background = meta.background ?: meta.poster, logo = meta.logo, videoId = videoId, season = season, episode = episode,
        episodeTitle = episodeTitle, positionMs = position, durationMs = duration, isNextUp = nextUp, lastWatched = entry.lastWatched,
    )

    private fun nextEpisode(videos: List<MetaVideo>, season: Int?, episode: Int?, watchedKeys: Set<String>, contentId: String): MetaVideo? {
        if (season == null || episode == null) return null
        val now = today()
        return videos
            .filter { it.season != null && it.episode != null && it.season.toInt() > 0 }
            .sortedWith(compareBy({ it.season!!.toInt() }, { it.episode!!.toInt() }))
            .firstOrNull { v ->
                val s = v.season!!.toInt(); val e = v.episode!!.toInt()
                (s > season || (s == season && e > episode)) &&
                    v.available && (v.released?.take(10)?.let { it <= now } ?: true) &&
                    progressKey(contentId, s, e) !in watchedKeys
            }
    }
}
