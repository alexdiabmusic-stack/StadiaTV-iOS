package com.nuvio.app.features.explore

import com.nuvio.app.features.home.MetaPreview
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class CollectionPlanTest {
    private fun film(i: Int, date: String = "2000-01-01") = MetaPreview(id = "tmdb:$i", type = "movie", name = "Film $i", rawReleaseDate = date, genres = listOf(if (i % 2 == 0) "Action" else "Drama"))
    private fun titles(range: IntRange) = range.map { film(it) }
    private val shelfCollection = ExploreCollection("t", "T", "d", CollectionCategory.Genres, CollectionKind.Editorial, CollectionMedia.Movies, sections = listOf(CollectionSection("Shelf", SectionSource.Titles(emptyList()))))
    private val saga = ExploreCollection("s", "S", "d", CollectionCategory.Universes, CollectionKind.Franchise, CollectionMedia.Movies,
        sections = listOf(CollectionSection("Phase 1", SectionSource.Titles(emptyList())), CollectionSection("Phase 2", SectionSource.Titles(emptyList()))))

    private fun plan(
        c: ExploreCollection, r: ResolvedCollection?, loaded: Boolean = true, f: BrowseFilters = BrowseFilters(), s: BrowseSort = BrowseSort.Curated,
        ctx: BrowseContext = BrowseContext(), columns: Int = 2, children: List<ExploreCollection> = emptyList(),
    ) = CollectionPlan.build(c, children, r, loaded, f, s, ctx, columns)

    private fun resolved(vararg sections: ResolvedSection, upcoming: List<MetaPreview> = emptyList()) = ResolvedCollection("t", sections.toList(), upcoming)

    @Test fun aLongCollectionIsAHeroControlsAndAMultiRowGrid() {
        val rows = plan(shelfCollection, resolved(ResolvedSection("Shelf", titles(1..25))))
        assertEquals(PlanRow.Hero, rows[0])
        assertIs<PlanRow.Controls>(rows[1])
        val posters = rows.filterIsInstance<PlanRow.Posters>()
        assertEquals(13, posters.size)                       // 25 titles, two to a row
        assertTrue(posters.dropLast(1).all { it.items.size == 2 } && posters.last().items.size == 1)
        assertEquals((1..25).map { "tmdb:$it" }, posters.flatMap { it.items }.map { it.id }, "curated order kept")
        assertTrue(rows.map { it.key }.let { it.size == it.toSet().size }, "row keys are unique")
    }

    @Test fun aSmallCollectionIsLargeCardsNotAnEmptyGrid() {
        listOf(1, 2, 3).forEach { n ->
            val rows = plan(shelfCollection, resolved(ResolvedSection("Shelf", titles(1..n))))
            assertEquals(n, rows.filterIsInstance<PlanRow.Sparse>().single().items.size)
            assertTrue(rows.none { it is PlanRow.Posters })
        }
    }

    @Test fun fourToNineTitlesUseTheStandardGridAndFilteringASparseCollectionKeepsItsFilters() {
        val rows = plan(shelfCollection, resolved(ResolvedSection("Shelf", titles(1..6))))
        assertTrue(rows.none { it is PlanRow.Sparse } && rows.filterIsInstance<PlanRow.Posters>().size == 3)
        // A sparse collection that the member has filtered shows its (filtered) titles in the normal grid.
        val sparse = resolved(ResolvedSection("Shelf", titles(1..3)))
        val filtered = plan(shelfCollection, sparse, f = BrowseFilters(genres = setOf("Drama")))
        assertTrue(filtered.none { it is PlanRow.Sparse } && filtered.filterIsInstance<PlanRow.Posters>().flatMap { it.items }.size == 2)
    }

    @Test fun noMatchesShowsAMessageNotAnEmptyGrid() {
        val rows = plan(shelfCollection, resolved(ResolvedSection("Shelf", titles(1..12))), f = BrowseFilters(genres = setOf("Western")))
        assertEquals("movies", rows.filterIsInstance<PlanRow.NoMatches>().single().noun)
        assertTrue(rows.none { it is PlanRow.Posters }, "no empty grid")
        assertTrue(rows.any { it is PlanRow.Controls }, "the controls stay so the filter can be reset")
    }

    @Test fun loadingErrorAndEmptyStatesAreDistinct() {
        assertTrue(plan(shelfCollection, null, loaded = false).last() is PlanRow.Skeleton)
        assertTrue(plan(shelfCollection, resolved(), loaded = false).last() is PlanRow.Skeleton)
        assertTrue(plan(shelfCollection, resolved(), loaded = true).last() is PlanRow.LoadError)
        // Content already on screen is never replaced by a skeleton while a refresh is under way.
        assertTrue(plan(shelfCollection, resolved(ResolvedSection("Shelf", titles(1..12))), loaded = false).none { it is PlanRow.Skeleton })
    }

    @Test fun aSagaShowsProgressChaptersAndEachChapterHeading() {
        val rows = plan(saga, resolved(ResolvedSection("Phase 1", titles(1..6)), ResolvedSection("Phase 2", titles(7..12))))
        assertTrue(rows.any { it is PlanRow.Progress })
        assertEquals(listOf("Phase 1", "Phase 2"), rows.filterIsInstance<PlanRow.Chapters>().single().chapters.map { it.title })
        val headings = rows.filterIsInstance<PlanRow.Heading>()
        assertEquals(listOf("Phase 1", "Phase 2"), headings.map { it.text })
        assertEquals(6, headings.first().count)
        // A chapter chip scrolls to its heading's row.
        val index = CollectionPlan.indexOfChapter(rows, "Phase 2")!!
        assertEquals("Phase 2", (rows[index] as PlanRow.Heading).text)
        assertEquals(null, CollectionPlan.indexOfChapter(rows, "Phase 9"))
    }

    @Test fun sortingMergesChaptersIntoOneListAndDropsTheChapterChips() {
        val rows = plan(saga, resolved(ResolvedSection("Phase 1", titles(1..6)), ResolvedSection("Phase 2", titles(7..12))), s = BrowseSort.MostRecent)
        assertTrue(rows.none { it is PlanRow.Chapters })
        assertEquals(listOf("Most Recent"), rows.filterIsInstance<PlanRow.Heading>().map { it.text })
        assertEquals(12, rows.filterIsInstance<PlanRow.Posters>().sumOf { it.items.size })
    }

    @Test fun filtersHideChapterChipsAndEmptyChaptersDisappear() {
        val r = resolved(ResolvedSection("Phase 1", titles(1..6)), ResolvedSection("Phase 2", listOf(film(7), film(9))))
        val rows = plan(saga, r, f = BrowseFilters(genres = setOf("Action")))
        assertTrue(rows.none { it is PlanRow.Chapters })
        assertEquals(listOf("Phase 1"), rows.filterIsInstance<PlanRow.Heading>().map { it.text }, "Phase 2 has no Action films")
    }

    @Test fun announcedTitlesStayApartAtTheEnd() {
        val rows = plan(shelfCollection, resolved(ResolvedSection("Shelf", titles(1..10)), upcoming = listOf(film(99, "2099-01-01"))))
        val last = rows.filterIsInstance<PlanRow.Heading>().last()
        assertEquals("Announced", last.text)
        assertEquals("tmdb:99", rows.filterIsInstance<PlanRow.Posters>().last().items.single().id)
    }

    @Test fun aCollectionOfCollectionsIsItsChildrenInRows() {
        val kids = (1..5).map { ExploreCollection("k$it", "K$it", "d", CollectionCategory.Universes, CollectionKind.Franchise, CollectionMedia.Movies) }
        val parent = ExploreCollection("p", "P", "d", CollectionCategory.Universes, CollectionKind.Franchise, CollectionMedia.Movies, children = kids.map { it.id })
        val rows = plan(parent, null, children = kids)
        assertEquals(3, rows.filterIsInstance<PlanRow.ChildrenRow>().size)
        assertTrue(rows.none { it is PlanRow.Controls || it is PlanRow.Skeleton }, "no titles, no controls, nothing loading")
    }

    @Test fun nounNamesWhatTheCollectionHolds() {
        assertEquals("movies", CollectionPlan.noun(titles(1..3)))
        assertEquals("series", CollectionPlan.noun(listOf(MetaPreview("tmdb:1", "series", "S"))))
        assertEquals("titles", CollectionPlan.noun(listOf(film(1), MetaPreview("tmdb:2", "series", "S"))))
    }

    @Test fun visibleCountFollowsTheFilters() {
        val r = resolved(ResolvedSection("Shelf", titles(1..10)))
        assertEquals(10, CollectionPlan.visibleCount(r, BrowseFilters(), BrowseContext()))
        assertEquals(5, CollectionPlan.visibleCount(r, BrowseFilters(genres = setOf("Action")), BrowseContext()))
        assertFalse(CollectionPlan.visibleCount(null, BrowseFilters(), BrowseContext()) > 0)
    }
}
