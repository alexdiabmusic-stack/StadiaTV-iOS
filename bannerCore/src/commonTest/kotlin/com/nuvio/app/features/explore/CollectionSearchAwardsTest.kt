package com.nuvio.app.features.explore

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CollectionSearchAwardsTest {
    @Test fun everyAliasPointsAtARealPublishedCollection() {
        CollectionSearch.ALIASES.forEach { (alias, ids) ->
            ids.forEach { id -> assertTrue(ExploreCatalog[id]?.published == true, "alias '$alias' -> unknown collection '$id'") }
        }
    }

    @Test fun marvelFindsTheMarvelUniverseFirst() {
        val ids = CollectionSearch.search("marvel").map { it.id }
        assertTrue(ids.isNotEmpty() && ids.first() in setOf("mcu", "infinity-saga", "multiverse-saga", "studio-marvel"), "got $ids")
        assertTrue("mcu" in ids)
    }

    @Test fun christmasFindsTheHolidayCollections() {
        val ids = CollectionSearch.search("christmas").map { it.id }
        assertTrue("christmas-classics" in ids && "christmas-romance" in ids, "got $ids")
    }

    @Test fun otherNamesPeopleTypeWork() {
        assertTrue("harry-potter" in CollectionSearch.search("hogwarts").map { it.id })
        assertTrue("lord-of-the-rings" in CollectionSearch.search("tolkien").map { it.id })
        assertTrue("oscar-best-picture" in CollectionSearch.search("oscars").map { it.id })
        assertTrue("oscar-best-picture" in CollectionSearch.search("best picture").map { it.id })
    }

    @Test fun aTitleMatchBeatsADescriptionMatch() {
        assertEquals("action-classics", CollectionSearch.search("action classics").first().id)
    }

    @Test fun categoryNamesFindTheirFamily() {
        val ids = CollectionSearch.search("awards").map { it.id }
        assertTrue("oscar-best-picture" in ids || "emmy-series" in ids, "got $ids")
    }

    @Test fun shortOrEmptyQueriesAndGibberishFindNothing() {
        assertTrue(CollectionSearch.search("").isEmpty())
        assertTrue(CollectionSearch.search("a").isEmpty())
        assertTrue(CollectionSearch.search("zzzxqv").isEmpty())
    }

    @Test fun resultsAreLimitedAndNeverDuplicated() {
        val r = CollectionSearch.search("the", limit = 5)
        assertTrue(r.size <= 5 && r.map { it.id }.distinct().size == r.size)
    }

    // ---- awards

    @Test fun oscarCeremonyYearsAreConsecutiveFrom2025To1989AndThenTheLandmarks() {
        val entries = ExploreAwards.entries("oscar-best-picture")
        val list = ExploreCatalog["oscar-best-picture"]!!.sections.single().source as SectionSource.Titles
        assertEquals(list.refs.size, entries.size, "every winner has its ceremony")
        val years = list.refs.map { entries.getValue(it.key).single().ceremonyYear }
        assertEquals((2025 downTo 1989).toList(), years.take(37))
        assertEquals(years.drop(37), years.drop(37).sortedDescending(), "landmarks run newest to oldest")
        assertTrue(years.drop(37).all { it < 1989 })
        assertEquals(years.size, years.distinct().size, "one Best Picture per ceremony")
    }

    @Test fun oscarCeremonyYearIsNotTheReleaseYear() {
        // Anora came out in 2024 and won at the 2025 ceremony; Driving Miss Daisy and Rain Man are in the list (Rain Man was mislisted as 1990).
        assertEquals(2025, ExploreAwards.entries("oscar-best-picture").getValue(TitleRef(1064213).key).single().ceremonyYear)
        assertEquals(1990, ExploreAwards.entries("oscar-best-picture").getValue(TitleRef(403).key).single().ceremonyYear)
        assertEquals(1989, ExploreAwards.entries("oscar-best-picture").getValue(TitleRef(380).key).single().ceremonyYear)
    }

    @Test fun everyEmmyWinnerIsInTheCollectionAndHasACategoryAndYears() {
        val entries = ExploreAwards.entries("emmy-series")
        val list = ExploreCatalog["emmy-series"]!!.sections.single().source as SectionSource.Titles
        assertEquals(list.refs.map { it.key }.toSet(), entries.keys, "wins and the collection list the same series")
        entries.values.flatten().forEach { assertTrue(it.ceremonyYear in 2010..2025 && it.category.startsWith("Outstanding ")) }
        assertEquals(listOf("Outstanding Comedy Series", "Outstanding Drama Series"), ExploreAwards.categories("emmy-series"))
        assertEquals(listOf(2013, 2014), entries.getValue(TitleRef(1396, tv = true).key).map { it.ceremonyYear }) // Breaking Bad
    }

    @Test fun otherCollectionsCarryNoAwardData() {
        assertTrue(ExploreAwards.entries("action-classics").isEmpty() && !ExploreAwards.has("action-classics"))
    }
}

class CollectionDataQualityTest {
    @Test fun noCollectionListsTheSameCuratedTitleTwiceInOneShelf() {
        ExploreCatalog.all.forEach { c ->
            c.sections.forEach { s ->
                val refs = (s.source as? SectionSource.Titles)?.refs ?: return@forEach
                assertEquals(refs.map { it.key }.distinct().size, refs.size, "${c.id}/${s.title} repeats a title")
            }
        }
    }

    @Test fun theCollectionsFoundEmptyOrNearlyEmptyNowUseTheWiderRules() {
        fun movieQuery(id: String) = ExploreCatalog[id]!!.sections.map { it.source }.filterIsInstance<SectionSource.Discover>().first { !it.tv }.query
        // Feel-good was one film: every TMDB tag for the idea counts now.
        assertTrue(movieQuery("feel-good").getValue("with_keywords").split('|').size >= 5)
        // Disney Classics was zero: the classics are filed under Walt Disney Productions and Pictures.
        val disney = movieQuery("disney-classics")
        assertTrue("3166" in disney.getValue("with_companies") && "2" in disney.getValue("with_companies").split('|'))
        assertEquals("1999-12-31", disney["primary_release_date.lte"])
        // Cult Classics leads with BannerTV's verified picks.
        val cult = ExploreCatalog["cult-classics"]!!
        val seed = (cult.sections.first().source as SectionSource.Titles).refs
        assertTrue(seed.size >= 30 && seed.all { !it.tv })
    }

    @Test fun theRuntimeCollectionsKeepStrictBoundaries() {
        val under2 = ExploreCatalog["under-2-hours"]!!.sections.single().source as SectionSource.Discover
        assertEquals("119", under2.query["with_runtime.lte"], "strictly below 120 minutes")
        assertEquals("80", under2.query["with_runtime.gte"])
        val ninety = ExploreCatalog["under-90"]!!.sections.map { it.source }.filterIsInstance<SectionSource.Discover>()
        assertTrue(ninety.isNotEmpty() && ninety.all { (it.query["with_runtime.lte"]?.toInt() ?: 999) <= 90 }, "90 minutes or less never lets a longer film in")
    }

    @Test fun goldenAgeStaysInsideItsDateBoundaries() {
        val q = (ExploreCatalog["golden-age"]!!.sections.single().source as SectionSource.Discover).query
        assertEquals("1930-01-01", q["primary_release_date.gte"])
        assertEquals("1959-12-31", q["primary_release_date.lte"])
    }
}
