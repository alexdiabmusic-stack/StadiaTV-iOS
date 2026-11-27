package com.nuvio.app.features.watchlist

/**
 * A title on a member's watchlist at another service (Letterboxd, Serializd), in terms every service shares: its TMDB id, whether it is
 * a show, and what is known of how to show it. The services hand these over; the app decides what goes into BannerTV's own My List.
 */
data class WatchlistTitle(
    val tmdbId: Int,
    val isSeries: Boolean,
    val name: String,
    val year: String? = null,
    /** A TMDB poster path ("/abc.jpg") when the service gave one. */
    val posterPath: String? = null,
) {
    /** Stable across runs: what "already dealt with" is remembered by. */
    val key: String get() = (if (isSeries) "series:" else "movie:") + tmdbId
}

/** What putting a watchlist into My List did. */
data class WatchlistApplyResult(
    val added: Int,
    /** Already in My List (the member's own or from an earlier run). */
    val alreadyThere: Int,
    /** Put there before and since removed by the member: not put back. */
    val removedByMember: Int,
    /** Films the member has already watched in BannerTV. */
    val alreadyWatched: Int,
    /** Titles whose BannerTV id could not be worked out. */
    val unresolved: Int,
) {
    fun summary(): String = buildString {
        append("$added added to My List")
        if (alreadyThere > 0) append(", $alreadyThere already there")
        if (alreadyWatched > 0) append(", $alreadyWatched already watched")
        if (removedByMember > 0) append(", $removedByMember you removed before are left out")
        if (unresolved > 0) append(", $unresolved could not be matched")
    }

    companion object { val NONE = WatchlistApplyResult(0, 0, 0, 0, 0) }
}

/** Where a service's watchlist lands in the app. Called with only complete reads of the watchlist. */
fun interface WatchlistSink {
    suspend fun apply(profileId: Int, source: String, titles: List<WatchlistTitle>): WatchlistApplyResult
}

/**
 * Decides which watchlist titles become new My List entries. The rules, in order, per title (first occurrence only):
 *  1. already in My List: nothing to add, and it is remembered as dealt with, so removing it later is respected;
 *  2. dealt with before and no longer in My List: the member took it out, so it is not put back;
 *  3. a film already watched in BannerTV: not added (a watchlist is for what is still to watch);
 *  4. otherwise it is added, and remembered.
 * Nothing is ever removed from My List by this.
 */
object WatchLaterPlanner {
    data class Plan(
        val add: List<WatchlistTitle>,
        val alreadyThere: Int,
        val removedByMember: Int,
        val alreadyWatched: Int,
        /** Keys to remember as dealt with after this run (everything already there, and everything about to be added). */
        val handled: Set<String>,
    )

    fun plan(
        titles: List<WatchlistTitle>,
        handledBefore: Set<String>,
        isInMyList: (WatchlistTitle) -> Boolean,
        isWatched: (WatchlistTitle) -> Boolean,
    ): Plan {
        val add = ArrayList<WatchlistTitle>()
        val handled = LinkedHashSet(handledBefore)
        var there = 0; var removed = 0; var watched = 0
        val seen = HashSet<String>()
        for (t in titles) {
            if (!seen.add(t.key)) continue
            when {
                isInMyList(t) -> { there++; handled += t.key }
                t.key in handledBefore -> removed++
                !t.isSeries && isWatched(t) -> watched++
                else -> { add += t; handled += t.key }
            }
        }
        return Plan(add, there, removed, watched, handled)
    }
}
