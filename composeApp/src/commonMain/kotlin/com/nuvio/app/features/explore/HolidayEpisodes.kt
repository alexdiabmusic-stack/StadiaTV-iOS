package com.nuvio.app.features.explore

import com.nuvio.app.features.watched.watchedItemKeys
import kotlin.random.Random

/**
 * One verified episode of a curated episode collection (Christmas Episodes, Halloween Episodes). Every entry was
 * matched against TMDB by season, episode number and title by scripts/holiday-episodes/resolve_holiday_episodes.py,
 * which generates [HOLIDAY_EPISODE_COLLECTIONS]; unverified entries never reach the app.
 */
data class HolidayEpisode(
    val seriesTmdbId: Int,
    val seriesImdbId: String?,
    val seriesName: String,
    val season: Int,
    val episode: Int,
    val episodeTmdbId: Int,
    val title: String,
    val airDate: String,
    val still: String?,
    val seasonPoster: String?,
    val seriesBackdrop: String?,
    val seriesPoster: String?,
    val runtime: Int?,
    val overview: String,
) {
    val key: String get() = "$seriesTmdbId:$season:$episode"

    /** The id the rest of the app knows the series by (IMDb when known, as the watch history and addons use). */
    val seriesAppId: String get() = seriesImdbId ?: "tmdb:$seriesTmdbId"

    /** "S2 · E10" */
    val code: String get() = "S$season · E$episode"

    /** The episode's own still, else the season's artwork, else the series' backdrop. */
    fun artwork(size: String = "w780"): String? =
        (still ?: seasonPoster ?: seriesBackdrop)?.let { "https://image.tmdb.org/t/p/$size$it" }

    fun seriesPosterUrl(): String? = seriesPoster?.let { "https://image.tmdb.org/t/p/w500$it" }
    fun backdropUrl(): String? = seriesBackdrop?.let { "https://image.tmdb.org/t/p/w1280$it" }
}

/** Opening and playing an episode, provided by the app shell (the same episode playback every screen uses). */
object ExploreEpisodeActions {
    var play: ((HolidayEpisode) -> Unit)? = null
    var openDetails: ((HolidayEpisode) -> Unit)? = null
}

object HolidayEpisodes {
    enum class Sort(val label: String) { Featured("Featured"), BySeries("By Show"), Newest("Newest"), Oldest("Oldest") }
    enum class WatchFilter(val label: String) { All("All"), Unwatched("Unwatched"), Watched("Watched") }

    /** The collection's episodes, each once. */
    fun of(collectionId: String): List<HolidayEpisode> =
        HOLIDAY_EPISODE_COLLECTIONS[collectionId].orEmpty().distinctBy { it.seriesTmdbId to it.episodeTmdbId }

    fun isWatched(ep: HolidayEpisode, watchedKeys: Set<String>): Boolean =
        listOf(ep.seriesAppId, "tmdb:${ep.seriesTmdbId}").any { id ->
            watchedItemKeys("series", id, ep.season, ep.episode).any(watchedKeys::contains)
        }

    /**
     * The featured order: one episode from each show in turn, so no show fills the first screen. The order of the shows
     * and which of each show's episodes leads both move on week by week, and stay put within a week.
     */
    fun featured(episodes: List<HolidayEpisode>, week: Long): List<HolidayEpisode> {
        val random = Random(week * 31 + 7)
        val bySeries = episodes.groupBy { it.seriesTmdbId }.mapValues { (_, list) ->
            val sorted = list.sortedWith(compareBy({ it.season }, { it.episode }))
            val shift = week.mod(sorted.size.toLong()).toInt()
            sorted.drop(shift) + sorted.take(shift)
        }
        val seriesOrder = bySeries.keys.sorted().shuffled(random)
        val longest = bySeries.values.maxOfOrNull { it.size } ?: 0
        return (0 until longest).flatMap { round -> seriesOrder.mapNotNull { bySeries.getValue(it).getOrNull(round) } }
    }

    fun sorted(episodes: List<HolidayEpisode>, sort: Sort, week: Long): List<HolidayEpisode> = when (sort) {
        Sort.Featured -> featured(episodes, week)
        Sort.BySeries -> episodes.sortedWith(compareBy({ it.seriesName }, { it.season }, { it.episode }))
        Sort.Newest -> episodes.sortedByDescending { it.airDate }
        Sort.Oldest -> episodes.sortedBy { it.airDate }
    }

    fun filtered(
        episodes: List<HolidayEpisode>,
        series: Int?,
        watch: WatchFilter,
        watchedKeys: Set<String>,
    ): List<HolidayEpisode> = episodes.filter { ep ->
        (series == null || ep.seriesTmdbId == series) && when (watch) {
            WatchFilter.All -> true
            WatchFilter.Unwatched -> !isWatched(ep, watchedKeys)
            WatchFilter.Watched -> isWatched(ep, watchedKeys)
        }
    }

    /** A random episode from what's on screen (all of it verified); null when nothing matches the filters. */
    fun random(episodes: List<HolidayEpisode>, random: Random = Random.Default): HolidayEpisode? =
        episodes.takeIf { it.isNotEmpty() }?.random(random)
}
