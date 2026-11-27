package com.nuvio.app.features.explore

import com.nuvio.app.features.recommendations.TasteProfile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class ExploreSelectionTest {
    private val noTaste = TasteProfile.EMPTY
    private fun taste(vararg genres: Pair<Int, Double>) =
        TasteProfile(genres.toMap(), emptyMap(), emptyMap(), emptyMap(), seriesShare = 0.3)

    @Test
    fun sameWeekGivesTheSameRail() {
        assertEquals(
            ExploreSelection.forHome(noTaste, month = 3, week = 2900).map { it.id },
            ExploreSelection.forHome(noTaste, month = 3, week = 2900).map { it.id },
        )
    }

    @Test
    fun railMovesOnOverTheWeeks() {
        val rails = (2900L..2907L).map { week -> ExploreSelection.forHome(noTaste, month = 3, week = week).map { it.id } }
        assertTrue(rails.toSet().size > 1, "eight weeks in a row gave the identical rail")
    }

    @Test
    fun railHasAtMostTenAndRespectsCategoryCaps() {
        (1..12).forEach { month ->
            val rail = ExploreSelection.forHome(noTaste, month, week = 2901)
            assertTrue(rail.size <= ExploreSelection.HOME_COUNT)
            rail.groupBy { it.category }.forEach { (category, list) ->
                // Seasonal collections may take up to four places while they are in season.
                val cap = when (category) { CollectionCategory.Featured -> 7; CollectionCategory.Seasonal -> 4; else -> 2 }
                assertTrue(list.size <= cap, "$category has ${list.size} in month $month")
            }
        }
    }

    @Test
    fun christmasIsPromotedInDecemberAndHiddenInJune() {
        assertTrue(ExploreSelection.forHome(noTaste, month = 12, week = 2950).any { it.id == "christmas-classics" })
        assertFalse(ExploreSelection.forHome(noTaste, month = 6, week = 2950).any { it.months.isNotEmpty() && 6 !in it.months })
    }

    @Test
    fun superheroFanSeesMovieUniverses() {
        // Action, Sci-Fi and Adventure dominate this taste.
        val fan = taste(28 to 1.0, 878 to 0.9, 12 to 0.8)
        (2900L..2905L).forEach { week ->
            assertTrue(ExploreSelection.forHome(fan, month = 3, week = week).any { it.id == "movie-universes" }, "week $week")
        }
    }

    @Test
    fun sitcomFanSeesComedyCollections() {
        val fan = taste(35 to 1.0)
        val rail = ExploreSelection.forHome(fan, month = 3, week = 2903).map { it.id }
        assertTrue("comfort-tv" in rail || "laugh-out-loud" in rail, rail.toString())
    }

    @Test
    fun monthAndWeekFromIsoDate() {
        assertEquals(1 to 0L, ExploreSelection.monthAndWeek("1970-01-01"))
        assertEquals(1 to 1L, ExploreSelection.monthAndWeek("1970-01-08"))
        val (month, week) = ExploreSelection.monthAndWeek("2026-11-18")
        assertEquals(11, month)
        // 2026-11-18 is day 20,775 since the epoch.
        assertEquals(20775L / 7, week)
    }

    @Test
    fun jitterIsStableAndBounded() {
        val a = ExploreSelection.jitter("comfort-tv", 2900)
        assertEquals(a, ExploreSelection.jitter("comfort-tv", 2900))
        assertNotEquals(a, ExploreSelection.jitter("comfort-tv", 2901))
        (0L..50L).forEach { w -> assertTrue(ExploreSelection.jitter("mcu", w) in 0.0..0.45) }
    }
}
