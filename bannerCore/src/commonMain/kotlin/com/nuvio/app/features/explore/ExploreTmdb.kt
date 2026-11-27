package com.nuvio.app.features.explore
import com.nuvio.app.features.tmdb.TmdbRuntime
import com.nuvio.app.features.tmdb.CoreClock

import com.nuvio.app.features.addons.httpGetText
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.tmdb.buildTmdbUrl
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject

/**
 * The TMDB calls behind Explore and the recommendations: one cached GET per URL (a few hours), at most six requests
 * in flight, and the JSON-to-[MetaPreview] mapping every collection shares. A failed request returns null and is not
 * cached, so it is simply asked again next time (offline, or TMDB having a bad moment).
 */
object ExploreTmdb {
    private const val TTL_MS = 6L * 60 * 60 * 1000
    private const val MAX_ENTRIES = 600

    /** Films TMDB doesn't mark adult but that are explicit; kept out of every list (same as Search). */
    val EXPLICIT_MOVIE_IDS = setOf(27)

    /** Talk shows and news: they chart daily and say nothing about taste. */
    val TALK_AND_NEWS = setOf(10767, 10763)

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val permits = Semaphore(6)
    private val lock = Mutex()
    private val cache = LinkedHashMap<String, Pair<Long, JsonObject>>()

    /** Requests that failed (network or a bad answer) since launch. */
    var failureCount: Int = 0
        private set

    fun available(): Boolean = TmdbRuntime.apiKey().isNotBlank()

    /** Forgets every saved answer, so the next request asks TMDB again (a deliberate pull to refresh). */
    suspend fun dropCache() = lock.withLock { cache.clear() }

    suspend fun get(endpoint: String, query: Map<String, String> = emptyMap()): JsonObject? {
        val key = TmdbRuntime.apiKey()
        if (key.isBlank()) return null
        val q = mapOf("language" to TmdbRuntime.language()) + query.mapValues { (_, v) -> expand(v) }
        val url = buildTmdbUrl(endpoint = endpoint, apiKey = key, query = q)
        val now = CoreClock.nowMs()
        lock.withLock { cache[url]?.takeIf { now - it.first < TTL_MS }?.let { return it.second } }
        val body = runCatching { permits.withPermit { httpGetText(url) } }.getOrNull()
        val obj = body?.let { runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull() }
        if (obj == null) {
            lock.withLock { failureCount++ }
            return null
        }
        lock.withLock {
            cache[url] = now to obj
            if (cache.size > MAX_ENTRIES) cache.keys.take(cache.size - MAX_ENTRIES).forEach(cache::remove)
        }
        return obj
    }

    /** Date placeholders in catalog queries, filled in when the request is made. */
    private fun expand(value: String): String {
        if (!value.contains('{')) return value
        val today = CoreClock.todayIsoDate()
        return value
            .replace("{TODAY}", today)
            .replace("{TWO_YEARS_AGO}", shiftYears(today, -2))
    }

    private fun shiftYears(isoDate: String, years: Int): String {
        val year = isoDate.take(4).toIntOrNull() ?: return isoDate
        return (year + years).toString().padStart(4, '0') + isoDate.drop(4)
    }

    /** A results page as JSON objects. */
    suspend fun results(endpoint: String, query: Map<String, String>, page: Int = 1): List<JsonObject> =
        (get(endpoint, query + ("page" to page.toString()))?.get("results") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }

    fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }
    fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
    fun JsonObject.double(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
    fun JsonObject.genreIds(): List<Int> =
        (this["genre_ids"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull }
            ?: (this["genres"] as? JsonArray)?.mapNotNull { (it as? JsonObject)?.int("id") }
            ?: emptyList()

    /** True for something that should never appear in a list: adult, explicit, talk or news, or no poster. */
    fun JsonObject.excluded(tv: Boolean): Boolean =
        this["adult"]?.toString() == "true" ||
            (!tv && int("id") in EXPLICIT_MOVIE_IDS) ||
            genreIds().any { it in TALK_AND_NEWS } ||
            str("poster_path") == null

    /** The app's preview of a TMDB title, opened by its "tmdb:<id>" id like every other TMDB-backed list. */
    fun JsonObject.toPreview(tv: Boolean): MetaPreview? {
        val id = int("id") ?: return null
        val name = str("title") ?: str("name") ?: return null
        val poster = str("poster_path")?.let { "https://image.tmdb.org/t/p/w500$it" } ?: return null
        val date = str("release_date") ?: str("first_air_date")
        return MetaPreview(
            id = "tmdb:$id",
            type = if (tv) "series" else "movie",
            name = name,
            poster = poster,
            rawPosterUrl = poster,
            banner = str("backdrop_path")?.let { "https://image.tmdb.org/t/p/w780$it" },
            description = str("overview"),
            releaseInfo = date?.take(4),
            rawReleaseDate = date,
            popularity = double("popularity"),
            voteCount = int("vote_count"),
            language = str("original_language"),
            // Lists carry genre ids, so the names cost nothing; Browse filters by them without a request per title.
            genres = genreIds().mapNotNull(GENRE_NAMES::get).distinct(),
        )
    }

    /** TMDB's genre ids (film and series) and their names. */
    val GENRE_NAMES: Map<Int, String> = mapOf(
        28 to "Action", 12 to "Adventure", 16 to "Animation", 35 to "Comedy", 80 to "Crime", 99 to "Documentary", 18 to "Drama",
        10751 to "Family", 14 to "Fantasy", 36 to "History", 27 to "Horror", 10402 to "Music", 9648 to "Mystery", 10749 to "Romance",
        878 to "Science Fiction", 10770 to "TV Movie", 53 to "Thriller", 10752 to "War", 37 to "Western",
        10759 to "Action & Adventure", 10762 to "Kids", 10763 to "News", 10764 to "Reality", 10765 to "Sci-Fi & Fantasy",
        10766 to "Soap", 10767 to "Talk", 10768 to "War & Politics",
    )

    /** TMDB's own id from a "tmdb:<id>" preview id, or null for other ids. */
    fun tmdbId(previewId: String): Int? = previewId.removePrefix("tmdb:").takeIf { previewId.startsWith("tmdb:") }?.toIntOrNull()
}
