package com.nuvio.app.features.recommendations

import com.nuvio.app.core.storage.AppFileCache
import com.nuvio.app.features.letterboxd.LetterboxdViewing
import com.nuvio.app.features.library.LibraryItem
import com.nuvio.app.features.watched.WatchedClock
import com.nuvio.app.features.watched.WatchedTmdbIndex
import com.nuvio.app.features.watched.WatchedItem
import com.nuvio.app.features.watchprogress.WatchProgressEntry

/**
 * The engine lives in BannerCore and knows nothing of this app's stores. These map the app's own items to the
 * engine's evidence types, and connect it to the TMDB-backed metadata provider.
 */
/**
 * A film imported from Letterboxd with no diary entry carries a placeholder date (see LetterboxdViewing.UNDATED). The
 * engine reads it as "watched some time ago": two years back, so it counts towards long-term taste without passing for
 * recent viewing and without crowding out the films whose dates are real.
 */
private const val UNDATED_IMPORT_MARKED_AT_MS = LetterboxdViewing.UNDATED_EPOCH_DAY * 86_400_000L + 12 * 3_600_000L
private const val UNDATED_AS_AGO_MS = 2L * 365 * 86_400_000L

internal fun WatchedItem.toEvidence() = WatchedEvidence(
    type = type, id = id, name = name, season = season, episode = episode,
    markedAtEpochMs = if (markedAtEpochMs == UNDATED_IMPORT_MARKED_AT_MS) WatchedClock.nowEpochMs() - UNDATED_AS_AGO_MS else markedAtEpochMs,
)

internal fun WatchProgressEntry.toEvidence() = ProgressEvidence(
    parentMetaType = parentMetaType, parentMetaId = parentMetaId, title = title, isCompleted = isCompleted,
    progressPercent = progressPercent, durationMs = durationMs, lastPositionMs = lastPositionMs,
    seasonNumber = seasonNumber, episodeNumber = episodeNumber, lastUpdatedEpochMs = lastUpdatedEpochMs,
)

internal fun LibraryItem.toEvidence() = SavedEvidence(type = type, id = id, name = name, savedAtEpochMs = savedAtEpochMs)

/** Connects the shared engine to this app's metadata provider and debug setting (idempotent). */
internal fun installRecommendationEngine() {
    if (TmdbRecommendationData.diskCache == null) {
        // Trimmed title details are kept between launches, so a rebuild only asks TMDB about titles it hasn't seen.
        TmdbRecommendationData.diskCache = object : TmdbRecommendationData.DiskCache {
            override fun read(path: String): String? = AppFileCache.read(path)
            override fun write(path: String, payload: String) = AppFileCache.write(path, payload)
        }
    }
    if (RecommendationEngine.data !== TmdbRecommendationData) {
        RecommendationEngine.install(TmdbRecommendationData, diagnostics = com.nuvio.app.isDebugBuild)
    }
}

/**
 * The member's own Letterboxd ratings as the engine's 1..10 scale (half stars doubled), keyed the way it reads them
 * ("movie:<the id the app stores for the film>"). The newest rating of a film wins; unrated viewings add nothing.
 */
internal suspend fun letterboxdRatings(viewings: List<LetterboxdViewing>, profileId: Int): Map<String, Int> {
    val latest = viewings.asSequence().filter { it.profileId == profileId && it.tmdbId > 0 && it.stars != null }
        .sortedByDescending { it.completedAtMs }.distinctBy { it.tmdbId }.toList()
    val out = HashMap<String, Int>(latest.size)
    latest.forEach { v ->
        val appId = WatchedTmdbIndex.imdbFor(v.tmdbId) ?: "tmdb:${v.tmdbId}"
        out["movie:$appId"] = (v.stars!! * 2).toInt().coerceIn(1, 10)
    }
    return out
}
