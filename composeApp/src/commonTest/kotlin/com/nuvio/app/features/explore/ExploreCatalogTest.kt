package com.nuvio.app.features.explore

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ExploreCatalogTest {
    private val featuredTitles = listOf(
        "90 Minutes or Less", "Hidden Gems", "Movie Universes", "Nostalgia Night", "Twists You Won't See Coming",
        "Comfort TV", "Masterpieces", "Game to Screen", "Based on True Events", "One More Episode", "Time Travel",
        "Visually Stunning", "The Complete Saga", "Short & Sweet", "Critically Acclaimed Series", "What a Plot Twist!",
        "From Book to Screen", "The 2000s Rewind", "Laugh Out Loud", "Movie Night for Two", "Award Winners",
        "Around the World", "Just Added", "Coming Soon",
    )

    @Test
    fun all24FeaturedCollectionsExistInOrder() {
        assertEquals(featuredTitles, ExploreCatalog.featured.map { it.title })
    }

    @Test
    fun idsAreUnique() {
        val ids = ExploreCatalog.all.map { it.id }
        assertEquals(ids.size, ids.toSet().size, "duplicate ids: ${ids.groupBy { it }.filterValues { it.size > 1 }.keys}")
    }

    @Test
    fun everyChildCollectionExists() {
        ExploreCatalog.all.forEach { c ->
            c.children.forEach { child -> assertTrue(ExploreCatalog[child] != null, "${c.id} lists missing child $child") }
        }
    }

    @Test
    fun everyPublishedCollectionCanResolveSomething() {
        ExploreCatalog.all.filter { it.published }.forEach { c ->
            assertTrue(c.sections.isNotEmpty() || c.children.isNotEmpty() || c.episodes != null, "${c.id} has nothing to show")
        }
    }

    @Test
    fun seasonalMonthsAreValid() {
        ExploreCatalog.all.forEach { c -> assertTrue(c.months.all { it in 1..12 }, "${c.id} has an invalid month") }
    }

    @Test
    fun requestedFranchisesAndSubcollectionsExist() {
        listOf(
            "mcu", "infinity-saga", "multiverse-saga", "x-men", "spider-man", "batman", "dceu", "dc-elseworlds", "superman",
            "dc-animated", "fantastic-four", "deadpool", "star-wars", "star-wars-skywalker", "star-wars-clone-wars",
            "star-wars-new-republic", "star-trek", "wizarding-world", "harry-potter", "fantastic-beasts", "middle-earth",
            "lord-of-the-rings", "the-hobbit", "dune", "matrix", "avatar", "planet-of-the-apes", "alien", "predator",
            "terminator", "jurassic", "back-to-the-future", "hunger-games", "conjuring", "breaking-bad", "game-of-thrones",
            "walking-dead", "one-chicago", "bachelor",
        ).forEach { id -> assertTrue(ExploreCatalog[id] != null, "missing franchise $id") }
    }

    @Test
    fun storyOrdersOnlyListTitlesFromTheirOwnCollection() {
        // A story order may only arrange titles the collection itself lists (by curated id), never add new ones.
        ExploreCatalog.all.filter { it.storyOrder != null }.forEach { c ->
            val listed = c.sections.mapNotNull { (it.source as? SectionSource.Titles)?.refs }.flatten().toSet()
            val usesTmdbCollections = c.sections.any { it.source is SectionSource.MovieCollection }
            c.storyOrder!!.forEach { ref ->
                assertTrue(usesTmdbCollections || ref in listed, "${c.id} story order has ${ref.key}, which it doesn't list")
            }
        }
    }

    @Test
    fun awardCollectionsAreLabelledWithTheirCutoff() {
        listOf("oscar-best-picture", "emmy-series", "bafta", "golden-globes", "critics-choice").forEach { id ->
            assertTrue(ExploreCatalog[id]?.subtitle?.contains("2025") == true, "$id should say which ceremonies it covers")
        }
    }

    @Test
    fun episodeCollectionsAreBrowsableAllYear() {
        val browsable = ExploreCatalog.byCategory().flatMap { it.second }.map { it.id }.toSet()
        assertTrue("christmas-episodes" in browsable)
        assertTrue("halloween-episodes" in browsable)
        assertTrue(ExploreCatalog.all.filter { it.episodes != null }.all { HolidayEpisodes.of(it.episodes!!).isNotEmpty() })
    }
}
