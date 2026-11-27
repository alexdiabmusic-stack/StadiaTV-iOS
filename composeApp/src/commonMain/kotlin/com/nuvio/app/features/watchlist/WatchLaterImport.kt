package com.nuvio.app.features.watchlist

import com.nuvio.app.features.addons.httpGetText
import com.nuvio.app.features.library.LibraryClock
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.music.data.MusicStorage
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tmdb.TmdbService
import com.nuvio.app.features.tmdb.TmdbSettingsRepository
import com.nuvio.app.features.tmdb.buildTmdbUrl
import com.nuvio.app.features.watched.WatchedRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Puts a watchlist from Letterboxd or Serializd into BannerTV's My List (the local Library list, the one the + button adds to).
 *
 * The decisions live in [WatchLaterPlanner]: only additions, nothing already there is touched or duplicated, a film already watched in
 * BannerTV is left out, and a title the member took out of My List is not put back (the titles dealt with are remembered per service and
 * profile). This file does the work around it: finding each title's BannerTV id (IMDb, like the rest of the catalog), a poster and a few
 * facts from TMDB, and one batch save. Nothing here writes to Letterboxd or Serializd.
 */
internal object WatchLaterImport : WatchlistSink {
    private const val STORE = "watchlist_import"
    private val json = Json { ignoreUnknownKeys = true }

    private class Facts(val posterPath: String?, val backdropPath: String?, val overview: String?, val genres: List<String>, val year: String?)

    override suspend fun apply(profileId: Int, source: String, titles: List<WatchlistTitle>): WatchlistApplyResult {
        // My List belongs to the profile that is open: adding another profile's watchlist here would put it in the wrong list.
        check(profileId == ProfileRepository.activeProfileId) { "Switch to this profile to add its watchlist to My List" }
        val distinct = titles.distinctBy { it.key }
        val ids = resolveIds(distinct)
        val handledBefore = readHandled(source, profileId)
        val plan = WatchLaterPlanner.plan(
            titles = distinct,
            handledBefore = handledBefore,
            isInMyList = { t -> LibraryRepository.isInLocalList(ids.getValue(t.key), typeOf(t)) },
            isWatched = { t -> WatchedRepository.isWatched(id = ids.getValue(t.key), type = "movie") },
        )
        if (plan.add.isNotEmpty()) {
            val facts = loadFacts(plan.add)
            val base = LibraryClock.nowEpochMs()
            // The watchlist lists its newest first; My List sorts by when a title was saved, so the first one gets the latest time.
            val items = plan.add.mapIndexed { index, t ->
                val f = facts[t.key]
                val id = ids.getValue(t.key)
                LibraryItem(
                    id = id, type = typeOf(t), name = t.name,
                    poster = (t.posterPath ?: f?.posterPath)?.let { "$IMAGE_BASE/w500$it" },
                    banner = f?.backdropPath?.let { "$IMAGE_BASE/w1280$it" },
                    description = f?.overview, releaseInfo = t.year ?: f?.year, genres = f?.genres.orEmpty(),
                    imdbId = id.takeIf { it.startsWith("tt") }, tmdbId = t.tmdbId,
                    savedAtEpochMs = base - index * 1_000L,
                )
            }
            LibraryRepository.saveAll(items)
        }
        // Remembered only once the save went through, so a failure is tried again next time.
        writeHandled(source, profileId, plan.handled)
        return WatchlistApplyResult(plan.add.size, plan.alreadyThere, plan.removedByMember, plan.alreadyWatched, 0)
    }

    private fun typeOf(t: WatchlistTitle) = if (t.isSeries) "series" else "movie"

    /** BannerTV's catalog ids are IMDb ids; TMDB's own id is the fallback for a title it has no IMDb id for. */
    private suspend fun resolveIds(titles: List<WatchlistTitle>): Map<String, String> {
        val out = HashMap<String, String>()
        titles.chunked(8).forEach { chunk ->
            coroutineScope {
                chunk.map { t ->
                    async { t.key to (runCatching { TmdbService.tmdbToImdb(t.tmdbId, if (t.isSeries) "tv" else "movie") }.getOrNull() ?: "tmdb:${t.tmdbId}") }
                }.awaitAll()
            }.forEach { (k, v) -> out[k] = v }
        }
        return out
    }

    /** A poster, backdrop, overview and genres for the titles about to be added (a few at a time). A title TMDB does not answer for is added without them. */
    private suspend fun loadFacts(titles: List<WatchlistTitle>): Map<String, Facts> {
        val apiKey = TmdbSettingsRepository.effectiveApiKey().takeIf { it.isNotBlank() } ?: return emptyMap()
        val out = HashMap<String, Facts>()
        titles.chunked(8).forEach { chunk ->
            coroutineScope {
                chunk.map { t -> async { t.key to fetchFacts(t, apiKey) } }.awaitAll()
            }.forEach { (k, v) -> if (v != null) out[k] = v }
        }
        return out
    }

    private suspend fun fetchFacts(t: WatchlistTitle, apiKey: String): Facts? = try {
        val root = json.parseToJsonElement(httpGetText(buildTmdbUrl(endpoint = (if (t.isSeries) "tv/" else "movie/") + t.tmdbId, apiKey = apiKey, query = mapOf("language" to "en-US")))) as? JsonObject
        root?.let {
            fun str(k: String) = (it[k] as? JsonPrimitive)?.contentOrNull?.takeIf { v -> v.isNotBlank() }
            Facts(
                posterPath = str("poster_path"), backdropPath = str("backdrop_path"), overview = str("overview"),
                genres = (it["genres"] as? kotlinx.serialization.json.JsonArray).orEmpty().mapNotNull { g -> (g as? JsonObject)?.get("name")?.jsonPrimitive?.contentOrNull },
                year = (str("release_date") ?: str("first_air_date"))?.take(4),
            )
        }
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        null
    }

    private fun readHandled(source: String, profileId: Int): Set<String> =
        MusicStorage.getString(STORE, "$source.$profileId")?.let { runCatching { json.decodeFromString(ListSerializer(String.serializer()), it) }.getOrNull() }.orEmpty().toSet()

    private fun writeHandled(source: String, profileId: Int, handled: Set<String>) =
        MusicStorage.putString(STORE, "$source.$profileId", json.encodeToString(ListSerializer(String.serializer()), handled.toList()))

    /** Forgets what was dealt with for a profile (its Letterboxd or Serializd account was disconnected with its local history). */
    fun forget(source: String, profileId: Int) = MusicStorage.remove(STORE, "$source.$profileId")

    private const val IMAGE_BASE = "https://image.tmdb.org/t/p"
}
