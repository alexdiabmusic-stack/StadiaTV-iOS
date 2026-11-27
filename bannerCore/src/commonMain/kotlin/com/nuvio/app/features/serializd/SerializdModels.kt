package com.nuvio.app.features.serializd

import kotlinx.serialization.Serializable

/*
 * Serializd for BannerTV: shared models.
 *
 * Serializd (serializd.com) is the TV counterpart of Letterboxd. Its private JSON API is ported from Jellyscribe
 * (github.com/builtbyproxy/Jellyscribe, LetterboxdSync/Serializd) and cross-checked against serializd-py, serializd-export and
 * the request shapes in Serializd's own web client. Nothing here talks to the Letterboxd integration: the two share only
 * small generic helpers (the key-value store interface, the playback coverage tracker and the auth breaker).
 */

enum class SerializdConnectionState {
    Disconnected,
    Connecting,
    Connected,
    SessionExpired,
    ReconnectionRequired,
    TemporarilyUnavailable,
}

/** Why an operation did not go through, in terms the app can act on. Never carries credentials, tokens or review text. */
enum class SerializdErrorCategory {
    None,
    /** No connection: nothing reached Serializd. */
    Offline,
    /** The email or password was refused. */
    BadCredentials,
    SessionExpired,
    ReconnectionRequired,
    RateLimited,
    ServerError,
    /** The show or season could not be found on Serializd (yet). */
    MetadataMissing,
    /** Serializd numbers the show differently and the episode cannot be placed with certainty. */
    MetadataMismatch,
    /** Serializd refused the request (a 4xx other than auth): the payload is not acceptable. */
    Rejected,
    /** A write may have landed: it is checked against the diary before anything is sent again. */
    Ambiguous,
    Unsupported,
    Unexpected,
}

enum class SerializdOperationType {
    /** Marks episodes watched (`/episode_log/add`). Idempotent on Serializd's side. */
    MarkEpisodeWatched,
    /** Adds a dated diary entry (`/show/reviews/add` with `is_log`). */
    CreateDiaryEntry,
    /** A rating for an episode, season or show. Edits the existing entry when one is known, never adds a second diary row. */
    SubmitRating,
    /** A written review for an episode, season or show. */
    SubmitReview,
    /** Removes the watched marker only. A dated diary entry is a separate thing and is never deleted by this. */
    RemoveWatchedMarker,
    /** History entries only (never queued): an import, a check, a backfill. */
    ImportHistory,
    Verify,
}

enum class SerializdOperationStatus {
    Pending,
    InProgress,
    Synced,
    /** Not sent on purpose (already there, or switched off). */
    Skipped,
    /** Will be tried again at [SerializdOperation.nextAttemptAtMs]. */
    RetryScheduled,
    /** The member must reconnect before this can go on. */
    NeedsReconnect,
    /** A write may have landed: the diary is read first, nothing is sent again until it is clear. */
    ReconciliationRequired,
    /** Held for the member to decide (for example an edit this session cannot make). */
    ActionRequired,
    FailedPermanent,
}

enum class SerializdScope { Show, Season, Episode }

/** What a rating, review or log is about. An episode needs its season; a null season and episode means the whole show. */
@Serializable
data class SerializdTarget(val showTmdbId: Int, val seasonNumber: Int? = null, val episodeNumber: Int? = null) {
    val scope: SerializdScope get() = when {
        episodeNumber != null && seasonNumber != null -> SerializdScope.Episode
        seasonNumber != null -> SerializdScope.Season
        else -> SerializdScope.Show
    }
    val key: String get() = "$showTmdbId|${seasonNumber ?: -1}|${episodeNumber ?: -1}"
}

/** One queued write. Persisted, so the queue survives the app being closed. One operation per remote phase. */
@Serializable
data class SerializdOperation(
    val id: String,
    val profileId: Int,
    /** The Serializd username this was queued for. An operation never runs for another account. */
    val account: String,
    val type: SerializdOperationType,
    val showTmdbId: Int,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    /** More episodes of the same season, marked in the same request (a multi-episode file, or a backfill batch). */
    val extraEpisodes: List<Int> = emptyList(),
    val title: String,
    /** Scoped to profile, account and content: a second operation with the same key is never queued. */
    val dedupeKey: String,
    /** The local viewing this belongs to (the playback event id), when it belongs to one. */
    val watchId: String? = null,
    val watchedAtMs: Long = 0L,
    val rewatch: Boolean = false,
    val stars: Double? = null,
    val liked: Boolean = false,
    val reviewText: String? = null,
    val containsSpoilers: Boolean = false,
    /** Serializd's id of the entry to edit, when it is known. */
    val reviewId: Int? = null,
    val createdAtMs: Long,
    val notBeforeMs: Long = 0L,
    val lastAttemptAtMs: Long = 0L,
    val nextAttemptAtMs: Long = 0L,
    val attempts: Int = 0,
    val status: SerializdOperationStatus = SerializdOperationStatus.Pending,
    val error: SerializdErrorCategory = SerializdErrorCategory.None,
    val note: String? = null,
    /** True from the moment a non-repeatable write was sent until its outcome is known: the diary is read, not written. */
    val reconciling: Boolean = false,
    val writeSentAtMs: Long = 0L,
    /** The last write got no answer at all (a timeout): it may still be applied, so it is not resent for a while. */
    val noReply: Boolean = false,
) {
    val target: SerializdTarget get() = SerializdTarget(showTmdbId, seasonNumber, episodeNumber)
    val episodes: List<Int> get() = if (episodeNumber == null) emptyList() else listOf(episodeNumber) + extraEpisodes
}

/** One viewing of an episode, kept locally whatever happens to the remote writes. */
@Serializable
data class SerializdWatch(
    /** "w-" plus the playback session id: a repeated finish callback for the same session is the same viewing. */
    val id: String,
    val profileId: Int,
    val account: String,
    val showTmdbId: Int,
    val showName: String,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val episodeTitle: String? = null,
    val posterUrl: String? = null,
    /** The real moment playback completed (epoch ms, UTC). It never moves when a retry runs later. */
    val completedAtMs: Long,
    val rewatch: Boolean = false,
    val stars: Double? = null,
    val liked: Boolean = false,
    val reviewDraft: String? = null,
    val reviewSpoilers: Boolean = false,
    val reviewPublished: Boolean = false,
    /** "playback", "manual" (a viewing the member logged, with the date they gave) or "import" (read from Serializd, never sent back). */
    val source: String = SOURCE_PLAYBACK,
    /** The watched marker for this episode is known to be on Serializd. */
    val markedWatched: Boolean = false,
    /** The dated diary entry for this viewing is known to be on Serializd. */
    val onDiary: Boolean = false,
    /** Serializd's id of that diary entry, once known: what an edit goes to. */
    val remoteReviewId: Int? = null,
    /** The date is not known (an import with no diary entry). Never sent anywhere. */
    val undated: Boolean = false,
) {
    val target: SerializdTarget get() = SerializdTarget(showTmdbId, seasonNumber, episodeNumber)

    companion object {
        const val SOURCE_PLAYBACK = "playback"
        const val SOURCE_MANUAL = "manual"
        const val SOURCE_IMPORT = "import"
    }
}

/** What the sync history shows for each outcome. */
@Serializable
data class SerializdSyncEvent(
    val id: String,
    val atMs: Long,
    val profileId: Int,
    val account: String,
    val showTmdbId: Int,
    val title: String,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val type: SerializdOperationType,
    val status: SerializdOperationStatus,
    val error: SerializdErrorCategory = SerializdErrorCategory.None,
    val note: String? = null,
    /** True when this entry is a rewatch. */
    val rewatch: Boolean = false,
)

/** The member's choices for what BannerTV does. Each is separate. */
@Serializable
data class SerializdSettings(
    val autoTrackEpisodes: Boolean = true,
    val createDiaryEntries: Boolean = true,
    val logRewatches: Boolean = true,
    val syncRatings: Boolean = true,
    val syncFavorites: Boolean = false,
    val importWatchedHistory: Boolean = true,
    val importWatchlist: Boolean = true,
    /** Put the watchlist in BannerTV's My List (watch later) when it is read. Never removes anything from My List. */
    val watchlistToLibrary: Boolean = true,
    /** Share of an episode that must really have been watched to count it done without the player reporting the end. */
    val completionThreshold: Double = 0.90,
)

/** The connected account for a profile. The credentials and token live in protected storage, not here. */
@Serializable
data class SerializdAccount(
    val username: String,
    val connectedAtMs: Long,
    val lastValidatedAtMs: Long = 0L,
    val lastImportAtMs: Long = 0L,
    val lastImportSummary: String? = null,
    val lastWatchlistAtMs: Long = 0L,
    val lastWatchlistSummary: String? = null,
    /** The numbers behind the last history import, for the details view. Absent on accounts that imported before this was kept. */
    val lastImportStats: SerializdImportStats? = null,
    /**
     * True from a new connection until the member picks "Use recommended settings" or "Customize" on the setup step. While it is set,
     * nothing is read from Serializd on its own, so the choice is made before the first import. Accounts connected earlier never have it.
     */
    val setupPending: Boolean = false,
)

/** What one history import did, kept with the account so the details view can show it without re-running anything. */
@Serializable
data class SerializdImportStats(
    val atMs: Long,
    val added: Int,
    val alreadyKnown: Int,
    val unmatched: Int,
    val diaryEntries: Int = 0,
    val watchedShows: Int = 0,
    val notMatched: List<String> = emptyList(),
    val placedByCount: List<String> = emptyList(),
    val partial: Boolean = false,
)

// ---------------------------------------------------------------------------------------------- what Serializd sends

/** One season of a show as Serializd numbers it. [id] is Serializd's own season id (not necessarily TMDB's). */
@Serializable
data class SerializdSeasonInfo(val number: Int, val id: Int, val episodeCount: Int? = null)

/** A show's season list, with the facts import needs to decide what a "watched" season holds. */
@Serializable
data class SerializdShow(
    val tmdbId: Int,
    val name: String? = null,
    val seasons: List<SerializdSeasonInfo>,
    val status: String? = null,
    val posterPath: String? = null,
    val inProduction: Boolean = false,
)

/** An episode of a season, with the day it aired when Serializd says. */
data class SerializdEpisodeInfo(val number: Int, val airDate: String?, val name: String?)

/** One diary row. A null [episodeNumber] is a show-level or season-level entry, never episode zero. */
data class SerializdDiaryEntry(
    val id: Int?,
    val showTmdbId: Int,
    val showName: String?,
    val seasonId: Int?,
    /** The season number, resolved through the row's own season list (null when it cannot be). */
    val seasonNumber: Int?,
    val episodeNumber: Int?,
    /** Serializd's 1 to 10, 0 or null when unrated. */
    val rating: Int?,
    val reviewText: String?,
    val containsSpoiler: Boolean,
    val isLog: Boolean,
    val isRewatch: Boolean,
    val like: Boolean,
    /** The watch date, when Serializd gave one. [backdateDateOnly] is true when it carried no time of day. */
    val backdateMs: Long?,
    val backdateDateOnly: Boolean,
    val dateAddedMs: Long?,
)

/** [totalEntries] is what Serializd says the diary holds in all (`totalReviews`): a read that comes up short of it is not complete. */
data class SerializdDiaryPage(val entries: List<SerializdDiaryEntry>, val totalPages: Int?, val rawCount: Int, val totalEntries: Int? = null)

/** A show on the member's watched page: the seasons they have marked watched as a whole. */
data class SerializdWatchedEntry(val showTmdbId: Int, val name: String?, val seasonIds: List<Int>, val posterPath: String?, val numSeasons: Int?, val numEpisodes: Int?)

data class SerializdWatchedPage(val entries: List<SerializdWatchedEntry>, val totalPages: Int?, val rawCount: Int, val totalShows: Int? = null)

@Serializable
data class SerializdWatchlistEntry(
    val showTmdbId: Int,
    val name: String? = null,
    val posterPath: String? = null,
    /** The seasons watchlisted, as numbers. Empty means the whole show, or that they could not be resolved yet. */
    val seasonNumbers: List<Int> = emptyList(),
    val seasonIds: List<Int> = emptyList(),
)

/** [totalShows] is what Serializd says the watchlist holds in all (`numberOfShows`). */
data class SerializdWatchlistPage(val entries: List<SerializdWatchlistEntry>, val totalPages: Int?, val rawCount: Int, val totalShows: Int? = null)

/** The last complete read of the member's watchlist. Only ever replaced by another complete read. */
@Serializable
data class SerializdWatchlistSnapshot(val entries: List<SerializdWatchlistEntry>, val completeAtMs: Long)

/** An entry about a whole show or a season, read from the diary: its rating and review, for display and for editing later. */
@Serializable
data class SerializdRemoteEntry(
    val id: Int?,
    val showTmdbId: Int,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val stars: Double? = null,
    val reviewText: String? = null,
    val containsSpoiler: Boolean = false,
    val isLog: Boolean = false,
    val atMs: Long = 0L,
)

/** An episode the member watched according to Serializd. [watchedAtMs] is null when Serializd gave no reliable date. */
data class SerializdImportedEpisode(
    val showTmdbId: Int,
    val showName: String?,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val watchedAtMs: Long?,
    val stars: Double? = null,
    val rewatch: Boolean = false,
)

data class SerializdImportResult(
    val newEpisodes: Int,
    val alreadyKnown: Int,
    val unmatched: Int,
    val pagesRead: Int,
    /** True when the run stopped early (a failed read or the page limit) and running it again continues. */
    val partial: Boolean,
    val message: String?,
    /** Shows whose watched seasons could not be matched, as "Show (3 seasons)". Serializd renumbers seasons now and then, leaving an old record pointing at ids it no longer lists. */
    val notMatched: List<String> = emptyList(),
    /** Shows whose watched seasons were placed by counting, as "Show (9 seasons)": their ids were gone, but the count left no other reading. */
    val placedByCount: List<String> = emptyList(),
)
