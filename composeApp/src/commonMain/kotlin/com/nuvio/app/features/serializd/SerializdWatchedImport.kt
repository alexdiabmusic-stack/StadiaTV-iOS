package com.nuvio.app.features.serializd

import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.tmdb.TmdbService
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watched.WatchedRepository
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * Where history read from Serializd lands in BannerTV: episodes become watched here, with the date Serializd gave, or with the
 * placeholder "unknown" date when it gave none (never today's date, which would pretend the member watched them today). Marks go to
 * the member's BannerTV account as one batch at a time; they are not mirrored to Trakt or Simkl, which the member did not ask for.
 * Nothing in this file writes to Serializd.
 */
internal object SerializdWatchedImport : SerializdImportSink {
    /** 2000-01-01 12:00 UTC, the same placeholder the Letterboxd import uses for a watch with no date. */
    private const val UNKNOWN_DATE_MS = 946_728_000_000L

    override suspend fun apply(profileId: Int, episodes: List<SerializdImportedEpisode>) {
        // The watched list belongs to the profile that is open. Marking another profile's list from here would put the episodes in the wrong place.
        check(profileId == ProfileRepository.activeProfileId) { "Switch to this profile to add its Serializd history to the watched list" }
        val shows = episodes.groupBy { it.showTmdbId }
        // BannerTV's catalog ids are IMDb ids; TMDB's own id is the fallback for a show with no IMDb id.
        val ids = HashMap<Int, String>()
        shows.keys.toList().chunked(8).forEach { chunk ->
            coroutineScope {
                chunk.map { tmdb -> async { tmdb to (runCatching { TmdbService.tmdbToImdb(tmdb, "tv") }.getOrNull() ?: "tmdb:$tmdb") } }.awaitAll()
            }.forEach { (tmdb, id) -> ids[tmdb] = id }
        }
        val items = ArrayList<WatchedItem>(episodes.size)
        for (e in episodes) {
            val id = ids[e.showTmdbId] ?: continue
            if (WatchedRepository.isWatched(id = id, type = "series", season = e.seasonNumber, episode = e.episodeNumber)) continue
            items += WatchedItem(
                id = id, type = "series", name = e.showName.orEmpty(), season = e.seasonNumber, episode = e.episodeNumber,
                videoId = "$id:${e.seasonNumber}:${e.episodeNumber}", markedAtEpochMs = e.watchedAtMs ?: UNKNOWN_DATE_MS,
            )
        }
        // Batches, because each batch is one request to the member's account and a whole library is too big for one.
        items.chunked(100).forEach { WatchedRepository.markWatchedImported(it) }
        if (items.isNotEmpty()) com.nuvio.app.features.settings.profileInsightsAllowBackfill()
    }
}
