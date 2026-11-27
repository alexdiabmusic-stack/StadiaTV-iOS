package com.nuvio.app.features.explore

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class CollectionLandingTest {
    @Test fun theHeroIsAPublishedCollectionAndNotRepeatedInTheFeaturedMosaic() {
        val hero = assertNotNull(CollectionLanding.hero())
        assertTrue(hero.published)
        assertTrue(CollectionLanding.featured().none { it.id == hero.id })
    }

    @Test fun theMosaicKeepsEveryCardOnceInAnEditorialRhythm() {
        val items = ExploreCatalog.featured
        val blocks = CollectionLanding.mosaic(items)
        assertEquals(items.map { it.id }, blocks.flatMap { it.items }.map { it.id }, "order and membership kept")
        assertTrue(blocks.first().wide && blocks.first().items.size == 1)
        assertEquals(listOf(false, false), blocks.drop(1).take(2).map { it.wide })
        assertTrue(blocks.filter { it.wide }.all { it.items.size == 1 } && blocks.filter { !it.wide }.all { it.items.size in 1..2 })
        assertEquals(blocks, CollectionLanding.mosaic(items), "the same every time")
    }

    @Test fun theMosaicOfNothingIsNothing() {
        assertTrue(CollectionLanding.mosaic(emptyList()).isEmpty())
    }

    @Test fun everyPublishedCollectionIsInExactlyOneFamilyOrTheFeaturedGroup() {
        val inFamilies = CollectionLanding.families().flatMap { it.collections }.map { it.id }
        assertEquals(inFamilies.size, inFamilies.toSet().size, "no collection twice")
        val featuredOnly = ExploreCatalog.all.filter { it.published && it.category == CollectionCategory.Featured }.map { it.id }.toSet()
        val missing = ExploreCatalog.all.filter { it.published }.map { it.id }.toSet() - inFamilies.toSet() - featuredOnly
        assertTrue(missing.isEmpty(), "collections that would never be shown: $missing")
    }

    @Test fun noFamilyIsEmptyAndTheOrderPutsUniversesFirst() {
        val families = CollectionLanding.families()
        assertTrue(families.all { it.collections.isNotEmpty() })
        assertEquals(CollectionCategory.Universes, families.first().category)
        assertEquals(CollectionLanding.CATEGORY_ORDER.filter { c -> families.any { it.category == c } }, families.map { it.category })
    }
}
