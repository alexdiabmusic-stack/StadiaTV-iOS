package com.nuvio.app.features.letterboxd

import com.nuvio.app.features.tmdb.TmdbService
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.WatchedTmdbIndex
import com.nuvio.app.features.watched.WatchedRepository
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** What an import (and the optional marking) did, for the Settings page to show. */
internal data class LetterboxdWatchedImportResult(
    val importedFilms: Int,
    val markedWatched: Int,
    val alreadyWatched: Int,
    val couldNotIdentify: Int,
    val partial: Boolean,
    val message: String?,
    /** Films this run added to the journal (not the whole journal). */
    val newFilms: Int = importedFilms,
)

/**
 * Imports the member's Letterboxd diary and, when they choose, marks every film in it as watched in BannerTV. Marking is its
 * own step so it can also be done later for a journal imported earlier. Nothing is sent to Letterboxd.
 */
internal object LetterboxdWatchedImport {
    private val _status = MutableStateFlow<String?>(null)
    /** One line of progress while this runs, else null. */
    val status: StateFlow<String?> = _status.asStateFlow()

    private const val MAX_RUNS = 25

    /** Reads the whole diary (in runs, because each new film needs a page read) and optionally marks the films watched. */
    suspend fun importDiary(profileId: Int, markWatched: Boolean): LetterboxdWatchedImportResult {
        val manager = LetterboxdRuntime.manager
        var runs = 0
        var newFilms = 0
        var partial = false
        var message: String? = null
        while (runs < MAX_RUNS) {
            runs++
            val r = manager.importDiary(profileId)
            message = r.message
            partial = r.partial
            newFilms += r.newViewings
            if (!r.partial || r.message != null || r.newViewings == 0) break
        }
        val imported = importedFilms(profileId).size
        if (!markWatched) {
            _status.value = null
            return LetterboxdWatchedImportResult(imported, 0, 0, 0, partial, message, newFilms)
        }
        val marked = markImportedWatched(profileId)
        return marked.copy(partial = partial, message = message, newFilms = newFilms)
    }

    /** The films imported from the diary for this profile, one per film. */
    fun importedFilms(profileId: Int): List<LetterboxdViewing> =
        LetterboxdRuntime.manager.engine.viewings.value
            .filter { it.profileId == profileId && it.source == "import" }
            .sortedByDescending { it.completedAtMs }
            .distinctBy { it.tmdbId }

    /** Marks the imported films watched in BannerTV. Films already marked are left alone; safe to run again. */
    suspend fun markImportedWatched(profileId: Int): LetterboxdWatchedImportResult {
        val films = importedFilms(profileId)
        val items = ArrayList<WatchedItem>(films.size)
        var already = 0
        var unknown = 0
        var done = 0
        // IMDb lookups are independent network calls: a few at a time instead of one after another.
        films.chunked(8).forEach { chunk ->
            val resolved = coroutineScope {
                chunk.map { film ->
                    async {
                        if (film.tmdbId <= 0) film to null
                        // BannerTV's catalog ids are IMDb ids; TMDB's own id is the fallback for titles it has no IMDb id for.
                        else film to (runCatching { TmdbService.tmdbToImdb(film.tmdbId, "movie") }.getOrNull() ?: "tmdb:${film.tmdbId}")
                    }
                }.awaitAll()
            }
            // The import already knows each film's TMDB id: remember it with the IMDb id, so recommendations can tell the whole
            // library is watched without looking every film up again.
            WatchedTmdbIndex.recordAll(resolved.mapNotNull { (film, id) -> id?.takeIf { it.startsWith("tt") }?.let { it to film.tmdbId } }.toMap())
            resolved.forEach { (film, id) ->
                done++
                if (id == null) { unknown++; return@forEach }
                if (WatchedRepository.isWatched(id = id, type = "movie")) { already++; return@forEach }
                items += WatchedItem(id = id, type = "movie", name = film.title, poster = film.posterUrl, markedAtEpochMs = film.completedAtMs)
            }
            _status.value = "Matching films $done of ${films.size}"
        }
        // Batches, because each batch is one request to the member's account and a whole library is too big for one.
        items.chunked(100).forEachIndexed { index, batch ->
            _status.value = "Marking films as watched ${minOf((index + 1) * 100, items.size)} of ${items.size}"
            WatchedRepository.markWatchedImported(batch)
        }
        if (items.isNotEmpty()) com.nuvio.app.features.settings.profileInsightsAllowBackfill()
        _status.value = null
        return LetterboxdWatchedImportResult(films.size, items.size, already, unknown, partial = false, message = null)
    }
}
