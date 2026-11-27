package com.nuvio.app.features.watched

import com.nuvio.app.features.music.data.MusicStorage
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * Which TMDB film each watched IMDb id is, kept on the device. The recommendation engine looks titles up one by one, so it can
 * only afford a sample; this makes every watched film known by id, whichever service it came from (a Letterboxd import knows
 * the id at the moment it marks a film, others are looked up once in the background). Only films still on the watched list are
 * reported, so un-marking a film takes it out again.
 */
internal object WatchedTmdbIndex {
    private const val STORE = "watched_tmdb_index"
    private const val KEY = "movies_v1"
    private const val RESOLVE_PER_RUN = 2_500
    private const val RESOLVE_PARALLEL = 6

    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = MapSerializer(String.serializer(), Int.serializer())
    private val lock = Mutex()
    private val map: MutableMap<String, Int> by lazy {
        (MusicStorage.getString(STORE, KEY)?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() } ?: emptyMap()).toMutableMap()
    }
    private val triedThisSession = HashSet<String>()
    private val reverse = HashMap<Int, String>()

    private val _version = MutableStateFlow(0)
    /** Changes whenever the index learns something, so screens that use it rebuild. */
    val version: StateFlow<Int> = _version.asStateFlow()

    private fun save() {
        MusicStorage.putString(STORE, KEY, json.encodeToString(serializer, map))
        _version.value = _version.value + 1
    }

    /** Remembers IMDb id -> TMDB id for films whose TMDB id is already known (an import). */
    suspend fun recordAll(pairs: Map<String, Int>) {
        if (pairs.isEmpty()) return
        lock.withLock {
            var changed = false
            pairs.forEach { (imdb, tmdb) -> if (tmdb > 0 && map[imdb] != tmdb) { map[imdb] = tmdb; changed = true } }
            if (changed) { reverse.clear(); save() }
        }
    }

    /** The IMDb id stored for a TMDB film, when the index has one. */
    suspend fun imdbFor(tmdbId: Int): String? = lock.withLock {
        if (reverse.isEmpty()) map.forEach { (imdb, tmdb) -> reverse[tmdb] = imdb }
        reverse[tmdbId]
    }

    /** TMDB ids of the films in [items] that the index knows (movies only; a "tmdb:<id>" id is its own answer). */
    suspend fun tmdbIdsOf(items: Collection<WatchedItem>): Set<Int> = lock.withLock {
        val out = HashSet<Int>()
        items.forEach { item ->
            if (item.season != null || item.episode != null) return@forEach
            if (!item.type.equals("movie", true) && !item.type.equals("film", true)) return@forEach
            when {
                item.id.startsWith("tmdb:") -> item.id.removePrefix("tmdb:").toIntOrNull()?.let(out::add)
                item.id.startsWith("tt") -> map[item.id]?.let(out::add)
            }
        }
        out
    }

    /**
     * Looks up, a few at a time, the TMDB id of watched films the index doesn't know yet. Each film is tried once per launch,
     * and at most [RESOLVE_PER_RUN] per call, so one pass learns a library of a couple of thousand films in about a minute without hammering the service.
     */
    suspend fun resolveMissing(items: Collection<WatchedItem>) {
        val todo = lock.withLock {
            items.asSequence()
                .filter { it.season == null && it.episode == null && it.id.startsWith("tt") && (it.type.equals("movie", true)) }
                .map { it.id }.distinct()
                .filter { it !in map && it !in triedThisSession }
                .take(RESOLVE_PER_RUN).toList().also { triedThisSession += it }
        }
        if (todo.isEmpty()) return
        val gate = Semaphore(RESOLVE_PARALLEL)
        val found = coroutineScope {
            todo.map { imdb ->
                async {
                    gate.withPermit {
                        try {
                            TmdbService.ensureTmdbId(imdb, "movie")?.toIntOrNull()?.let { imdb to it }
                        } catch (e: CancellationException) {
                            throw e
                        } catch (_: Throwable) {
                            null
                        }
                    }
                }
            }.awaitAll().filterNotNull().toMap()
        }
        recordAll(found)
    }
}
