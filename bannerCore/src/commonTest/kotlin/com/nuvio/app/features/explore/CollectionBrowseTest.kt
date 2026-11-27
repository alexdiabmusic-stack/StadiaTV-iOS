package com.nuvio.app.features.explore

import com.nuvio.app.features.home.MetaPreview
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CollectionBrowseTest {
    private fun film(id: Int, name: String, date: String?, genres: List<String> = emptyList(), lang: String? = "en", popularity: Double? = null) =
        MetaPreview(id = "tmdb:$id", type = "movie", name = name, rawReleaseDate = date, releaseInfo = date?.take(4), genres = genres, language = lang, popularity = popularity)
    private fun show(id: Int, name: String, date: String?) = MetaPreview(id = "tmdb:$id", type = "series", name = name, rawReleaseDate = date)

    private val a = film(1, "The Alpha", "1994-05-01", listOf("Action", "Drama"), popularity = 10.0)
    private val b = film(2, "Bravo", "2005-01-01", listOf("Comedy"), "fr", popularity = 50.0)
    private val c = film(3, "A Charlie", "2016-09-09", listOf("Action"), popularity = 30.0)
    private val d = film(4, "Delta", null, emptyList(), null, popularity = null)
    private val all = listOf(a, b, c, d)

    // ---- runtime boundaries

    @Test fun underTwoHoursIsStrictlyBelow120AndNeedsAKnownRuntime() {
        val ctx = BrowseContext(runtimes = mapOf("tmdb:1" to 119, "tmdb:2" to 120, "tmdb:3" to 121))
        val f = BrowseFilters(runtime = RuntimeBand.Under120)
        assertEquals(listOf(a), CollectionBrowse.filter(all, f, ctx))   // 120 is out, and film 4 (unknown runtime) is out
    }

    @Test fun ninetyMinutesOrLessIncludesExactlyNinety() {
        val ctx = BrowseContext(runtimes = mapOf("tmdb:1" to 90, "tmdb:2" to 91, "tmdb:3" to 60))
        assertEquals(listOf(a, c), CollectionBrowse.filter(all, BrowseFilters(runtime = RuntimeBand.UpTo90), ctx))
    }

    @Test fun runtimeBandsDoNotOverlapAboveTwoHours() {
        assertTrue(RuntimeBand.From120To150.contains(120) && RuntimeBand.From120To150.contains(150))
        assertFalse(RuntimeBand.From120To150.contains(151))
        assertTrue(RuntimeBand.Over150.contains(151) && !RuntimeBand.Over150.contains(150))
        assertFalse(RuntimeBand.Under120.contains(120))
    }

    // ---- other filters never guess

    @Test fun aFilterNeverMatchesATitleThatLacksTheValue() {
        val ctx = BrowseContext(ratings = mapOf("tmdb:1" to 8.0, "tmdb:2" to 6.0))
        assertEquals(listOf(a), CollectionBrowse.filter(all, BrowseFilters(minRating = 7.5), ctx))
        assertEquals(listOf(a, b, c), CollectionBrowse.filter(all, BrowseFilters(decades = setOf(1990, 2000, 2010)), ctx)) // film 4 has no date
        assertEquals(listOf(a, c), CollectionBrowse.filter(all, BrowseFilters(genres = setOf("Action")), ctx))
        assertEquals(listOf(b), CollectionBrowse.filter(all, BrowseFilters(languages = setOf("fr")), ctx))
    }

    @Test fun watchChipsUseTheProfilesHistoryAndKeepCuratedOrder() {
        val ctx = BrowseContext(isWatched = { it.id == "tmdb:2" }, isSaved = { it.id == "tmdb:3" })
        assertEquals(listOf(a, c, d), CollectionBrowse.filter(all, BrowseFilters(watch = WatchFilter.Unwatched), ctx))
        assertEquals(listOf(b), CollectionBrowse.filter(all, BrowseFilters(watch = WatchFilter.Watched), ctx))
        assertEquals(listOf(c), CollectionBrowse.filter(all, BrowseFilters(watch = WatchFilter.Watchlist), ctx))
    }

    @Test fun mediaAndAwardFiltersCombine() {
        val s = show(9, "Series", "2020-01-01")
        val ctx = BrowseContext(awards = mapOf("tv:9" to listOf(AwardEntry(2021, "Outstanding Drama Series"))))
        assertEquals(listOf(s), CollectionBrowse.filter(listOf(a, s), BrowseFilters(media = BrowseMedia.Series, awardCategory = "Outstanding Drama Series"), ctx))
        assertTrue(CollectionBrowse.filter(listOf(a, s), BrowseFilters(awardCategory = "Best Picture"), ctx).isEmpty())
    }

    @Test fun filtersThatMatchNothingGiveAnEmptyListNotAnError() {
        assertTrue(CollectionBrowse.filter(all, BrowseFilters(genres = setOf("Western")), BrowseContext()).isEmpty())
    }

    // ---- sorts

    @Test fun recentAndOldestPutTitlesWithoutADateLast() {
        assertEquals(listOf(c, b, a, d), CollectionBrowse.sort(all, BrowseSort.MostRecent, BrowseContext()))
        assertEquals(listOf(a, b, c, d), CollectionBrowse.sort(all, BrowseSort.Oldest, BrowseContext()))
    }

    @Test fun popularityAndRatingKeepCuratedOrderForTies() {
        assertEquals(listOf(b, c, a, d), CollectionBrowse.sort(all, BrowseSort.MostPopular, BrowseContext()))
        val ctx = BrowseContext(ratings = mapOf("tmdb:3" to 9.0, "tmdb:1" to 9.0))
        assertEquals(listOf(a, c, b, d), CollectionBrowse.sort(all, BrowseSort.HighestRated, ctx)) // a before c: their curated order
    }

    @Test fun titleSortIgnoresLeadingArticlesAndCase() {
        val sorted = CollectionBrowse.sort(all, BrowseSort.TitleAZ, BrowseContext()).map { it.name }
        assertEquals(listOf("The Alpha", "Bravo", "A Charlie", "Delta"), sorted)
    }

    @Test fun runtimeSortsPutUnknownRuntimesAtTheEnd() {
        val ctx = BrowseContext(runtimes = mapOf("tmdb:1" to 130, "tmdb:2" to 85, "tmdb:3" to 100))
        assertEquals(listOf(b, c, a, d), CollectionBrowse.sort(all, BrowseSort.ShortestRuntime, ctx))
        assertEquals(listOf(a, c, b, d), CollectionBrowse.sort(all, BrowseSort.LongestRuntime, ctx))
    }

    @Test fun storyOrderFollowsTheCuratedListThenReleaseOrder() {
        val ctx = BrowseContext(story = listOf(TitleRef(3), TitleRef(1)))
        assertEquals(listOf(c, a, b, d), CollectionBrowse.sort(all, BrowseSort.Story, ctx))
    }

    @Test fun awardCollectionsFilterAndSortByCeremonyYearNotReleaseYear() {
        // Released in 2020 and 2021, but both won at the 2021 and 2022 ceremonies.
        val x = film(21, "X", "2020-12-01"); val y = film(22, "Y", "2021-08-01")
        val awards = mapOf("movie:21" to listOf(AwardEntry(2021, "Best Picture")), "movie:22" to listOf(AwardEntry(2022, "Best Picture")))
        val ctx = BrowseContext(awards = awards)
        assertEquals(listOf(x, y), CollectionBrowse.filter(listOf(x, y), BrowseFilters(decades = setOf(2020)), ctx))
        // The 2021 ceremony and the 2022 ceremony are both in the 2020s; a 2010s filter finds neither, though neither came out before 2020.
        assertTrue(CollectionBrowse.filter(listOf(x, y), BrowseFilters(decades = setOf(2010)), ctx).isEmpty())
        assertEquals(listOf(y, x), CollectionBrowse.sort(listOf(x, y), BrowseSort.CeremonyYear, ctx))
        // A film released in December 2009 that won at the 2010 ceremony belongs to the 2010s for an award page.
        val z = film(23, "Z", "2009-12-01")
        assertEquals(listOf(z), CollectionBrowse.filter(listOf(z), BrowseFilters(decades = setOf(2010)), BrowseContext(awards = mapOf("movie:23" to listOf(AwardEntry(2010, "Best Picture"))))))
        assertTrue(CollectionBrowse.filter(listOf(z), BrowseFilters(decades = setOf(2010)), BrowseContext()).isEmpty(), "without award data it is a 2000s film")
        // The decade menu offers the ceremony's decade for z (2010s) and the release decade for the title with no award data (2000s).
        assertEquals(listOf(2000, 2010), CollectionBrowse.facets(listOf(z, film(24, "W", "2009-01-01")), mapOf("movie:23" to listOf(AwardEntry(2010, "Best Picture")))).decades)
    }

    @Test fun awardCollectionsOfferTheCeremonySort() {
        assertTrue(BrowseSort.CeremonyYear in CollectionBrowse.sortsFor(ExploreCatalog["oscar-best-picture"]!!))
        assertFalse(BrowseSort.CeremonyYear in CollectionBrowse.sortsFor(ExploreCatalog["action-classics"]!!))
    }

    @Test fun curatedSortIsTheIdentity() {
        assertEquals(all, CollectionBrowse.sort(all, BrowseSort.Curated, BrowseContext()))
    }

    @Test fun sortingDoesNotDropOrDuplicateTitles() {
        BrowseSort.entries.forEach { s ->
            val out = CollectionBrowse.sort(all, s, BrowseContext())
            assertEquals(all.map { it.id }.sorted(), out.map { it.id }.sorted(), "sort $s")
        }
    }

    @Test fun anAnnouncedFranchiseOffersStoryOnlyWithAStoryOrder() {
        val mcu = ExploreCatalog["mcu"]!!
        assertTrue(BrowseSort.Story in CollectionBrowse.sortsFor(mcu) && BrowseSort.Release in CollectionBrowse.sortsFor(mcu))
        val oscar = ExploreCatalog["oscar-best-picture"]!!
        assertFalse(BrowseSort.Story in CollectionBrowse.sortsFor(oscar) || BrowseSort.Release in CollectionBrowse.sortsFor(oscar))
    }

    // ---- facets, density, columns

    @Test fun facetsOfferOnlyValuesThatActuallyFilterSomething() {
        val f = CollectionBrowse.facets(all)
        assertEquals(listOf("Action" to 2, "Comedy" to 1, "Drama" to 1), f.genres)
        assertEquals(listOf(1990, 2000, 2010), f.decades)
        assertTrue(CollectionBrowse.facets(listOf(a)).isEmpty, "one title: nothing to filter by")
    }

    @Test fun densityDecidesTheLayout() {
        assertEquals(CollectionBrowse.Density.Empty, CollectionBrowse.density(0))
        assertEquals(CollectionBrowse.Density.Sparse, CollectionBrowse.density(1))
        assertEquals(CollectionBrowse.Density.Sparse, CollectionBrowse.density(3))
        assertEquals(CollectionBrowse.Density.Standard, CollectionBrowse.density(4))
        assertEquals(CollectionBrowse.Density.Standard, CollectionBrowse.density(9))
        assertEquals(CollectionBrowse.Density.Full, CollectionBrowse.density(10))
    }

    @Test fun columnsComeFromWidthAndNeverFromTheDevice() {
        assertEquals(2, CollectionBrowse.columns(320f))     // compact iPhone
        assertEquals(2, CollectionBrowse.columns(402f))     // iPhone 17
        assertEquals(2, CollectionBrowse.columns(440f))     // larger iPhone
        assertEquals(3, CollectionBrowse.columns(700f))     // iPad split
        assertEquals(5, CollectionBrowse.columns(900f))     // iPad portrait
        assertEquals(6, CollectionBrowse.columns(1300f))    // iPad landscape (capped)
        assertEquals(1, CollectionBrowse.columns(402f, fontScale = 2.2f), "huge accessibility text on a phone")
        assertEquals(5, CollectionBrowse.columns(900f, fontScale = 2.2f), "an iPad keeps its columns")
    }

    @Test fun heroHeightAdaptsToTheScreen() {
        assertTrue(CollectionBrowse.heroHeightDp(402f, 874f) in 240f..420f)
        assertTrue(CollectionBrowse.heroHeightDp(874f, 402f) <= 402f * 0.6f + 0.01f, "landscape: never more than 60% of the height")
        assertTrue(CollectionBrowse.heroHeightDp(320f, 568f) >= 200f)
    }

    @Test fun chaptersSkipSectionsWithNoTitles() {
        val sections = listOf(ResolvedSection("Phase 1", listOf(a, b)), ResolvedSection("Empty", emptyList()), ResolvedSection("Phase 2", listOf(c)))
        assertEquals(listOf(CollectionBrowse.Chapter("Phase 1", 2), CollectionBrowse.Chapter("Phase 2", 1)), CollectionBrowse.chapters(sections))
    }
}
