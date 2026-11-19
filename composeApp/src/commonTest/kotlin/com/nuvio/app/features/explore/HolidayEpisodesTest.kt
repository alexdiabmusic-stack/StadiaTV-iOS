package com.nuvio.app.features.explore

import com.nuvio.app.features.watched.watchedItemKeys
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HolidayEpisodesTest {
    private val christmas = HolidayEpisodes.of("christmas-episodes")
    private val halloween = HolidayEpisodes.of("halloween-episodes")

    @Test
    fun verifiedCatalogsAreLoaded() {
        assertEquals(107, christmas.size)
        assertEquals(102, halloween.size)
    }

    @Test
    fun noDuplicateEpisodes() {
        listOf(christmas, halloween).forEach { list ->
            assertEquals(list.size, list.map { it.seriesTmdbId to it.episodeTmdbId }.toSet().size)
            assertEquals(list.size, list.map { it.key }.toSet().size)
        }
    }

    @Test
    fun everyEpisodeCanBePlayedAndHasArtwork() {
        (christmas + halloween).forEach { ep ->
            assertTrue(ep.seriesImdbId?.startsWith("tt") == true, "${ep.seriesName} has no IMDb id")
            assertTrue(ep.artwork() != null, "${ep.seriesName} ${ep.code} has no artwork")
        }
    }

    @Test
    fun featuredFirstScreenRotatesShows() {
        val first = HolidayEpisodes.featured(christmas, week = 2967).take(8)
        assertEquals(8, first.map { it.seriesTmdbId }.toSet().size, first.map { it.seriesName }.toString())
    }

    @Test
    fun featuredIsStableWithinAWeekAndMovesOn() {
        assertEquals(HolidayEpisodes.featured(christmas, 2967), HolidayEpisodes.featured(christmas, 2967))
        assertNotEquals(HolidayEpisodes.featured(christmas, 2967).take(5), HolidayEpisodes.featured(christmas, 2968).take(5))
        assertEquals(christmas.toSet(), HolidayEpisodes.featured(christmas, 2968).toSet())
    }

    @Test
    fun watchedStateFollowsTheProfileHistory() {
        val ep = christmas.first { it.seriesName == "Friends" }
        val keys = watchedItemKeys("series", ep.seriesAppId, ep.season, ep.episode)
        assertTrue(HolidayEpisodes.isWatched(ep, keys))
        val unwatched = HolidayEpisodes.filtered(christmas, null, HolidayEpisodes.WatchFilter.Unwatched, keys)
        assertTrue(ep !in unwatched)
        assertEquals(listOf(ep), HolidayEpisodes.filtered(christmas, null, HolidayEpisodes.WatchFilter.Watched, keys))
    }

    @Test
    fun showFilterAndRandomUseOnlyWhatIsShown() {
        val simpsons = christmas.first { it.seriesName == "The Simpsons" }.seriesTmdbId
        val shown = HolidayEpisodes.filtered(christmas, simpsons, HolidayEpisodes.WatchFilter.All, emptySet())
        assertTrue(shown.isNotEmpty() && shown.all { it.seriesTmdbId == simpsons })
        repeat(20) { i -> assertTrue(HolidayEpisodes.random(shown, Random(i)) in shown) }
        assertNull(HolidayEpisodes.random(emptyList()))
    }

    @Test
    fun sortsKeepEveryEpisode() {
        HolidayEpisodes.Sort.entries.forEach { s -> assertEquals(christmas.toSet(), HolidayEpisodes.sorted(christmas, s, 1).toSet()) }
        val newest = HolidayEpisodes.sorted(christmas, HolidayEpisodes.Sort.Newest, 1)
        assertTrue(newest.zipWithNext().all { (a, b) -> a.airDate >= b.airDate })
    }
}
