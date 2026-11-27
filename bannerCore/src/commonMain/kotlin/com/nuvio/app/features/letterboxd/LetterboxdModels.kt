package com.nuvio.app.features.letterboxd

import kotlinx.serialization.Serializable

/*
 * Letterboxd for BannerTV: shared models.
 *
 * Behaviour is ported from Jellyscribe (github.com/builtbyproxy/Jellyscribe, commit 2d460bc): the website-session path of
 * its LetterboxdSync project. No third-party API credentials are used; the connection is the member's own signed-in
 * Letterboxd session.
 */

/** A Letterboxd film resolved from a TMDB movie id. [filmId] is the numeric site id, [productionId] the short "lid". */
@Serializable
data class LetterboxdFilm(
    val tmdbId: Int,
    val slug: String,
    val filmId: String,
    val productionId: String?,
    val resolvedAtMs: Long,
) {
    val url: String get() = "https://letterboxd.com/film/$slug/"
}

/** The member's diary dates for one film ("yyyy-MM-dd"), as the site's film diary page lists them. */
data class LetterboxdDiaryInfo(val dates: List<String>) {
    val lastDate: String? get() = dates.maxOrNull()
    val hasAnyEntry: Boolean get() = dates.isNotEmpty()
    fun hasDate(date: String): Boolean = date in dates
}

/** A film from the member's watched list: its TMDB id and rating in stars (0.5 to 5.0) when rated. */
data class LetterboxdWatchedFilm(val tmdbId: Int, val stars: Double?)

/** One row of the member's diary page: the film slug, the day watched, the rating and whether it was marked a rewatch. */
/** One film from the watched-films grid. [title] is the grid's name without the year. */
data class LetterboxdGridFilm(val slug: String, val title: String?, val stars: Double?, val year: String? = null)

/** One page of the member's watchlist: its films, whether another page follows, and the total the page itself declares ("191 films"). */
data class LetterboxdWatchlistPage(val films: List<LetterboxdGridFilm>, val hasNext: Boolean, val declaredTotal: Int?)

/** A film on the member's watchlist, matched to its TMDB movie id. */
@Serializable
data class LetterboxdWatchlistFilm(val slug: String, val tmdbId: Int, val title: String, val year: String? = null)

/** The last complete read of the member's watchlist. Only ever replaced by another complete read. */
@Serializable
data class LetterboxdWatchlistSnapshot(val films: List<LetterboxdWatchlistFilm>, val completeAtMs: Long)

data class LetterboxdDiaryRow(val slug: String, val date: String, val stars: Double?, val rewatch: Boolean)

/** What a diary write sends. Every field but the film and date is optional. */
data class LetterboxdDiaryWrite(
    val film: LetterboxdFilm,
    val diaryDate: String,
    val rewatch: Boolean,
    val liked: Boolean = false,
    val stars: Double? = null,
    val reviewText: String? = null,
    val containsSpoilers: Boolean = false,
)

enum class LetterboxdConnectionState {
    Disconnected,
    Connecting,
    Connected,
    SessionExpired,
    ReconnectionRequired,
    TemporarilyUnavailable,
}

/** Why an operation did not go through, in terms the app can act on. Never contains session material or review text. */
enum class LetterboxdErrorCategory {
    None,
    Offline,
    SessionExpired,
    ReconnectionRequired,
    Blocked,
    RateLimited,
    ServerError,
    FilmNotFound,
    NotAFilm,
    Unsupported,
    Ambiguous,
    Unexpected,
}

enum class LetterboxdOperationType { CreateDiaryEntry, SetRating, PublishReview, SetLike, ImportDiary, Verify }

enum class LetterboxdOperationStatus {
    Pending,
    InProgress,
    Succeeded,
    /** Not sent on purpose (already on the diary, or a same-day repeat). */
    Skipped,
    /** Will be tried again at [LetterboxdOperation.nextAttemptAtMs]. */
    RetryScheduled,
    /** The member must reconnect before this can go on. */
    NeedsReconnect,
    /** A write may have landed: it is checked against the diary before anything is sent again. */
    NeedsReconciliation,
    /** Held for the member to decide (for example a review for a viewing that is already on the diary). */
    ActionRequired,
    Failed,
}

/** One queued write. Persisted, so the queue survives the app being closed. */
@Serializable
data class LetterboxdOperation(
    val id: String,
    val profileId: Int,
    val account: String,
    val tmdbId: Int,
    val title: String,
    val type: LetterboxdOperationType,
    val viewingId: String? = null,
    val viewingDate: String? = null,
    val stars: Double? = null,
    val liked: Boolean = false,
    val rewatch: Boolean? = null,
    val forceSameDay: Boolean = false,
    val reviewText: String? = null,
    val containsSpoilers: Boolean = false,
    val createdAtMs: Long,
    val notBeforeMs: Long = 0L,
    val lastAttemptAtMs: Long = 0L,
    val nextAttemptAtMs: Long = 0L,
    val attempts: Int = 0,
    val status: LetterboxdOperationStatus = LetterboxdOperationStatus.Pending,
    val filmId: String? = null,
    val filmSlug: String? = null,
    val externalEntryDate: String? = null,
    /** True from the moment a write was sent until its outcome is known: the diary is checked, nothing is resent. */
    val reconciling: Boolean = false,
    val writeSentAtMs: Long = 0L,
    val error: LetterboxdErrorCategory = LetterboxdErrorCategory.None,
    val note: String? = null,
)

/** One viewing of a film, kept locally whatever happens to the remote write. */
@Serializable
data class LetterboxdViewing(
    val id: String,
    val profileId: Int,
    val tmdbId: Int,
    val title: String,
    val posterUrl: String? = null,
    val completedAtMs: Long,
    /** The viewer's own calendar day at completion, "yyyy-MM-dd". It never moves when a retry runs later. */
    val localDate: String,
    val rewatch: Boolean = false,
    val stars: Double? = null,
    val liked: Boolean = false,
    val reviewDraft: String? = null,
    val reviewSpoilers: Boolean = false,
    val reviewPublished: Boolean = false,
    val source: String = "playback",
    /** Set once the diary entry for this viewing is known to be on Letterboxd. */
    val onDiary: Boolean = false,
    /** True when it is recorded here only: a second viewing on the same day is not sent unless the member asks. */
    val localOnly: Boolean = false,
) {
    companion object {
        /** The date given to a film marked watched on Letterboxd with no diary entry: its viewing date is not known. */
        const val UNDATED = "2000-01-01"
        const val UNDATED_EPOCH_DAY = 10_957L
    }
}

/** What the sync history shows for each outcome. */
@Serializable
data class LetterboxdSyncEvent(
    val id: String,
    val atMs: Long,
    val profileId: Int,
    val account: String,
    val tmdbId: Int,
    val title: String,
    val type: LetterboxdOperationType,
    val status: LetterboxdOperationStatus,
    val viewingDate: String? = null,
    val error: LetterboxdErrorCategory = LetterboxdErrorCategory.None,
    val note: String? = null,
)

/** The member's choices for what BannerTV sends. Each is separate. */
@Serializable
data class LetterboxdSettings(
    val autoLogMovies: Boolean = true,
    val syncRatings: Boolean = true,
    val syncFavorites: Boolean = false,
    val logRewatches: Boolean = true,
    val showPostWatchPrompt: Boolean = true,
    /** Put the watchlist in BannerTV's My List (watch later) when it is read. Never removes anything from My List. */
    val watchlistToLibrary: Boolean = true,
    /** Share of a film that must really have been watched to count it done without the player reporting the end. */
    val completionThreshold: Double = 0.95,
)

/** The connected account for a profile. The session material itself lives in protected storage, not here. */
@Serializable
data class LetterboxdAccount(
    val username: String,
    val connectedAtMs: Long,
    val lastValidatedAtMs: Long = 0L,
    val lastWatchlistAtMs: Long = 0L,
    val lastWatchlistSummary: String? = null,
)
