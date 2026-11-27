package com.nuvio.app.features.recommendations

import com.nuvio.app.features.explore.CollectionKind
import com.nuvio.app.features.explore.ExploreCatalog
import com.nuvio.app.features.explore.SectionSource

/** A title with the lists TMDB pairs with it. */
data class TitleDetails(val meta: TitleMeta, val recommendations: List<TitleMeta>, val similar: List<TitleMeta>)

data class PersonCredits(val cast: List<PersonalRows.ActorCredit>, val directed: List<TitleMeta>)

data class CollectionParts(val name: String, val parts: List<TitleMeta>)

/** One verified continuity from BannerTV's catalog: the titles it lists and the TMDB film series it includes. */
data class UniverseDef(val id: String, val name: String, val refs: Set<String>, val collectionIds: Set<Int>)

/**
 * Everything the engine reads from metadata providers. The app uses [TmdbRecommendationData]; tests use a fake, so the
 * whole pipeline (seeding, candidates, rows, coordination, caching, profile isolation) runs without a network.
 */
interface RecommendationData {
    /** TMDB id for an id the app stores (an IMDb id, "tmdb:<id>", ...); null when it isn't a film or series. */
    suspend fun tmdbId(appType: String, appId: String): Int?
    suspend fun details(tv: Boolean, tmdbId: Int): TitleDetails?
    suspend fun discover(tv: Boolean, query: Map<String, String>): List<TitleMeta>
    suspend fun personCredits(personId: Int): PersonCredits?
    suspend fun movieCollection(id: Int): CollectionParts?
    /** Whether the title can be watched at home (the check every Home row uses). */
    suspend fun available(meta: TitleMeta): Boolean
    fun today(): String
    /** Requests that failed so far; the engine compares before and after a build to spot a bad network. */
    val failureCount: Int
}

/** The verified continuities: catalog universes whose every title shares one continuity (see ExploreCatalog). */
object Continuities {
    val all: List<UniverseDef> by lazy {
        ExploreCatalog.continuityIds.mapNotNull { id ->
            val c = ExploreCatalog[id] ?: return@mapNotNull null
            if (c.kind != CollectionKind.Franchise) return@mapNotNull null
            val refs = (c.sections.flatMap { (it.source as? SectionSource.Titles)?.refs.orEmpty() } + c.storyOrder.orEmpty())
                .mapTo(HashSet()) { titleKey(it.tv, it.tmdbId) }
            val collections = c.sections.mapNotNullTo(HashSet()) { (it.source as? SectionSource.MovieCollection)?.tmdbCollectionId }
            UniverseDef(c.id, c.title, refs, collections)
        }
    }
}

/** Franchise keys used for diversity and grouping: the verified universe when there is one, else the TMDB film series. */
class FranchiseIndex(private val universes: List<UniverseDef>) {
    private val byRef = HashMap<String, UniverseDef>().apply { universes.forEach { u -> u.refs.forEach { if (it !in this) put(it, u) } } }
    private val byCollection = HashMap<Int, UniverseDef>().apply { universes.forEach { u -> u.collectionIds.forEach { if (it !in this) put(it, u) } } }

    fun universeOf(meta: TitleMeta): UniverseDef? = byRef[meta.key] ?: meta.collectionId?.let { byCollection[it] }

    fun franchiseKey(meta: TitleMeta): String? = universeOf(meta)?.id ?: meta.collectionId?.let { "coll:$it" }

    /** The group a film series belongs to: its universe if any of it is in one, else the series itself. */
    fun groupOf(collectionId: Int, parts: List<TitleMeta>): String =
        byCollection[collectionId]?.id ?: parts.firstNotNullOfOrNull { byRef[it.key] }?.id ?: "coll:$collectionId"
}
