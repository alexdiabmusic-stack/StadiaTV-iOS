package com.nuvio.app.features.recommendations
import com.nuvio.app.features.tmdb.CoreClock

import com.nuvio.app.features.explore.ExploreTmdb
import com.nuvio.app.features.explore.ExploreTmdb.double
import com.nuvio.app.features.explore.ExploreTmdb.excluded
import com.nuvio.app.features.explore.ExploreTmdb.genreIds
import com.nuvio.app.features.explore.ExploreTmdb.int
import com.nuvio.app.features.explore.ExploreTmdb.str
import com.nuvio.app.features.explore.ExploreTmdb.toPreview
import com.nuvio.app.features.home.DigitalAvailability
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/** [RecommendationData] backed by TMDB through Explore's cached client. */
object TmdbRecommendationData : RecommendationData {
    private val lock = Mutex()
    private val ids = HashMap<String, Int?>()

    override val failureCount: Int get() = ExploreTmdb.failureCount

    override fun today(): String = CoreClock.todayIsoDate()

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

    /** Somewhere on the device to keep trimmed title details between launches; null (the default) keeps nothing. */
    interface DiskCache {
        fun read(path: String): String?
        fun write(path: String, payload: String)
    }

    @kotlin.concurrent.Volatile
    var diskCache: DiskCache? = null

    private val diskJson = kotlinx.serialization.json.Json { ignoreUnknownKeys = true; isLenient = true }
    private const val DETAILS_MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000

    /**
     * Details for a title, from the saved copy when it is under 30 days old, otherwise from TMDB (then saved). A saved copy
     * holds only what the engine reads (a few KB), so a history of a few hundred titles stays small and a rebuild needs no
     * network for the titles it already knows.
     */
    private suspend fun detailsObject(tv: Boolean, tmdbId: Int): JsonObject? {
        val path = "recommendations/details_${if (tv) "tv" else "movie"}_$tmdbId.json"
        val disk = diskCache
        val now = CoreClock.nowMs()
        disk?.read(path)?.let { text ->
            val saved = runCatching { diskJson.parseToJsonElement(text) as? JsonObject }.getOrNull()
            val at = (saved?.get("at") as? kotlinx.serialization.json.JsonPrimitive)?.content?.toLongOrNull()
            val body = saved?.get("o") as? JsonObject
            if (body != null && at != null && now - at < DETAILS_MAX_AGE_MS) return body
        }
        val fresh = ExploreTmdb.get(
            if (tv) "tv/$tmdbId" else "movie/$tmdbId",
            mapOf("append_to_response" to "recommendations,similar,keywords,credits"),
        ) ?: return null
        val trimmed = trimDetails(fresh, tv)
        disk?.let { d -> runCatching { d.write(path, JsonObject(mapOf("at" to kotlinx.serialization.json.JsonPrimitive(now.toString()), "o" to trimmed)).toString()) } }
        return trimmed
    }

    private val LIST_KEYS = setOf(
        "id", "title", "name", "poster_path", "backdrop_path", "genre_ids", "release_date", "first_air_date",
        "vote_average", "vote_count", "popularity", "original_language", "adult",
    )

    /** Keeps what [toFullMeta] and the recommendation lists read, and drops the rest of the (large) TMDB answer. */
    internal fun trimDetails(o: JsonObject, tv: Boolean): JsonObject {
        fun trimList(name: String): kotlinx.serialization.json.JsonElement {
            val results = ((o[name] as? JsonObject)?.get("results") as? JsonArray).orEmpty().take(20)
                .mapNotNull { it as? JsonObject }.map { r -> JsonObject(r.filterKeys { it in LIST_KEYS }) }
            return JsonObject(mapOf("results" to JsonArray(results)))
        }
        val credits = o["credits"] as? JsonObject
        val cast = (credits?.get("cast") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.take(12)
            .map { c -> JsonObject(c.filterKeys { it == "id" || it == "name" || it == "order" }) }
        val crew = (credits?.get("crew") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .filter { it["job"]?.let { j -> (j as? kotlinx.serialization.json.JsonPrimitive)?.content } == "Director" }
            .map { c -> JsonObject(c.filterKeys { it == "id" || it == "name" || it == "job" }) }
        val keep = o.filterKeys {
            it in LIST_KEYS || it == "genres" || it == "belongs_to_collection" || it == "keywords" || it == "created_by" || it == "adult"
        }
        val createdBy = (o["created_by"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .map { c -> JsonObject(c.filterKeys { it == "id" || it == "name" }) }
        return JsonObject(
            keep + mapOf(
                "credits" to JsonObject(mapOf("cast" to JsonArray(cast), "crew" to JsonArray(crew))),
                "created_by" to JsonArray(createdBy),
                "recommendations" to trimList("recommendations"),
                "similar" to trimList("similar"),
            ),
        )
    }

    override suspend fun details(tv: Boolean, tmdbId: Int): TitleDetails? {
        val o = detailsObject(tv, tmdbId) ?: return null
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
