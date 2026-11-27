package com.nuvio.app.features.letterboxd

import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** A small string store the Letterboxd code keeps its caches and queues in. Scoped by the caller's key names. */
interface LetterboxdKeyValue {
    fun read(key: String): String?
    fun write(key: String, value: String?)
}

/** Resolved films, kept between launches. A found film is trusted for a long time; a miss only briefly. */
class LetterboxdFilmCache(private val store: LetterboxdKeyValue, private val now: () -> Long) {
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Mutex()
    private var films: MutableMap<Int, LetterboxdFilm>? = null
    private var misses: MutableMap<Int, Long>? = null

    private fun loaded(): MutableMap<Int, LetterboxdFilm> = films ?: run {
        val raw = store.read(FILMS_KEY)
        val parsed = raw?.let { runCatching { json.decodeFromString<List<LetterboxdFilm>>(it) }.getOrNull() }.orEmpty()
        parsed.associateByTo(LinkedHashMap()) { it.tmdbId }.also { films = it }
    }

    private fun loadedMisses(): MutableMap<Int, Long> = misses ?: run {
        val raw = store.read(MISSES_KEY)
        (raw?.let { runCatching { json.decodeFromString(MapSerializer(String.serializer(), Long.serializer()), it) }.getOrNull() }.orEmpty())
            .mapKeys { it.key.toInt() }.toMutableMap().also { misses = it }
    }

    suspend fun film(tmdbId: Int): LetterboxdFilm? = lock.withLock {
        loaded()[tmdbId]?.takeIf { now() - it.resolvedAtMs < FILM_TTL_MS }
    }

    /** True when this id was recently found not to be a film Letterboxd has. */
    suspend fun recentlyMissing(tmdbId: Int): Boolean = lock.withLock { loadedMisses()[tmdbId]?.let { now() - it < MISS_TTL_MS } == true }

    suspend fun put(film: LetterboxdFilm) = lock.withLock {
        val map = loaded(); map[film.tmdbId] = film
        loadedMisses().remove(film.tmdbId)
        if (map.size > MAX_FILMS) map.keys.take(map.size - MAX_FILMS).forEach(map::remove)
        store.write(FILMS_KEY, json.encodeToString(map.values.toList()))
        store.write(MISSES_KEY, json.encodeToString(MapSerializer(String.serializer(), Long.serializer()), loadedMisses().mapKeys { it.key.toString() }))
    }

    suspend fun putMiss(tmdbId: Int) = lock.withLock {
        val m = loadedMisses(); m[tmdbId] = now()
        store.write(MISSES_KEY, json.encodeToString(MapSerializer(String.serializer(), Long.serializer()), m.mapKeys { it.key.toString() }))
    }

    suspend fun forget(tmdbId: Int) = lock.withLock {
        val map = loaded(); map.remove(tmdbId)
        store.write(FILMS_KEY, json.encodeToString(map.values.toList()))
    }

    companion object {
        private const val FILMS_KEY = "letterboxd_films_v1"
        private const val MISSES_KEY = "letterboxd_film_misses_v1"
        const val FILM_TTL_MS = 90L * 24 * 60 * 60 * 1000
        const val MISS_TTL_MS = 24L * 60 * 60 * 1000
        private const val MAX_FILMS = 4000
    }
}

/** A write the site accepted. Acceptance is not confirmation: the diary is read back before anything is called synced. */
data class LetterboxdWriteAccepted(val endpoint: String)

/**
 * The website-session Letterboxd client: TMDB film lookup, diary reads, diary writes and film ratings, the way
 * Jellyscribe's LetterboxdScraper and LetterboxdDiary do them. It never retries a write itself; the sync engine decides.
 */
class LetterboxdWebService(
    private val session: LetterboxdSession,
    private val cache: LetterboxdFilmCache,
    private val now: () -> Long = { kotlin.time.Clock.System.now().toEpochMilliseconds() },
    private val pause: suspend (Long) -> Unit = { delay(it) },
    /** Spacing between page requests, so a run of lookups does not look like a crawler. */
    private val pageSpacingMs: Long = 1_200L,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val pace = Mutex()
    private var lastRequestAt = 0L

    val username: String get() = session.username

    private suspend fun spaced(spacingMs: Long = pageSpacingMs) = pace.withLock {
        val wait = lastRequestAt + spacingMs - now()
        if (wait > 0) pause(wait)
        lastRequestAt = now()
    }

    /** Whether the session is still signed in. */
    suspend fun validateSession(): Boolean = try { session.validate(); true } catch (e: LetterboxdException.SessionExpired) { false }

    // ------------------------------------------------------------------ film matching

    /**
     * TMDB movie id to the Letterboxd film: `/tmdb/{id}` leads to the film page, whose markup holds the ids. The page must
     * itself be for that TMDB movie (and not a TV entry), or the match is refused. Results are cached.
     */
    suspend fun resolveFilm(tmdbId: Int): LetterboxdFilm {
        cache.film(tmdbId)?.let { return it }
        if (cache.recentlyMissing(tmdbId)) throw LetterboxdException.FilmNotFound("TMDB $tmdbId was not found on Letterboxd recently")
        spaced()
        val lookup = session.send(LetterboxdRequest("GET", "/tmdb/$tmdbId", session.navHeaders()))
        if (lookup.status == 404) { cache.putMiss(tmdbId); throw LetterboxdException.FilmNotFound("TMDB $tmdbId is not on Letterboxd") }
        if (lookup.status !in 200..299) throw LetterboxdException.Server(lookup.status)
        val slug = LetterboxdHtml.filmSlug(lookup.body) ?: throw LetterboxdException.FilmNotFound("TMDB $tmdbId did not lead to a film page")

        spaced()
        val filmPage = session.send(LetterboxdRequest("GET", "/film/$slug/", session.navHeaders("https://letterboxd.com/tmdb/$tmdbId")))
        if (filmPage.status == 404) { cache.putMiss(tmdbId); throw LetterboxdException.FilmNotFound("Film page for $slug is missing") }
        if (filmPage.status !in 200..299) throw LetterboxdException.Server(filmPage.status)
        val entry = LetterboxdHtml.tmdbEntry(filmPage.body)
        if (entry.isTv) { cache.putMiss(tmdbId); throw LetterboxdException.NotAFilm("TMDB $tmdbId matched a TV entry ($slug), not a film") }
        // The page's own TMDB id must agree with the one asked for: a remake or a namesake is a different film.
        if (entry.movieId != null && entry.movieId != tmdbId) {
            cache.putMiss(tmdbId)
            throw LetterboxdException.FilmNotFound("Letterboxd matched TMDB $tmdbId to a page for TMDB ${entry.movieId}")
        }
        val (filmId, productionId) = LetterboxdHtml.filmIdentifiers(filmPage.body, slug, filmPage.headers["x-letterboxd-identifier"])
            ?: throw LetterboxdException.Unexpected("Could not read the film ids on /film/$slug/ (the page layout may have changed)")
        return LetterboxdFilm(tmdbId, slug, filmId, productionId, now()).also { cache.put(it) }
    }

    // ------------------------------------------------------------------ diary reads

    /**
     * The member's diary dates for [film]. A 404 is the site's answer for "no entry". Any other failure is an error: reading
     * a failed check as "not logged" would post a duplicate of a film already on the diary.
     */
    suspend fun diaryInfo(film: LetterboxdFilm): LetterboxdDiaryInfo {
        spaced()
        val r = session.send(LetterboxdRequest("GET", "/${session.username}/film/${film.slug}/diary/", session.navHeaders()))
        if (r.status == 404) return LetterboxdDiaryInfo(emptyList())
        if (r.status !in 200..299) throw LetterboxdException.Server(r.status)
        if (LetterboxdHtml.isSignInPage(r.body)) throw LetterboxdException.SessionExpired("Letterboxd served its sign-in page")
        return LetterboxdDiaryInfo(LetterboxdHtml.diaryDates(r.body).distinct().sorted())
    }

    // ------------------------------------------------------------------ diary write

    /**
     * Logs a viewing: `/api/v0/production-log-entries` with the production id, falling back to `/api/v0/log-entries` with
     * the film id when the first answers 404. A rating or a review rides on the same entry. Throws on any failure and never
     * replays: a lost reply surfaces as [LetterboxdException.NoReplyAfterSend] so the caller reconciles first.
     */
    suspend fun writeDiary(write: LetterboxdDiaryWrite): LetterboxdWriteAccepted {
        session.refreshCsrf()
        for (endpoint in DIARY_ENDPOINTS) {
            val payload = diaryPayload(endpoint, write)
            val r = session.send(
                LetterboxdRequest("POST", endpoint, session.apiHeaders(write.film.slug), json = payload),
                expectJson = false,
            )
            if (r.status == 404) continue
            if (r.status in 200..299) {
                if (!LetterboxdHtml.looksLikeJson(r.body)) {
                    throw if (LetterboxdHtml.isSignInPage(r.body)) LetterboxdException.SessionExpired("Letterboxd served its sign-in page")
                    else LetterboxdException.Unexpected("Letterboxd answered a diary write with a page, not data")
                }
                return LetterboxdWriteAccepted(endpoint)
            }
            val text = r.body.replace(Regex("\\s+"), " ")
            if (text.contains("expired", true) || text.contains("try again", true)) throw LetterboxdException.Server(r.status)
            throw LetterboxdException.Unexpected("Letterboxd returned ${r.status} for the diary write")
        }
        throw LetterboxdException.Unsupported("Letterboxd's diary endpoints were not found (404)")
    }

    internal fun diaryPayload(endpoint: String, w: LetterboxdDiaryWrite): String = buildJsonObject {
        put("diaryDetails", buildJsonObject { put("diaryDate", w.diaryDate); put("rewatch", w.rewatch) })
        put("tags", JsonArray(emptyList()))
        put("like", w.liked)
        w.stars?.let { put("rating", it) }
        if (!w.reviewText.isNullOrBlank()) put("review", buildJsonObject { put("text", w.reviewText); put("containsSpoilers", w.containsSpoilers) })
        // The production endpoint takes the production id; the plain one takes the film id.
        if (endpoint.contains("production") && !w.film.productionId.isNullOrEmpty()) put("productionId", w.film.productionId)
        else put("filmId", w.film.filmId)
    }.toString()

    // ------------------------------------------------------------------ rating

    /**
     * Sets the film rating (the one on the film page and profile) through the rate action: `POST /s/film:{id}/rate/` with the
     * rating on a 1 to 10 scale. Only an explicit `"result": true` counts.
     */
    suspend fun rateFilm(film: LetterboxdFilm, stars: Double) {
        require(LetterboxdRating.isValid(stars) && stars >= 0.5) { "Stars must be 0.5 to 5.0 in half steps" }
        session.refreshCsrf()
        val r = session.send(
            LetterboxdRequest(
                "POST", "/s/film:${film.filmId}/rate/", session.apiHeaders(film.slug),
                form = mapOf("rating" to LetterboxdRating.toSiteScale(stars).toString(), "__csrf" to session.csrf),
            ),
        )
        if (r.status !in 200..299) throw LetterboxdException.Unexpected("Rating returned ${r.status}")
        LetterboxdHtml.siteActionFailure(r.body)?.let { throw LetterboxdException.Unexpected("Letterboxd did not confirm the rating: $it") }
    }

    // ------------------------------------------------------------------ import

    /** One page of the member's watched films with their ratings, plus whether another page follows. */
    suspend fun watchedFilmsPage(page: Int): Pair<List<Pair<String, Double?>>, Boolean> {
        val (films, more) = watchedGridPage(page)
        return films.map { it.slug to it.stars } to more
    }

    /** One page of the member's watched-films grid (every film they have marked watched, dated or not), plus whether another follows. */
    suspend fun watchedGridPage(page: Int): Pair<List<LetterboxdGridFilm>, Boolean> {
        spaced()
        val path = if (page <= 1) "/${session.username}/films/" else "/${session.username}/films/page/$page/"
        val r = session.send(LetterboxdRequest("GET", path, session.navHeaders()))
        if (r.status == 404 && page > 1) return emptyList<LetterboxdGridFilm>() to false
        if (r.status !in 200..299) throw LetterboxdException.Server(r.status)
        if (LetterboxdHtml.isSignInPage(r.body)) throw LetterboxdException.SessionExpired("Letterboxd served its sign-in page")
        return LetterboxdHtml.watchedGrid(r.body) to LetterboxdHtml.hasNextPage(r.body, page)
    }

    /**
     * One page of the member's watchlist (`/{user}/watchlist/`, then `/page/N/`): its films, whether another page follows, and the total the
     * page declares. An empty later page is the end, not an error.
     */
    suspend fun watchlistPage(page: Int): LetterboxdWatchlistPage {
        spaced()
        val path = if (page <= 1) "/${session.username}/watchlist/" else "/${session.username}/watchlist/page/$page/"
        val r = session.send(LetterboxdRequest("GET", path, session.navHeaders()))
        if (r.status == 404 && page > 1) return LetterboxdWatchlistPage(emptyList(), false, null)
        if (r.status !in 200..299) throw LetterboxdException.Server(r.status)
        if (LetterboxdHtml.isSignInPage(r.body)) throw LetterboxdException.SessionExpired("Letterboxd served its sign-in page")
        return LetterboxdWatchlistPage(LetterboxdHtml.watchedGrid(r.body), LetterboxdHtml.hasNextPage(r.body, page), LetterboxdHtml.watchlistCount(r.body))
    }

    /** One page of the member's diary (newest first), plus whether another page follows. */
    suspend fun diaryPage(page: Int): Pair<List<LetterboxdDiaryRow>, Boolean> {
        spaced()
        // The site's own address for the film diary; the older /films/diary/ form only redirects here.
        val path = if (page <= 1) "/${session.username}/diary/" else "/${session.username}/diary/films/page/$page/"
        val r = session.send(LetterboxdRequest("GET", path, session.navHeaders()))
        if (r.status == 404) return emptyList<LetterboxdDiaryRow>() to false
        if (r.status !in 200..299) throw LetterboxdException.Server(r.status)
        if (LetterboxdHtml.isSignInPage(r.body)) throw LetterboxdException.SessionExpired("Letterboxd served its sign-in page")
        return LetterboxdHtml.diaryRows(r.body) to LetterboxdHtml.hasNextPage(r.body, page)
    }

    /**
     * The TMDB movie id for a film slug (its page names it), or null for a TV entry. A page that is missing is null; anything
     * else that is not a page (a bot check, rate limit, server error) is thrown so an import stops instead of calling every
     * film "unmatched". Paced faster than member-facing requests because an import reads one page per film.
     */
    suspend fun tmdbIdForSlug(slug: String): Int? {
        spaced(IMPORT_SPACING_MS)
        val r = session.send(LetterboxdRequest("GET", "/film/$slug/", session.navHeaders()))
        if (r.status == 404 || r.status == 410) return null
        if (r.status !in 200..299) throw LetterboxdException.Server(r.status)
        return LetterboxdHtml.tmdbEntry(r.body).movieId
    }

    private companion object {
        const val IMPORT_SPACING_MS = 350L
        val DIARY_ENDPOINTS = listOf("/api/v0/production-log-entries", "/api/v0/log-entries")
    }
}
