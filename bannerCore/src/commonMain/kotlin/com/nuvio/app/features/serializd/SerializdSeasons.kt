package com.nuvio.app.features.serializd

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** A small string store the Serializd code keeps its caches and queues in (the app backs it with its own storage). */
interface SerializdKeyValue {
    fun read(key: String): String?
    fun write(key: String, value: String?)
}

/**
 * What may go to Serializd. The two trackers split the library cleanly: a film is Letterboxd's and never reaches Serializd, a TV episode
 * is Serializd's and never reaches Letterboxd. Kept as one small function so the rule is tested, not only written in the player.
 */
object SerializdEligibility {
    private val SERIES_TYPES = setOf("series", "show", "tvshow", "tv")

    /** A BannerTV content type that is a TV show. Films, music, sports and anything unknown are not. */
    fun isSeriesType(metaType: String?): Boolean = metaType?.trim()?.lowercase() in SERIES_TYPES

    /** Whether what is playing is a TV episode with a season and an episode number: the only thing ever tracked on Serializd. */
    fun isEpisode(metaType: String?, season: Int?, episode: Int?, isLive: Boolean = false): Boolean =
        !isLive && isSeriesType(metaType) && season != null && season >= 0 && episode != null && episode > 0
}

/** A resolved episode target: the TMDB show id, the season number, and the episode number(s) to log. */
data class SerializdEpisodeRef(val showTmdbId: Int, val seasonNumber: Int, val episodeNumbers: List<Int>)

/**
 * Pure mapping from a playing episode's raw numbers to a Serializd episode target (Jellyscribe's SerializdEpisodeMapper). Kept apart
 * from the player so every edge case (a missing id, specials, a file holding several episodes) is testable.
 */
object SerializdEpisodeMapper {
    /**
     * A file rarely holds more than a handful of episodes; a range wider than this is almost certainly bad metadata (a whole-season
     * file whose last episode is set to the finale). Only the first episode is logged then, rather than dozens of wrong ones.
     */
    private const val MAX_RANGE_SPAN = 24

    fun build(seriesTmdbId: Int?, seasonNumber: Int?, episodeNumber: Int?, episodeNumberEnd: Int? = null): SerializdEpisodeRef? {
        if (seriesTmdbId == null || seriesTmdbId <= 0) return null
        // Season 0 is Specials and is legitimate; only a missing or negative season is refused.
        if (seasonNumber == null || seasonNumber < 0) return null
        if (episodeNumber == null || episodeNumber <= 0) return null
        val numbers = mutableListOf(episodeNumber)
        if (episodeNumberEnd != null && episodeNumberEnd > episodeNumber && episodeNumberEnd - episodeNumber <= MAX_RANGE_SPAN) {
            for (n in episodeNumber + 1..episodeNumberEnd) numbers += n
        }
        return SerializdEpisodeRef(seriesTmdbId, seasonNumber, numbers)
    }
}

/**
 * Where an episode lands on Serializd: its season's id, and an offset when Serializd keeps several seasons as one long first season.
 * [episodeFor] is null when the number would fall past the end of the season Serializd has, which means the numbering does not match.
 */
data class SerializdSeasonTarget(val seasonId: Int, val episodeOffset: Int, val episodeCount: Int? = null) {
    fun episodeFor(episode: Int): Int? {
        val number = episode + episodeOffset
        return if (episodeCount != null && number > episodeCount) null else number
    }
}

/**
 * What a member's watched season ids on one show come to: the season [numbers] (those placed by id plus those placed by counting),
 * how many of them were [placedByCount], and how many ids could not be placed at all ([lost]).
 */
data class SerializdWatchedSeasons(val numbers: List<Int>, val placedByCount: Int, val lost: Int)

@Serializable
private data class CachedShow(val tmdbId: Int, val seasons: List<SerializdSeasonInfo>, val fetchedAtMs: Long, val name: String? = null, val status: String? = null, val inProduction: Boolean = false)

/**
 * Maps TMDB show and season numbers to Serializd's own season ids and sizes (`/show/{id}` is the source). The map is kept between
 * launches. A season number it does not know triggers one refresh (a season that has just aired), and a show Serializd does not have
 * is remembered as missing for a while so a bad id is not asked about again and again.
 */
class SerializdSeasonResolver(
    private val api: SerializdApi,
    private val store: SerializdKeyValue,
    private val now: () -> Long,
    /** Where the map is saved. One per profile, so two profiles never overwrite each other's copy. */
    private val cacheKey: String = KEY,
) {
    private val json = Json { ignoreUnknownKeys = true }
    private val lock = Mutex()
    private var shows: MutableMap<Int, CachedShow>? = null
    private val missing = HashMap<Int, Long>()

    private fun loaded(): MutableMap<Int, CachedShow> = shows ?: run {
        val parsed = store.read(cacheKey)?.let { runCatching { json.decodeFromString(ListSerializer(CachedShow.serializer()), it) }.getOrNull() }.orEmpty()
        parsed.associateByTo(LinkedHashMap()) { it.tmdbId }.also { shows = it }
    }

    private fun persist() {
        val map = loaded()
        if (map.size > MAX_SHOWS) map.keys.take(map.size - MAX_SHOWS).forEach(map::remove)
        store.write(cacheKey, json.encodeToString(ListSerializer(CachedShow.serializer()), map.values.toList()))
    }

    /** The show's seasons, from the saved map unless it is old (or [forceRefresh]). Null when Serializd does not have the show. */
    suspend fun show(showTmdbId: Int, forceRefresh: Boolean = false): SerializdShow? = lock.withLock {
        val t = now()
        if (!forceRefresh) {
            loaded()[showTmdbId]?.takeIf { t - it.fetchedAtMs < SHOW_TTL_MS }?.let { return@withLock it.toShow() }
            missing[showTmdbId]?.takeIf { t - it < MISSING_TTL_MS }?.let { return@withLock null }
        }
        try {
            val fresh = api.show(showTmdbId)
            val map = loaded()
            map.remove(showTmdbId)
            map[showTmdbId] = CachedShow(showTmdbId, fresh.seasons, t, fresh.name, fresh.status, fresh.inProduction)
            missing.remove(showTmdbId)
            persist()
            fresh
        } catch (e: SerializdException.NotFound) {
            missing[showTmdbId] = t
            null
        }
    }

    private fun CachedShow.toShow() = SerializdShow(tmdbId, name, seasons, status, null, inProduction)

    private suspend fun seasonInfo(showTmdbId: Int, seasonNumber: Int): SerializdSeasonInfo? {
        val cached = show(showTmdbId) ?: return null
        cached.seasons.firstOrNull { it.number == seasonNumber }?.let { return it }
        // A season the map does not hold: it may have aired since the map was saved. Look again, but not on every miss.
        val age = now() - (loaded()[showTmdbId]?.fetchedAtMs ?: 0L)
        if (age < MISS_REFRESH_MS) return null
        return show(showTmdbId, forceRefresh = true)?.seasons?.firstOrNull { it.number == seasonNumber }
    }

    suspend fun seasonId(showTmdbId: Int, seasonNumber: Int): Int? = seasonInfo(showTmdbId, seasonNumber)?.id

    suspend fun episodeCount(showTmdbId: Int, seasonNumber: Int): Int? = seasonInfo(showTmdbId, seasonNumber)?.episodeCount

    /** Serializd season ids to season numbers, refreshing once when an id is unknown. Ids that stay unknown are left out. */
    suspend fun seasonNumbers(showTmdbId: Int, seasonIds: List<Int>): List<Int> {
        if (seasonIds.isEmpty()) return emptyList()
        var s = show(showTmdbId) ?: return emptyList()
        if (seasonIds.any { id -> s.seasons.none { it.id == id } }) s = show(showTmdbId, forceRefresh = true) ?: s
        return seasonIds.mapNotNull { id -> s.seasons.firstOrNull { it.id == id }?.number }.sorted()
    }

    /**
     * The seasons a member has marked watched on one show. Serializd's watched list stores season ids, and now and then a show's seasons
     * get new ids (TMDB re-creates them) while the member's record keeps pointing at the old ones, which no endpoint can look up any
     * more. Ids are matched first. Ids that match nothing are then placed by counting, and only when the count leaves no choice: when
     * they are exactly as many as the show's seasons that the member has no other mark on, every one of those seasons was marked.
     * Specials (season 0) may or may not be among them, so either count settles it. Fewer or more stale ids than that cannot be told
     * apart (which seasons were left out is not recorded anywhere), so they stay unplaced and are counted in [SerializdWatchedSeasons.lost].
     */
    suspend fun watchedSeasons(showTmdbId: Int, seasonIds: List<Int>): SerializdWatchedSeasons {
        val ids = seasonIds.distinct()
        if (ids.isEmpty()) return SerializdWatchedSeasons(emptyList(), 0, 0)
        var s = show(showTmdbId) ?: return SerializdWatchedSeasons(emptyList(), 0, ids.size)
        if (ids.any { id -> s.seasons.none { it.id == id } }) s = show(showTmdbId, forceRefresh = true) ?: s
        val byId = s.seasons.associateBy { it.id }
        val known = ids.mapNotNull { byId[it]?.number }.toSet()
        val stale = ids.count { it !in byId }
        if (stale == 0) return SerializdWatchedSeasons(known.sorted(), 0, 0)
        val open = s.seasons.map { it.number }.distinct().filter { it !in known }
        val openNumbered = open.filter { it > 0 }
        val settled = openNumbered.isNotEmpty() && (stale == openNumbered.size || stale == open.size)
        if (!settled) return SerializdWatchedSeasons(known.sorted(), 0, stale)
        return SerializdWatchedSeasons((known + openNumbered).sorted(), openNumbered.size, 0)
    }

    /**
     * Where [seasonNumber] of the show is on Serializd. Serializd sometimes keeps a show as one long season 1 where TMDB has several;
     * the fallback (Jellyscribe's SerializdSeasonFallback) then places a later season's episodes after the earlier seasons', but only
     * when that is unambiguous: Serializd has no season N and no real season 2, season 1 exists, the earlier seasons' lengths are all
     * known, and the first episode of the later season still falls inside Serializd's season 1. Otherwise null, and nothing is logged.
     */
    suspend fun target(showTmdbId: Int, seasonNumber: Int, seasonLengths: suspend () -> Map<Int, Int>): SerializdSeasonTarget? {
        seasonInfo(showTmdbId, seasonNumber)?.let { return SerializdSeasonTarget(it.id, 0, it.episodeCount) }
        if (seasonNumber < 2) return null
        if (seasonNumber != 2 && seasonId(showTmdbId, 2) != null) return null
        val first = seasonInfo(showTmdbId, 1) ?: return null
        val offset = episodeOffset(seasonNumber, seasonLengths())
        val count = first.episodeCount
        if (count == null || offset == null || offset >= count) return null
        return SerializdSeasonTarget(first.id, offset, count)
    }

    /** Drops what is known about a show, so the next lookup asks Serializd again. */
    suspend fun forget(showTmdbId: Int) = lock.withLock {
        loaded().remove(showTmdbId); missing.remove(showTmdbId); persist()
    }

    suspend fun clear() = lock.withLock { shows = LinkedHashMap(); missing.clear(); store.write(cacheKey, null) }

    companion object {
        const val KEY = "serializd_seasons_v1"
        const val SHOW_TTL_MS = 7 * 24 * 3_600_000L
        const val MISSING_TTL_MS = 3_600_000L
        const val MISS_REFRESH_MS = 10 * 60_000L
        private const val MAX_SHOWS = 600

        /** How many episodes come before [seasonNumber] when the seasons are laid end to end, or null when a season's length is not known. */
        fun episodeOffset(seasonNumber: Int, seasonLengths: Map<Int, Int>): Int? {
            var offset = 0
            for (season in 1 until seasonNumber) {
                val length = seasonLengths[season]
                if (length == null || length <= 0) return null
                offset += length
            }
            return offset
        }
    }
}

/** One account's way to Serializd: the API on its session and the season map. One per connected account; nothing is shared between accounts. */
class SerializdService(val api: SerializdApi, val seasons: SerializdSeasonResolver) {
    val session: SerializdSession get() = api.session
}
