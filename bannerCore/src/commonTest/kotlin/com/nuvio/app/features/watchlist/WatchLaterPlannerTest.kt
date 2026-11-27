package com.nuvio.app.features.watchlist

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WatchLaterPlannerTest {
    private fun movie(id: Int) = WatchlistTitle(id, false, "Film $id")
    private fun show(id: Int) = WatchlistTitle(id, true, "Show $id")

    @Test fun newTitlesAreAddedInWatchlistOrderAndRememberedAsDealtWith() {
        val plan = WatchLaterPlanner.plan(listOf(movie(1), show(2), movie(3)), emptySet(), { false }, { false })
        assertEquals(listOf("movie:1", "series:2", "movie:3"), plan.add.map { it.key })
        assertEquals(setOf("movie:1", "series:2", "movie:3"), plan.handled)
    }

    @Test fun whatIsAlreadyInMyListIsNotAddedAgainAndIsRemembered() {
        val plan = WatchLaterPlanner.plan(listOf(movie(1), movie(2)), emptySet(), { it.tmdbId == 1 }, { false })
        assertEquals(listOf("movie:2"), plan.add.map { it.key }); assertEquals(1, plan.alreadyThere)
        assertTrue("movie:1" in plan.handled, "so that removing it later is respected")
    }

    @Test fun aTitleTheMemberRemovedIsNeverPutBack() {
        val plan = WatchLaterPlanner.plan(listOf(movie(1), movie(2)), setOf("movie:1"), { false }, { false })
        assertEquals(listOf("movie:2"), plan.add.map { it.key }); assertEquals(1, plan.removedByMember)
        assertTrue("movie:1" in plan.handled, "still remembered")
    }

    @Test fun aFilmAlreadyWatchedIsLeftOutButAShowIsNot() {
        val plan = WatchLaterPlanner.plan(listOf(movie(1), show(1)), emptySet(), { false }, { true })
        assertEquals(listOf("series:1"), plan.add.map { it.key }); assertEquals(1, plan.alreadyWatched)
        assertTrue("movie:1" !in plan.handled, "a watched film is not marked dealt with: it is simply not to-watch")
    }

    @Test fun aMovieAndAShowWithTheSameNumberAreDifferentTitles() {
        val plan = WatchLaterPlanner.plan(listOf(movie(5), show(5)), emptySet(), { false }, { false })
        assertEquals(2, plan.add.size)
    }

    @Test fun repeatedTitlesAreCountedOnce() {
        val plan = WatchLaterPlanner.plan(listOf(movie(1), movie(1), movie(1)), emptySet(), { false }, { false })
        assertEquals(1, plan.add.size)
    }

    @Test fun anEmptyWatchlistChangesNothingAndKeepsWhatWasRemembered() {
        val plan = WatchLaterPlanner.plan(emptyList(), setOf("movie:9"), { false }, { false })
        assertTrue(plan.add.isEmpty()); assertEquals(setOf("movie:9"), plan.handled)
    }

    @Test fun theSummaryNamesEachOutcomeOnlyWhenThereIsOne() {
        assertEquals("3 added to My List", WatchlistApplyResult(3, 0, 0, 0, 0).summary())
        assertEquals("2 added to My List, 1 already there, 4 already watched, 5 you removed before are left out, 6 could not be matched", WatchlistApplyResult(2, 1, 5, 4, 6).summary())
    }
}
