package com.nuvio.app.features.recommendations

import com.nuvio.app.features.explore.CollectionKind
import com.nuvio.app.features.explore.ExploreCatalog
import com.nuvio.app.features.explore.ExploreTmdb
import com.nuvio.app.features.explore.ExploreTmdb.double
import com.nuvio.app.features.explore.ExploreTmdb.excluded
import com.nuvio.app.features.explore.ExploreTmdb.genreIds
import com.nuvio.app.features.explore.ExploreTmdb.int
import com.nuvio.app.features.explore.ExploreTmdb.str
import com.nuvio.app.features.explore.ExploreTmdb.toPreview
import com.nuvio.app.features.explore.SectionSource
import com.nuvio.app.features.home.DigitalAvailability
import com.nuvio.app.features.tmdb.TmdbService
import com.nuvio.app.features.watchprogress.CurrentDateProvider
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

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

/** [RecommendationData] backed by TMDB through Explore's cached client. */
object TmdbRecommendationData : RecommendationData {
    private val lock = Mutex()
    private val ids = HashMap<String, Int?>()

    override val failureCount: Int get() = ExploreTmdb.failureCount

    override fun today(): String = CurrentDateProvider.todayIsoDate()

    override suspend fun tmdbId(appType: String, appId: String): Int? {
        val tv = appType.equals("series", true) || appType.equals("tv", true) || appType.equals("show", true)
        if (!tv && !appType.equals("movie", true)) return null
        if (appId.startsWith("tmdb:")) return appId.removePrefix("tmdb:").toIntOrNull()
        // Only IMDb-style ids can be looked up; others (live sports streams, files) aren't titles.
        if (!appId.startsWith("tt")) return null
        val key = "$appType|$appId"
        lock.withLock { if (ids.containsKey(key)) return ids[key] }
        val found = runCatching { TmdbService.ensureTmdbId(appId, if (tv) "tv" else "movie")?.toIntOrNull() }.getOrNull()
        lock.withLock { ids[key] = found }
        return found
    }

    override suspend fun details(tv: Boolean, tmdbId: Int): TitleDetails? {
        val o = ExploreTmdb.get(
            if (tv) "tv/$tmdbId" else "movie/$tmdbId",
            mapOf("append_to_response" to "recommendations,similar,keywords,credits"),
        ) ?: return null
        if (o.excluded(tv)) return null
        fun list(name: String) = ((o[name] as? JsonObject)?.get("results") as? JsonArray).orEmpty()
            .mapNotNull { it as? JsonObject }.filterNot { it.excluded(tv) }.mapNotNull { it.toLightMeta(tv) }
        return TitleDetails(o.toFullMeta(tv) ?: return null, list("recommendations"), list("similar"))
    }

    override suspend fun discover(tv: Boolean, query: Map<String, String>): List<TitleMeta> =
        ExploreTmdb.results(if (tv) "discover/tv" else "discover/movie", query)
            .filterNot { it.excluded(tv) }.mapNotNull { it.toLightMeta(tv) }

    override suspend fun personCredits(personId: Int): PersonCredits? {
        val o = ExploreTmdb.get("person/$personId/combined_credits") ?: return null
        fun JsonObject.tv() = str("media_type") == "tv"
        val cast = (o["cast"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .filter { it.str("media_type") == "movie" || it.str("media_type") == "tv" }
            .filterNot { it.excluded(it.tv()) }
            .mapNotNull { c -> c.toLightMeta(c.tv())?.let { PersonalRows.ActorCredit(it, c.int("order"), c.str("character"), c.int("episode_count")) } }
        val directed = (o["crew"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .filter { it.str("job") == "Director" || it.str("job") == "Creator" }
            .filterNot { it.excluded(it.tv()) }
            .mapNotNull { it.toLightMeta(it.tv()) }
        return PersonCredits(cast, directed)
    }

    override suspend fun movieCollection(id: Int): CollectionParts? {
        val o = ExploreTmdb.get("collection/$id") ?: return null
        val parts = (o["parts"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .filterNot { it.excluded(false) }
            .mapNotNull { it.toLightMeta(false)?.copy(collectionId = id) }
            .sortedBy { it.releaseDate ?: "9999" }
        val name = o.str("name")?.removeSuffix(" Collection")?.trim() ?: return null
        return CollectionParts(name, parts)
    }

    override suspend fun available(meta: TitleMeta): Boolean =
        runCatching { DigitalAvailability.check(if (meta.tv) "tv" else "movie", meta.tmdbId) != null }.getOrDefault(false)

    // ------------------------------------------------------------------------------------------------ Parsing

    private fun JsonObject.toLightMeta(tv: Boolean): TitleMeta? {
        val id = int("id") ?: return null
        val name = str("title") ?: str("name") ?: return null
        return TitleMeta(
            tmdbId = id,
            tv = tv,
            name = name,
            genres = genreIds(),
            language = str("original_language"),
            releaseDate = str("release_date") ?: str("first_air_date"),
            voteAverage = double("vote_average") ?: 0.0,
            voteCount = int("vote_count") ?: 0,
            popularity = double("popularity") ?: 0.0,
            preview = toPreview(tv),
        )
    }

    private fun JsonObject.toFullMeta(tv: Boolean): TitleMeta? {
        val base = toLightMeta(tv) ?: return null
        val keywordsObj = this["keywords"] as? JsonObject
        val keywords = (keywordsObj?.get(if (tv) "results" else "keywords") as? JsonArray).orEmpty()
            .mapNotNull { (it as? JsonObject)?.int("id") }
        val credits = this["credits"] as? JsonObject
        val cast = (credits?.get("cast") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .mapNotNull { c -> c.int("id")?.let { Person(it, c.str("name") ?: "", c.int("order") ?: 99) } }
            .sortedBy { it.order }.take(12)
        val creators = if (tv) {
            (this["created_by"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                .mapNotNull { c -> c.int("id")?.let { Person(it, c.str("name") ?: "") } }
        } else {
            (credits?.get("crew") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                .filter { it.str("job") == "Director" }
                .mapNotNull { c -> c.int("id")?.let { Person(it, c.str("name") ?: "") } }
        }
        return base.copy(
            keywords = keywords,
            cast = cast,
            creators = creators,
            collectionId = (this["belongs_to_collection"] as? JsonObject)?.int("id"),
        )
    }
}
