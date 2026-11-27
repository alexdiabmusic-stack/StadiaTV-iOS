package com.nuvio.app.features.discovery

import com.nuvio.app.features.playback.InMemoryPlaybackStateStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SearchQueryParserTest {
    private val year = 2026
    private fun parse(q: String) = SearchQueryParser.parse(q, year)

    @Test fun feelGoodMoviesUnderTwoHours() {
        val s = parse("Feel-good movies under two hours")
        assertEquals(SearchMediaType.MOVIE, s.mediaType); assertEquals(listOf("feel-good"), s.keywords); assertEquals(120, s.maxRuntimeMin)
        assertEquals(setOf(ChipKind.MEDIA_TYPE, ChipKind.KEYWORD, ChipKind.RUNTIME), s.chips.map { it.kind }.toSet())
        assertEquals("120", SearchQueryParser.toDiscover(s).params["with_runtime.lte"])
    }

    @Test fun crimeSeriesSimilarToBreakingBad() {
        val s = parse("Crime series similar to Breaking Bad")
        assertEquals(SearchMediaType.SERIES, s.mediaType); assertEquals(listOf("Crime"), s.genres); assertEquals("Breaking Bad", s.similarTo)
        assertEquals("80", SearchQueryParser.toDiscover(s).params["with_genres"])
    }

    @Test fun christmasRomanceMoviesThatArentHallmark() {
        val s = parse("Christmas romance movies that aren't Hallmark")
        assertEquals(listOf("Romance"), s.genres); assertEquals(listOf("christmas"), s.keywords); assertEquals(listOf("Hallmark"), s.excluded)
        assertEquals(listOf("Hallmark"), SearchQueryParser.toDiscover(s).unresolvedExcludedCompanies)
    }

    @Test fun moviesStarringTomCruiseFromTheTwoThousands() {
        val s = parse("Movies starring Tom Cruise from the 2000s")
        assertEquals(listOf("Tom Cruise"), s.people); assertEquals(2000, s.yearFrom); assertEquals(2009, s.yearTo)
        val d = SearchQueryParser.toDiscover(s)
        assertEquals("2000-01-01", d.params["primary_release_date.gte"]); assertEquals("2009-12-31", d.params["primary_release_date.lte"])
        assertEquals(listOf("Tom Cruise"), d.unresolvedPeople)
    }

    @Test fun scienceFictionMoviesIHaventWatched() {
        val s = parse("Science fiction movies I haven't watched")
        assertEquals(listOf("Science Fiction"), s.genres); assertEquals(WatchedFilter.UNWATCHED, s.watched)
        assertEquals(WatchedFilter.UNWATCHED, SearchQueryParser.toDiscover(s).localWatchedFilter) // answered from local history
    }

    @Test fun familyMoviesAvailableToWatchTonightAndAcclaimedThrillersFromTheLastFiveYears() {
        val a = parse("Family movies available to watch tonight")
        assertEquals(listOf("Family"), a.genres); assertTrue(a.availableNow)
        val b = parse("Acclaimed thrillers from the last five years")
        assertEquals(listOf("Thriller"), b.genres); assertEquals(2021, b.yearFrom); assertEquals(7.5, b.minRating)
        assertEquals("200", SearchQueryParser.toDiscover(b).params["vote_count.gte"])
    }

    @Test fun anOrdinaryTitleSearchIsLeftExactlyAsTyped() {
        for (q in listOf("Inception", "The Dark Knight", "Breaking Bad", "tt0111161")) {
            val s = parse(q); assertFalse(s.isStructured, q); assertEquals(q, s.residualText); assertTrue(s.chips.isEmpty())
        }
        assertEquals("a movie about war", parse("\"a movie about war\"").residualText) // quoted: exact, no filters
        assertFalse(parse("\"a movie about war\"").isStructured)
    }

    @Test fun everyChipCanBeRemoved() {
        val s = parse("Feel-good movies under two hours")
        val noRuntime = s.without(s.chips.first { it.kind == ChipKind.RUNTIME }.id)
        assertNull(noRuntime.maxRuntimeMin); assertEquals(SearchMediaType.MOVIE, noRuntime.mediaType)
        var bare = s; s.chips.forEach { bare = bare.without(it.id) }
        assertFalse(bare.isStructured); assertNull(bare.mediaType); assertTrue(bare.keywords.isEmpty())
    }

    @Test fun tvQueriesUseTvGenreIdsAndDateFields() {
        val s = parse("sci-fi series from the 90s")
        val d = SearchQueryParser.toDiscover(s)
        assertEquals("10765", d.params["with_genres"]); assertEquals("1990-01-01", d.params["first_air_date.gte"])
    }

    @Test fun aTitleWordThatIsAlsoAGenreInsideARealTitleStaysATitleSearchWhenNothingElseMatches() {
        // "Crime" alone does read as a genre chip; the viewer can remove it. A bare unknown title stays ordinary.
        assertTrue(parse("Crime").isStructured)
        assertFalse(parse("Zodiac").isStructured)
    }
}

class DiscoveryLogicTest {
    @Test fun microgenresWithTooFewResultsAreHiddenAndTasteAndSeasonLead() {
        val counts = MicrogenreCatalog.all.associate { it.id to 20 } + ("clever-heists" to 3)
        val shown = MicrogenreCatalog.visible(counts, tasteAffinity = mapOf("dark-crime-thrillers" to 0.9), month = 12)
        assertFalse(shown.any { it.id == "clever-heists" })
        assertEquals("dark-crime-thrillers", shown.first().id)
        assertEquals("cozy-small-town-romance", MicrogenreCatalog.visible(counts, emptyMap(), month = 12).first().id) // seasonal lift
        assertEquals(10, MicrogenreCatalog.all.size)
    }

    @Test fun aTheatricalDateNeverMakesATitlePlayable() {
        val now = 1_000L
        val theatrical = ReleaseLabeler.label(UpcomingItem("m", ReleaseKind.THEATRICAL, 5_000L), now)
        assertTrue(theatrical.upcoming); assertFalse(theatrical.canPlayNow); assertTrue(theatrical.showWatchlistAndRemind)
        val out = ReleaseLabeler.label(UpcomingItem("m", ReleaseKind.THEATRICAL, 500L), now)
        assertFalse(out.canPlayNow) // released in cinemas, not confirmed on any source
        assertTrue(ReleaseLabeler.label(UpcomingItem("m", ReleaseKind.RECENTLY_AVAILABLE, 500L, streamingConfirmed = true), now).canPlayNow)
    }

    private val day = 24 * 60 * 60_000L
    private fun reminder(date: Long?, notified: List<ReminderStage> = emptyList()) = ReleaseReminder(1, "movie:x", ReleaseKind.DIGITAL, date, notified)

    @Test fun nowAvailableIsNeverSentFromADateAlone() {
        val r = reminder(date = 1_000L)
        assertEquals(ReminderAction.Notify(ReminderStage.DATE_REACHED_AVAILABILITY_UNKNOWN), ReminderEngine.next(r, nowMs = 5_000L, availabilityConfirmed = false))
        assertEquals(ReminderAction.Notify(ReminderStage.AVAILABLE_CONFIRMED), ReminderEngine.next(r, 5_000L, availabilityConfirmed = true))
    }

    @Test fun eachStageIsSentAtMostOnce() {
        val r = reminder(date = 10 * day)
        assertEquals(ReminderAction.Notify(ReminderStage.DATE_APPROACHING), ReminderEngine.next(r, 9 * day + day / 2, false))
        assertEquals(ReminderAction.None, ReminderEngine.next(r.copy(notified = listOf(ReminderStage.DATE_APPROACHING)), 9 * day + day / 2, false))
        assertEquals(ReminderAction.None, ReminderEngine.next(r, 2 * day, false)) // too early
        val done = r.copy(notified = listOf(ReminderStage.AVAILABLE_CONFIRMED))
        assertEquals(ReminderAction.None, ReminderEngine.next(done, 11 * day, true))
        assertEquals(ReminderAction.None, ReminderEngine.next(done, 11 * day, false)) // already told it is available
    }

    @Test fun cancellingAndChangedDatesWork() {
        val s = ReminderStore(InMemoryPlaybackStateStore())
        s.add(reminder(10 * day)); s.markNotified(1, "movie:x", ReleaseKind.DIGITAL, ReminderStage.DATE_APPROACHING)
        s.updateReleaseDate(1, "movie:x", ReleaseKind.DIGITAL, 20 * day)
        assertTrue(s.all(1).single().notified.isEmpty()); assertEquals(20 * day, s.all(1).single().releaseDateMs)
        s.cancel(1, "movie:x", ReleaseKind.DIGITAL); assertTrue(s.all(1).isEmpty())
        assertTrue(s.all(2).isEmpty())
    }

    @Test fun myBannerTvShowsOnlySectionsThatHaveSomethingInOrder() {
        val s = MyBannerTv.sections(mapOf(MyBannerSection.WATCHLIST to 3, MyBannerSection.CONTINUE_WATCHING to 1, MyBannerSection.DOWNLOADS to 0))
        assertEquals(listOf(MyBannerSection.CONTINUE_WATCHING, MyBannerSection.WATCHLIST), s)
    }
}
