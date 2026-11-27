package com.nuvio.app.features.letterboxd

import com.nuvio.app.features.watchlist.WatchlistApplyResult
import com.nuvio.app.features.watchlist.WatchlistSink
import com.nuvio.app.features.watchlist.WatchlistTitle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val SIGNED_IN_COOKIES = mapOf(LetterboxdSession.SESSION_COOKIE to "abc", LetterboxdSession.CSRF_COOKIE to "tok123", "cf_clearance" to "cf")

@OptIn(ExperimentalCoroutinesApi::class)
private class WatchlistRig(scope: CoroutineScope, val site: FakeLetterboxdSite = FakeLetterboxdSite()) {
    var clock = LetterboxdDates.epochDay("2026-11-23")!! * 86_400_000L + 12 * 3_600_000L
    val kv = MemoryKeyValue()
    val secrets = MemorySecretStore()
    val applied = mutableListOf<List<WatchlistTitle>>()
    var sinkFails = false
    private var ids = 0
    val manager = LetterboxdManager(
        kv, secrets, site, scope, now = { clock }, localDate = ::civilDate, newId = { "w${ids++}" }, pageSpacingMs = 0,
        watchlistSink = WatchlistSink { _, source, titles ->
            check(source == "letterboxd")
            if (sinkFails) error("My List is unavailable")
            applied += titles; WatchlistApplyResult(titles.size, 0, 0, 0, 0)
        },
    )

    init {
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        site.films += FakeLetterboxdSite.Film(680, "pulp-fiction", "777", "p1")
        site.films += FakeLetterboxdSite.Film(11, "star-wars", "888", "s1")
        site.films += FakeLetterboxdSite.Film(99, "some-show", "999", "n1", tv = true)
    }

    fun watchlist(vararg films: Pair<String, String>) { site.watchlist.clear(); site.watchlist += films }
}

@OptIn(ExperimentalCoroutinesApi::class)
private fun TestScope.scopeForManager(): CoroutineScope = CoroutineScope(UnconfinedTestDispatcher(testScheduler))

@OptIn(ExperimentalCoroutinesApi::class)
class LetterboxdWatchlistTest {
    @Test fun everyPageIsReadAndEachFilmIsMatchedToItsTmdbIdAndPutInMyList() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle(); rig.applied.clear()
        rig.watchlist("the-matrix" to "The Matrix", "pulp-fiction" to "Pulp Fiction", "star-wars" to "Star Wars")
        val r = rig.manager.importWatchlist(1)
        assertEquals(3, r.films); assertEquals(0, r.unmatched); assertNull(r.message)
        val titles = rig.applied.single()
        assertEquals(listOf(603, 680, 11), titles.map { it.tmdbId }); assertTrue(titles.none { it.isSeries })
        assertEquals("The Matrix", titles.first().name); assertEquals("2020", titles.first().year)
        assertEquals(3, rig.manager.watchlistFlow.value[1]!!.films.size)
        assertTrue(r.summary!!.startsWith("3 added"))
        assertEquals(r.summary, rig.manager.accountsFlow.value[1]!!.lastWatchlistSummary)
        assertTrue(rig.site.writeCount == 0, "nothing was written to Letterboxd")
    }

    @Test fun aTvEntryOrAFilmWithNoTmdbMovieIsReportedNotAdded() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle(); rig.applied.clear()
        rig.watchlist("the-matrix" to "The Matrix", "some-show" to "Some Show", "not-on-the-site" to "Gone")
        val r = rig.manager.importWatchlist(1)
        assertEquals(1, r.films); assertEquals(2, r.unmatched)
        assertEquals(listOf(603), rig.applied.single().map { it.tmdbId })
    }

    @Test fun runningItAgainDoesNotReadFilmPagesItAlreadyMatched() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        rig.watchlist("the-matrix" to "The Matrix", "pulp-fiction" to "Pulp Fiction")
        rig.manager.importWatchlist(1)
        val filmPages = rig.site.requests.count { it.path.startsWith("/film/") }
        rig.manager.importWatchlist(1)
        assertEquals(filmPages, rig.site.requests.count { it.path.startsWith("/film/") })
    }

    @Test fun aWatchlistThatDoesNotAddUpToItsDeclaredSizeIsAShortReadAndKeepsTheLastCopy() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        rig.watchlist("the-matrix" to "The Matrix", "pulp-fiction" to "Pulp Fiction", "star-wars" to "Star Wars")
        assertEquals(3, rig.manager.importWatchlist(1).films); val before = rig.manager.watchlistFlow.value[1]; rig.applied.clear()
        rig.site.declaredWatchlistTotal = 191
        val r = rig.manager.importWatchlist(1)
        assertNull(r.films); assertTrue(r.message!!.contains("lists 191 films but 3 were read")); assertEquals(before, rig.manager.watchlistFlow.value[1])
        assertTrue(rig.applied.isEmpty(), "a short read is never put in My List")
    }

    @Test fun aFailedPageKeepsTheLastCopyAndAddsNothing() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        rig.watchlist("the-matrix" to "The Matrix", "pulp-fiction" to "Pulp Fiction", "star-wars" to "Star Wars")
        rig.manager.importWatchlist(1); val before = rig.manager.watchlistFlow.value[1]; rig.applied.clear()
        rig.site.watchlistFailsOnPage = 2
        val r = rig.manager.importWatchlist(1)
        assertNull(r.films); assertEquals(before, rig.manager.watchlistFlow.value[1]); assertTrue(rig.applied.isEmpty())
        assertTrue(rig.manager.engine.events.value.any { it.note?.contains("last copy was kept") == true })
    }

    @Test fun anEmptyWatchlistIsAGenuineCompleteRead() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        rig.watchlist("the-matrix" to "The Matrix"); rig.manager.importWatchlist(1)
        rig.watchlist()
        assertEquals(0, rig.manager.importWatchlist(1).films); assertTrue(rig.manager.watchlistFlow.value[1]!!.films.isEmpty())
    }

    @Test fun theSettingKeepsTheWatchlistOutOfMyListButStillSavesACopy() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle(); rig.applied.clear()
        rig.manager.updateSettings(1) { it.copy(watchlistToLibrary = false) }
        rig.watchlist("the-matrix" to "The Matrix")
        val r = rig.manager.importWatchlist(1)
        assertEquals(1, r.films); assertNull(r.summary); assertTrue(rig.applied.isEmpty())
        // Switching it on afterwards uses the saved copy, with no new request to Letterboxd.
        val requests = rig.site.requests.size
        rig.manager.updateSettings(1) { it.copy(watchlistToLibrary = true) }
        assertNotNull(rig.manager.addSavedWatchlistToMyList(1)); assertEquals(1, rig.applied.size); assertEquals(requests, rig.site.requests.size)
    }

    @Test fun aFailureAddingToMyListDoesNotCostTheCopyThatWasRead() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        rig.sinkFails = true; rig.watchlist("the-matrix" to "The Matrix")
        val r = rig.manager.importWatchlist(1)
        assertEquals(1, r.films); assertTrue(r.summary!!.startsWith("Could not add the watchlist to My List"))
        assertEquals(1, rig.manager.watchlistFlow.value[1]!!.films.size)
    }

    @Test fun aFirstConnectionReadsTheWatchlistButAReconnectDoesNot() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.watchlist("the-matrix" to "The Matrix")
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        assertEquals(1, rig.applied.size)
        rig.applied.clear(); rig.site.requests.clear()
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        assertTrue(rig.site.requests.none { it.path.contains("/watchlist/") })
    }

    @Test fun theWatchlistIsReadAgainWhenTheAppReturnsOnlyOnceItHasGoneStale() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        rig.watchlist("the-matrix" to "The Matrix"); rig.manager.importWatchlist(1)
        val reads = rig.site.requests.count { it.path.contains("/watchlist/") }
        rig.manager.refreshWatchlistIfStale(1); advanceUntilIdle()
        assertEquals(reads, rig.site.requests.count { it.path.contains("/watchlist/") }, "read a moment ago: left alone")
        rig.clock += 13 * 3_600_000L
        rig.manager.refreshWatchlistIfStale(1); advanceUntilIdle()
        assertTrue(rig.site.requests.count { it.path.contains("/watchlist/") } > reads)
    }

    @Test fun disconnectingWithDeletionRemovesTheSavedCopy() = runTest {
        val rig = WatchlistRig(scopeForManager())
        rig.manager.connect(1, SIGNED_IN_COOKIES, "UA"); advanceUntilIdle()
        rig.watchlist("the-matrix" to "The Matrix"); rig.manager.importWatchlist(1)
        rig.manager.disconnect(1, deleteLocalHistory = true)
        assertNull(rig.manager.watchlistFlow.value[1]); assertFalse(rig.kv.read("letterboxd_watchlist_v1").orEmpty().contains("the-matrix"))
    }

    @Test fun theCountParserReadsWhatTheLiveSiteSays() {
        assertEquals(191, LetterboxdHtml.watchlistCount("""<span class="js-watchlist-count">191 films</span>"""))
        assertEquals(1204, LetterboxdHtml.watchlistCount("""<span class="js-watchlist-count">1,204 films</span>"""))
        assertEquals(1, LetterboxdHtml.watchlistCount("""<span class="js-watchlist-count">1 film</span>"""))
        assertEquals(42, LetterboxdHtml.watchlistCount("""<h1>Alex wants to see <span>42 films</span></h1>"""))
        assertNull(LetterboxdHtml.watchlistCount("<html>nothing here</html>"))
        assertFalse(LetterboxdHtml.watchedGrid("<html></html>").isNotEmpty())
    }
}
