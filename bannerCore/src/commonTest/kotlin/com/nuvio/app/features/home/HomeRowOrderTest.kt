package com.nuvio.app.features.home

import kotlin.test.Test
import kotlin.test.assertEquals

class HomeRowOrderTest {
    private val rows = listOf("top10", "recommended", "curated:a", "curated:b", "personal:X", "cat:1")
    private fun apply(saved: List<String>, items: List<String> = rows) = HomeRowOrder.apply(items, saved) { it }

    @Test
    fun noSavedOrderLeavesTheDefault() {
        assertEquals(rows, apply(emptyList()))
    }

    @Test
    fun savedOrderIsFollowed() {
        val saved = listOf("cat:1", "top10", "curated:b", "recommended", "personal:X", "curated:a")
        assertEquals(saved, apply(saved))
    }

    @Test
    fun rowsTheListDoesNotMentionKeepTheirPlaceAfterTheRowTheyFollowed() {
        // "curated:a" and "personal:X" are new since the list was saved; each follows its default predecessor.
        val saved = listOf("cat:1", "top10", "recommended", "curated:b")
        assertEquals(listOf("cat:1", "top10", "recommended", "curated:a", "curated:b", "personal:X"), apply(saved))
    }

    @Test
    fun aRowAtTheStartWithNothingBeforeItStaysFirst() {
        val saved = listOf("recommended", "curated:a")
        val result = apply(saved, listOf("top10", "recommended", "curated:a"))
        assertEquals(listOf("top10", "recommended", "curated:a"), result)
    }

    @Test
    fun rowsThisDeviceLacksAreIgnored() {
        // The list came from a TV that has a "top10:movies" row this device doesn't.
        val saved = listOf("curated:b", "top10:movies", "top10", "recommended")
        // The rows the list doesn't mention follow the row that preceded them by default, wherever that row went.
        assertEquals(listOf("curated:b", "personal:X", "cat:1", "top10", "recommended", "curated:a"), apply(saved))
    }

    @Test
    fun applyNeverDropsOrDuplicatesARow() {
        val saved = listOf("cat:1", "cat:1", "gone", "top10")
        val result = apply(saved)
        assertEquals(rows.sorted(), result.sorted())
    }

    @Test
    fun moveShiftsOneRowAndClampsAtTheEnds() {
        assertEquals(listOf("b", "a", "c"), HomeRowOrder.moved(listOf("a", "b", "c"), "b", -1))
        assertEquals(listOf("a", "c", "b"), HomeRowOrder.moved(listOf("a", "b", "c"), "b", 1))
        assertEquals(listOf("a", "b", "c"), HomeRowOrder.moved(listOf("a", "b", "c"), "a", -1))
        assertEquals(listOf("a", "b", "c"), HomeRowOrder.moved(listOf("a", "b", "c"), "c", 1))
        assertEquals(listOf("c", "a", "b"), HomeRowOrder.moved(listOf("a", "b", "c"), "c", -5))
    }

    @Test
    fun savingKeepsRowsOnlyAnotherDeviceKnows() {
        val saved = listOf("top10:movies", "top10:shows", "recommended", "curated:a")
        // This device has no top10:movies / top10:shows (it has the combined row), and the user moved curated:a up.
        val toSave = HomeRowOrder.toSave(saved, listOf("top10", "curated:a", "recommended"))
        // The TV-only rows sit at the start, as they did (nothing before them), the rest in the new order.
        assertEquals(listOf("top10:movies", "top10:shows", "top10", "curated:a", "recommended").toSet(), toSave.toSet())
        assertEquals(listOf("top10", "curated:a", "recommended"), toSave.filter { it in setOf("top10", "curated:a", "recommended") })
    }

    @Test
    fun aSavedOrderRoundTripsThroughApplyAndSave() {
        val arranged = apply(listOf("cat:1", "top10"))
        val saved = HomeRowOrder.toSave(listOf("cat:1", "top10"), arranged)
        assertEquals(arranged, apply(saved))
    }
}
