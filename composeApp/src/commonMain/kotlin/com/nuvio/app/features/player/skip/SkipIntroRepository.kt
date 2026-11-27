package com.nuvio.app.features.player.skip

import com.nuvio.app.core.logging.InAppLogger
import com.nuvio.app.features.playback.PlaybackSegmentType
import com.nuvio.app.features.playback.SegmentArbiter
import com.nuvio.app.features.playback.SegmentCache
import com.nuvio.app.features.playback.SegmentCacheResult
import com.nuvio.app.features.playback.SegmentCandidate
import com.nuvio.app.features.playback.SegmentLookupOutcome
import com.nuvio.app.features.player.PlayerSettingsRepository
import com.nuvio.app.features.watchprogress.WatchProgressClock
import kotlinx.coroutines.CancellationException
import com.nuvio.app.features.tmdb.TmdbService
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull

object SkipIntroRepository {

    // Bounded and expiring (was an unbounded map): a found answer lives six hours, and a request that found nothing is not stored.
    private val cache = SegmentCache<List<SkipInterval>>(maxEntries = 128, clock = { WatchProgressClock.nowEpochMs() })

    // SkipDB answers are kept per provider so "SkipDB has nothing for this episode" can be remembered without hiding IntroDB.
    private val skipDbCache = SegmentCache<List<SkipInterval>>(maxEntries = 256, clock = { WatchProgressClock.nowEpochMs() })
    private const val SKIP_DB_TIMEOUT_MS = 4_000L
    private val imdbEntriesCache = HashMap<String, List<ArmEntry>>()
    private val animeSkipShowIdCache = HashMap<String, String>()
    private const val NO_ID = "__none__"
    private const val INTRO_DB_TIMEOUT_MS = 5_000L
    private const val ARM_LOOKUP_TIMEOUT_MS = 3_000L
    private const val ANISKIP_TIMEOUT_MS = 3_000L
    private const val ANIME_SKIP_TIMEOUT_MS = 3_000L
    private const val ANIME_SKIP_SHOW_LOOKUP_TIMEOUT_MS = 3_000L

    private val introDbConfigured: Boolean
        get() = IntroDbConfig.URL.isNotBlank()

    suspend fun getMovieSkipIntervals(
        contentId: String?,
        videoId: String?,
        requireSkipIntroEnabled: Boolean = true,
        durationMs: Long? = null,
        onUpdate: ((List<SkipInterval>) -> Unit)? = null,
    ): List<SkipInterval> = coroutineScope {
        if (requireSkipIntroEnabled && !PlayerSettingsRepository.uiState.value.skipIntroEnabled) return@coroutineScope emptyList()
        val imdbId = resolveMovieSkipImdbId(
            contentId, videoId,
            resolveTmdb = { TmdbService.tmdbToImdb(it, "movie") },
            resolveAnime = { source, id -> SimklIdResolver.resolveIds(source, id)?.imdb },
        ) ?: return@coroutineScope emptyList()
        val cacheKey = SegmentCache.key("movie", imdbId, durationSeconds = durationMs?.div(1000))
        (cache.get(cacheKey) as? SegmentCacheResult.Hit)?.let { return@coroutineScope it.value }

        val introDbDeferred = async { if (introDbConfigured) fetchMovieFromIntroDb(imdbId) else emptyList() }
        val skipDbDeferred = async { fetchFromSkipDb(imdbId, null, null, durationMs) }
        val introDb = introDbDeferred.await()
        val first = arbitrate(listOf(introDb), durationMs, episodic = false)
        if (first.isNotEmpty()) onUpdate?.invoke(first)
        val merged = arbitrate(listOf(introDb, skipDbDeferred.await()), durationMs, episodic = false)
        if (merged != first) onUpdate?.invoke(merged)
        merged.also { if (it.isNotEmpty()) cache.put(cacheKey, it) }
    }

    private suspend fun fetchMovieFromIntroDb(imdbId: String): List<SkipInterval> {
        val data = SkipIntroApi.getIntroDbMovieSegments(imdbId) ?: return emptyList()
        return data.movieSkipIntervals()
    }

    /**
     * Resolves a TV episode's segments from every provider at once and publishes as each one answers, so the Skip Intro button
     * appears with the first result and recap, credits and scenes fill in without it moving. An opening from one provider no
     * longer ends the search: the others still run for the categories it lacks. [onUpdate] is called from this coroutine, so
     * cancelling the caller (a new episode, leaving the player) stops late answers from reaching the old session.
     */
    suspend fun getSkipIntervals(
        imdbId: String?,
        season: Int,
        episode: Int,
        requireSkipIntroEnabled: Boolean = true,
        durationMs: Long? = null,
        onUpdate: ((List<SkipInterval>) -> Unit)? = null,
    ): List<SkipInterval> = coroutineScope {
        if (imdbId == null) {
            InAppLogger.debug("Player/SkipIntro", "skip lookup ignored: imdbId missing s=$season e=$episode")
            return@coroutineScope emptyList()
        }
        val settings = PlayerSettingsRepository.uiState.value
        if (requireSkipIntroEnabled && !settings.skipIntroEnabled) {
            InAppLogger.debug("Player/SkipIntro", "skip lookup disabled imdb=$imdbId s=$season e=$episode")
            return@coroutineScope emptyList()
        }

        val cacheKey = SegmentCache.key("tv", imdbId, season, episode, durationSeconds = durationMs?.div(1000))
        (cache.get(cacheKey) as? SegmentCacheResult.Hit)?.let { cached ->
            InAppLogger.debug("Player/SkipIntro", "skip lookup cache hit imdb=$imdbId s=$season e=$episode count=${cached.value.size}")
            return@coroutineScope cached.value
        }
        InAppLogger.info(
            "Player/SkipIntro",
            "skip lookup imdb=$imdbId s=$season e=$episode introDb=$introDbConfigured animeSkip=${settings.animeSkipEnabled}",
        )

        val introDbDeferred = async { if (introDbConfigured) fetchFromIntroDb(imdbId, season, episode) else emptyList() }
        val skipDbDeferred = async { fetchFromSkipDb(imdbId, season, episode, durationMs) }
        val simklIdsDeferred = async { SimklIdResolver.resolveIdsForImdbEpisode(imdbId, season, episode) }

        val results = ArrayList<List<SkipInterval>>()
        var published: List<SkipInterval>? = null
        fun publish() {
            val merged = arbitrate(results, durationMs, episodic = true)
            if (merged != published) {
                published = merged
                if (merged.isNotEmpty()) onUpdate?.invoke(merged)
            }
        }

        results += introDbDeferred.await()
        publish() // the Skip Intro button must not wait for the slower providers
        results += skipDbDeferred.await()
        publish()

        // Anime providers need the Simkl id mapping; they run for every title because they can supply the recap or credits
        // IntroDB lacks, but a non-anime title simply has no mapping and costs nothing further.
        val simklIds = simklIdsDeferred.await()
        val malId = simklIds?.mal
        val anilistId = simklIds?.anilist
        if (simklIds != null) {
            // Remap the TVDB episode number to the anime-entry-local episode number.
            val mapping = SimklIdResolver.getEpisodeMapping(simklIds.simklId, simklIds.type)
            val animeEpisode = mapping.firstOrNull { it.tvdbSeason == season && it.tvdbEpisode == episode }?.animeEpisode ?: episode
            val aniSkipDeferred = async { if (malId != null) fetchFromAniSkip(malId, animeEpisode) else emptyList() }
            val animeSkipDeferred = async { if (anilistId != null) fetchFromAnimeSkip(anilistId, animeEpisode, season = null) else emptyList() }
            results += animeSkipDeferred.await()
            results += aniSkipDeferred.await()
            publish()
        }

        val merged = arbitrate(results, durationMs, episodic = true)
        InAppLogger.info(
            "Player/SkipIntro",
            "skip lookup result imdb=$imdbId s=$season e=$episode count=${merged.size} providers=${results.map { it.size }}",
        )
        merged.also { if (it.isNotEmpty()) cache.put(cacheKey, it) }
    }

    /**
     * Once the real duration is known, asks SkipDB again with it (it can then say "exact" or "shifted" instead of "agnostic")
     * and re-arbitrates against what the session already has. Returns null when nothing changes.
     */
    suspend fun refineWithDuration(
        existing: List<SkipInterval>,
        imdbId: String?,
        season: Int?,
        episode: Int?,
        durationMs: Long,
    ): List<SkipInterval>? {
        if (imdbId == null || durationMs <= 0L) return null
        val refined = fetchFromSkipDb(imdbId, season, episode, durationMs)
        if (refined.isEmpty()) return null
        val others = existing.filter { it.provider != "skipdb" }
        return arbitrate(listOf(others, refined), durationMs, episodic = season != null).takeIf { it != existing }
    }

    private suspend fun fetchFromSkipDb(imdbId: String, season: Int?, episode: Int?, durationMs: Long?): List<SkipInterval> {
        val key = SegmentCache.key("skipdb", imdbId, season, episode, durationSeconds = durationMs?.div(1000))
        when (val hit = skipDbCache.get(key)) {
            is SegmentCacheResult.Hit -> return hit.value
            SegmentCacheResult.NegativeHit -> return emptyList()
            SegmentCacheResult.Miss -> Unit
        }
        val outcome = withTimeoutOrNull(SKIP_DB_TIMEOUT_MS) { SkipDbProvider.fetch(imdbId, season, episode, durationMs) }
            ?: SegmentLookupOutcome.ProviderError("timed out", retryable = true)
        return when (outcome) {
            is SegmentLookupOutcome.Segments -> outcome.toSkipIntervals("skipdb").also { skipDbCache.put(key, it) }
            // "Nothing for this episode" is an answer worth remembering; a failure is not, so it is asked again next time.
            SegmentLookupOutcome.NoData, is SegmentLookupOutcome.ConfirmedAbsent -> emptyList<SkipInterval>().also { skipDbCache.putNegative(key) }
            is SegmentLookupOutcome.ProviderError -> {
                InAppLogger.warn("Player/SkipIntro", "SkipDB ${outcome.reason} imdb=$imdbId s=${season ?: 0} e=${episode ?: 0}")
                emptyList()
            }
            is SegmentLookupOutcome.Invalid -> {
                InAppLogger.warn("Player/SkipIntro", "SkipDB invalid answer: ${outcome.reason} imdb=$imdbId")
                emptyList()
            }
        }
    }

    /** One arbitration for every flow: per-stretch trust order, validated for the duration when it is known. */
    private fun arbitrate(providerResults: List<List<SkipInterval>>, durationMs: Long?, episodic: Boolean): List<SkipInterval> {
        val candidates = providerResults.flatten().mapNotNull { interval ->
            interval.toPlaybackSegment()?.let { SegmentCandidate(it, interval) }
        }
        return SegmentArbiter.arbitrate(
            candidates = candidates,
            durationMs = durationMs?.takeIf { it > 0L },
            retime = { interval, segment ->
                interval.copy(
                    startTime = segment.startMs / 1000.0,
                    endTime = segment.endMs?.let { it / 1000.0 } ?: Double.MAX_VALUE,
                )
            },
            limitPerType = if (episodic) EPISODE_LIMITS else emptyMap(),
        ).map { it.candidate.payload }
    }

    private val EPISODE_LIMITS = mapOf(
        PlaybackSegmentType.INTRO to 1,
        PlaybackSegmentType.RECAP to 1,
        PlaybackSegmentType.CREDITS to 1,
    )

    suspend fun getSkipIntervalsForMal(
        malId: String,
        episode: Int,
        requireSkipIntroEnabled: Boolean = true,
        imdbId: String? = null,
        imdbSeason: Int? = null,
        imdbEpisode: Int? = null,
    ): List<SkipInterval> = coroutineScope {
        val settings = PlayerSettingsRepository.uiState.value
        if (requireSkipIntroEnabled && !settings.skipIntroEnabled) {
            InAppLogger.debug("Player/SkipIntro", "skip lookup disabled mal=$malId e=$episode")
            return@coroutineScope emptyList()
        }

        val cacheKey = "mal:$malId:$episode"
        (cache.get(cacheKey) as? SegmentCacheResult.Hit)?.let { cached ->
            InAppLogger.debug("Player/SkipIntro", "skip lookup cache hit mal=$malId e=$episode count=${cached.value.size}")
            return@coroutineScope cached.value
        }
        InAppLogger.info("Player/SkipIntro", "skip lookup mal=$malId e=$episode")

        val aniSkipDeferred = async { fetchFromAniSkip(malId, episode) }

        val imdbIdDeferred = async {
            try {
                SkipIntroApi.resolveMalToImdb(malId)?.imdb
            } catch (_: Exception) { null }
        }

        var introDb = emptyList<SkipInterval>()
        var animeSkip = emptyList<SkipInterval>()
        val imdbId = imdbIdDeferred.await()
        if (imdbId != null) {
            val entries = resolveImdbEntries(imdbId)
            val season = entries.indexOfFirst { it.myanimelist == malId.toIntOrNull() } + 1
            val introDbDeferred = async {
                if (introDbConfigured) fetchFromIntroDb(imdbId, season, episode) else emptyList()
            }
            val animeSkipDeferred = async { fetchAnimeSkipForEntries(entries, season, episode) }
            introDb = introDbDeferred.await()
            animeSkip = animeSkipDeferred.await()
        } else {
            val anilistId = try {
                SkipIntroApi.resolveMalToAnilist(malId)?.anilist?.toString()
            } catch (_: Exception) { null }
            if (anilistId != null) animeSkip = fetchFromAnimeSkip(anilistId, episode, season = null)
        }

        val aniSkip = aniSkipDeferred.await()
        return@coroutineScope mergeByPriority(introDb, aniSkip, animeSkip).also { merged ->
            InAppLogger.info(
                "Player/SkipIntro",
                "skip lookup result mal=$malId e=$episode count=${merged.size} " +
                    "introdb=${introDb.size} animeskip=${animeSkip.size} aniskip=${aniSkip.size}",
            )
            if (merged.isNotEmpty()) cache.put(cacheKey, merged)
        }
    }

    suspend fun getSkipIntervalsForKitsu(
        kitsuId: String,
        episode: Int,
        requireSkipIntroEnabled: Boolean = true,
        imdbId: String? = null,
        imdbSeason: Int? = null,
        imdbEpisode: Int? = null,
    ): List<SkipInterval> = coroutineScope {
        val settings = PlayerSettingsRepository.uiState.value
        if (requireSkipIntroEnabled && !settings.skipIntroEnabled) {
            InAppLogger.debug("Player/SkipIntro", "skip lookup disabled kitsu=$kitsuId e=$episode")
            return@coroutineScope emptyList()
        }

        val cacheKey = "kitsu:$kitsuId:$episode"
        (cache.get(cacheKey) as? SegmentCacheResult.Hit)?.let { cached ->
            InAppLogger.debug("Player/SkipIntro", "skip lookup cache hit kitsu=$kitsuId e=$episode count=${cached.value.size}")
            return@coroutineScope cached.value
        }
        InAppLogger.info("Player/SkipIntro", "skip lookup kitsu=$kitsuId e=$episode")

        val malIdDeferred = async {
            try {
                SkipIntroApi.resolveKitsuToMal(kitsuId)?.myanimelist?.toString()
            } catch (_: Exception) { null }
        }
        val imdbIdDeferred = async {
            try {
                SkipIntroApi.resolveKitsuToImdb(kitsuId)?.imdb
            } catch (_: Exception) { null }
        }
        val aniSkipDeferred = async {
            malIdDeferred.await()?.let { fetchFromAniSkip(it, episode) } ?: emptyList()
        }

        var introDb = emptyList<SkipInterval>()
        var animeSkip = emptyList<SkipInterval>()
        val imdbId = imdbIdDeferred.await()
        if (imdbId != null) {
            val entries = resolveImdbEntries(imdbId)
            val season = entries.indexOfFirst { it.kitsu == kitsuId.toIntOrNull() } + 1
            val introDbDeferred = async {
                if (introDbConfigured) fetchFromIntroDb(imdbId, season, episode) else emptyList()
            }
            val animeSkipDeferred = async { fetchAnimeSkipForEntries(entries, season, episode) }
            introDb = introDbDeferred.await()
            animeSkip = animeSkipDeferred.await()
        } else {
            val anilistId = try {
                SkipIntroApi.resolveKitsuToAnilist(kitsuId)?.anilist?.toString()
            } catch (_: Exception) { null }
            if (anilistId != null) animeSkip = fetchFromAnimeSkip(anilistId, episode, season = null)
        }

        val aniSkip = aniSkipDeferred.await()
        return@coroutineScope mergeByPriority(introDb, aniSkip, animeSkip).also { merged ->
            InAppLogger.info(
                "Player/SkipIntro",
                "skip lookup result kitsu=$kitsuId e=$episode count=${merged.size} " +
                    "introdb=${introDb.size} animeskip=${animeSkip.size} aniskip=${aniSkip.size}",
            )
            if (merged.isNotEmpty()) cache.put(cacheKey, merged)
        }
    }

    /**
     * Merge provider results into one best-of: fill each segment category (opening / ending /
     * recap) from the highest-priority provider that has it. Arguments MUST be passed in priority
     * order (IntroDB has the broadest coverage, then Anime-Skip, then AniSkip), so a partial
     * result from one provider never shadows a complete segment from another.
     */
    private fun mergeByPriority(vararg providerResults: List<SkipInterval>): List<SkipInterval> =
        arbitrate(providerResults.toList(), null, episodic = true)

    private suspend fun <T> withSkipProviderTimeout(
        provider: String,
        timeoutMs: Long,
        fallback: T,
        block: suspend () -> T,
    ): T {
        val result = withTimeoutOrNull(timeoutMs) { block() }
        if (result == null) {
            InAppLogger.warn("Player/SkipIntro", "$provider timed out after ${timeoutMs}ms")
            return fallback
        }
        return result
    }

    // AnimeSkip: season-specific AniList ID first, then season-1 as a season-filtered fallback.
    private suspend fun fetchAnimeSkipForEntries(
        entries: List<ArmEntry>,
        season: Int,
        episode: Int
    ): List<SkipInterval> {
        val seasonAnilistId = entries.getOrNull(season - 1)?.anilist?.toString()
        val fallbackAnilistId = entries.firstOrNull()?.anilist?.toString()
        for ((anilistId, seasonFilter) in listOfNotNull(
            seasonAnilistId?.let { it to null },
            if (fallbackAnilistId != null && fallbackAnilistId != seasonAnilistId) fallbackAnilistId to season else null
        )) {
            val result = fetchFromAnimeSkip(anilistId, episode, season = seasonFilter)
            if (result.isNotEmpty()) return result
        }
        return emptyList()
    }
    private suspend fun fetchFromIntroDb(imdbId: String, season: Int, episode: Int): List<SkipInterval> {
        return withSkipProviderTimeout("IntroDB", INTRO_DB_TIMEOUT_MS, emptyList()) {
            try {
                InAppLogger.debug("Player/SkipIntro", "IntroDB fetch imdb=$imdbId s=$season e=$episode")
                val data = SkipIntroApi.getIntroDbSegments(imdbId, season, episode)
                if (data == null) {
                    InAppLogger.debug("Player/SkipIntro", "IntroDB empty imdb=$imdbId s=$season e=$episode")
                    emptyList()
                } else {
                    listOfNotNull(
                        data.intro.toSkipIntervalOrNull("intro"),
                        data.recap.toSkipIntervalOrNull("recap"),
                        data.outro.toSkipIntervalOrNull("outro"),
                    ).also { result ->
                        InAppLogger.debug("Player/SkipIntro", "IntroDB result imdb=$imdbId s=$season e=$episode count=${result.size}")
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                InAppLogger.warn(
                    "Player/SkipIntro",
                    "IntroDB failed imdb=$imdbId s=$season e=$episode error=${InAppLogger.throwableSummary(error)}",
                )
                emptyList()
            }
        }
    }

    private fun IntroDbSegment?.toSkipIntervalOrNull(type: String): SkipInterval? {
        if (this == null) return null
        val start = startSec ?: startMs?.let { it / 1000.0 }
        val end = endSec ?: endMs?.let { it / 1000.0 }
        if (start == null || end == null || !start.isFinite() || !end.isFinite() || start < 0 || end <= start) return null
        return SkipInterval(startTime = start, endTime = end, type = type, provider = "introdb")
    }

    private suspend fun fetchFromAniSkip(malId: String, episode: Int): List<SkipInterval> {
        return withSkipProviderTimeout("AniSkip", ANISKIP_TIMEOUT_MS, emptyList()) {
            try {
                InAppLogger.debug("Player/SkipIntro", "AniSkip fetch mal=$malId e=$episode")
                val response = SkipIntroApi.getAniSkipTimes(malId, episode)
                when {
                    response == null -> {
                        InAppLogger.debug("Player/SkipIntro", "AniSkip empty mal=$malId e=$episode")
                        emptyList()
                    }
                    !response.found -> {
                        InAppLogger.debug("Player/SkipIntro", "AniSkip not found mal=$malId e=$episode")
                        emptyList()
                    }
                    else -> {
                        response.results?.map { result ->
                            SkipInterval(
                                startTime = result.interval.startTime,
                                endTime = result.interval.endTime,
                                type = result.skipType,
                                provider = "aniskip",
                            )
                        }?.also { result ->
                            InAppLogger.debug("Player/SkipIntro", "AniSkip result mal=$malId e=$episode count=${result.size}")
                        } ?: emptyList()
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                InAppLogger.warn(
                    "Player/SkipIntro",
                    "AniSkip failed mal=$malId e=$episode error=${InAppLogger.throwableSummary(error)}",
                )
                emptyList()
            }
        }
    }

    private suspend fun fetchFromAnimeSkip(anilistId: String, episode: Int, season: Int?): List<SkipInterval> {
        val settings = PlayerSettingsRepository.uiState.value
        val clientId = settings.animeSkipClientId.trim()
        if (clientId.isBlank()) {
            InAppLogger.debug("Player/SkipIntro", "AnimeSkip skipped: client id missing anilist=$anilistId e=$episode")
            return emptyList()
        }
        if (!settings.animeSkipEnabled) {
            InAppLogger.debug("Player/SkipIntro", "AnimeSkip disabled anilist=$anilistId e=$episode")
            return emptyList()
        }

        return withSkipProviderTimeout("AnimeSkip", ANIME_SKIP_TIMEOUT_MS, emptyList()) {
            try {
                InAppLogger.debug("Player/SkipIntro", "AnimeSkip fetch anilist=$anilistId e=$episode season=${season ?: 0}")
                val showIds = resolveAnimeSkipShowIds(anilistId, clientId)
                if (showIds.isEmpty()) {
                    InAppLogger.debug("Player/SkipIntro", "AnimeSkip show id not found anilist=$anilistId")
                    return@withSkipProviderTimeout emptyList()
                }

                for (showId in showIds) {
                    val query = "{ findEpisodesByShowId(showId: \"$showId\") { season number baseDuration timestamps { at type { name } } } }"
                    val response = SkipIntroApi.queryAnimeSkip(clientId, query) ?: continue
                    val episodes = response.data?.findEpisodesByShowId ?: continue

                    val result = episodes
                        .filter { ep ->
                            ep.number?.toIntOrNull() == episode &&
                                (season == null || ep.season?.toIntOrNull() == season)
                        }
                        .bestAnimeSkipIntervals()
                    if (result.isNotEmpty()) {
                        InAppLogger.debug(
                            "Player/SkipIntro",
                            "AnimeSkip result anilist=$anilistId showId=$showId e=$episode count=${result.size}",
                        )
                        return@withSkipProviderTimeout result
                    }
                }
                InAppLogger.debug("Player/SkipIntro", "AnimeSkip empty anilist=$anilistId e=$episode")
                emptyList()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                InAppLogger.warn(
                    "Player/SkipIntro",
                    "AnimeSkip failed anilist=$anilistId e=$episode error=${InAppLogger.throwableSummary(error)}",
                )
                emptyList()
            }
        }
    }

    private suspend fun resolveAnimeSkipShowIds(anilistId: String, clientId: String): List<String> {
        animeSkipShowIdCache[anilistId]?.let { cached ->
            InAppLogger.debug("Player/SkipIntro", "AnimeSkip show id cache hit anilist=$anilistId value=$cached")
            return if (cached == NO_ID) emptyList() else listOf(cached)
        }
        val query = "{ findShowsByExternalId(service: ANILIST, serviceId: \"$anilistId\") { id } }"
        val showIds = withSkipProviderTimeout(
            provider = "AnimeSkip show resolve",
            timeoutMs = ANIME_SKIP_SHOW_LOOKUP_TIMEOUT_MS,
            fallback = emptyList(),
        ) {
            try {
                SkipIntroApi.queryAnimeSkip(clientId, query)
                    ?.data?.findShowsByExternalId?.map { it.id } ?: emptyList()
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                InAppLogger.warn(
                    "Player/SkipIntro",
                    "AnimeSkip show id resolve failed anilist=$anilistId error=${InAppLogger.throwableSummary(error)}",
                )
                emptyList()
            }
        }

        if (showIds.size == 1) animeSkipShowIdCache[anilistId] = showIds[0]
        else if (showIds.isEmpty()) animeSkipShowIdCache[anilistId] = NO_ID
        return showIds
    }

    private suspend fun resolveImdbEntries(imdbId: String): List<ArmEntry> {
        imdbEntriesCache[imdbId]?.let { cached ->
            InAppLogger.debug("Player/SkipIntro", "ARM cache hit imdb=$imdbId entries=${cached.size}")
            return cached
        }
        return withSkipProviderTimeout("ARM resolve", ARM_LOOKUP_TIMEOUT_MS, emptyList()) {
            try {
                SkipIntroApi.resolveImdbToAll(imdbId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                InAppLogger.warn("Player/SkipIntro", "ARM resolve failed imdb=$imdbId error=${InAppLogger.throwableSummary(error)}")
                emptyList()
            }
        }.also { entries ->
            InAppLogger.debug("Player/SkipIntro", "ARM resolve imdb=$imdbId entries=${entries.size}")
            imdbEntriesCache[imdbId] = entries
        }
    }

    suspend fun submitIntro(
        imdbId: String,
        season: Int,
        episode: Int,
        startSec: Double,
        endSec: Double,
        segmentType: String,
    ): Boolean {
        val settings = PlayerSettingsRepository.uiState.value
        val apiKey = settings.introDbApiKey.trim()
        if (!settings.introSubmitEnabled || apiKey.isBlank()) {
            InAppLogger.warn(
                "Player/SkipIntro",
                "submit skipped imdb=$imdbId s=$season e=$episode enabled=${settings.introSubmitEnabled} apiKey=${apiKey.isNotBlank()}",
            )
            return false
        }

        InAppLogger.info(
            "Player/SkipIntro",
            "submit requested imdb=$imdbId s=$season e=$episode type=$segmentType start=$startSec end=$endSec",
        )

        val request = SubmitIntroRequest(
            imdbId = imdbId,
            season = season,
            episode = episode,
            startSec = startSec,
            endSec = endSec,
            startMs = (startSec * 1000).toLong(),
            endMs = (endSec * 1000).toLong(),
            segmentType = segmentType,
        )

        return try {
            SkipIntroApi.submitIntro(apiKey, request).also { success ->
                InAppLogger.info(
                    "Player/SkipIntro",
                    "submit result imdb=$imdbId s=$season e=$episode type=$segmentType success=$success",
                )
            }
        } catch (error: Exception) {
            InAppLogger.warn(
                "Player/SkipIntro",
                "submit failed imdb=$imdbId s=$season e=$episode type=$segmentType " +
                    "error=${InAppLogger.throwableSummary(error)}",
            )
            throw error
        }
    }

    suspend fun verifyIntroDbApiKey(apiKey: String): Boolean {
        InAppLogger.debug("Player/SkipIntro", "verify IntroDB api key requested hasKey=${apiKey.isNotBlank()}")
        return try {
            SkipIntroApi.verifyIntroDbApiKey(apiKey).also { success ->
                InAppLogger.info("Player/SkipIntro", "verify IntroDB api key result success=$success")
            }
        } catch (error: Exception) {
            InAppLogger.warn("Player/SkipIntro", "verify IntroDB api key failed error=${InAppLogger.throwableSummary(error)}")
            throw error
        }
    }

    fun clearCache() {
        cache.clear()
        imdbEntriesCache.clear()
        animeSkipShowIdCache.clear()
        InAppLogger.info("Player/SkipIntro", "skip caches cleared")
    }
}

internal suspend fun resolveMovieSkipImdbId(
    contentId: String?,
    videoId: String?,
    resolveTmdb: suspend (Int) -> String?,
    resolveAnime: suspend (String, String) -> String?,
): String? {
    val ids = listOfNotNull(contentId, videoId).map(String::trim).distinct()
    val imdbPattern = Regex("tt[0-9]+")
    ids.map { it.substringBefore(':') }.firstOrNull { imdbPattern.matches(it) }?.let { return it }
    return ids.firstNotNullOfOrNull { id ->
        val parts = id.split(':')
        val value = parts.getOrNull(1)?.takeIf { it.isNotEmpty() && it.all(Char::isDigit) }
            ?: return@firstNotNullOfOrNull null
        when (parts.first().lowercase()) {
            "tmdb" -> value.toIntOrNull()?.takeIf { it > 0 }?.let { resolveTmdb(it) }
            "mal", "kitsu" -> resolveAnime(parts.first().lowercase(), value)
            else -> null
        }?.trim()?.takeIf { imdbPattern.matches(it) }
    }
}

/**
 * A show can hold several community entries for the same episode number, some of them incomplete.
 * Pick the entry covering the most segment categories (opening / ending / recap), then the one
 * with the most segments; on a tie the earlier entry wins.
 */
internal fun List<AnimeSkipEpisode>.bestAnimeSkipIntervals(): List<SkipInterval> =
    map { it.timestamps.orEmpty().toAnimeSkipIntervals(it.baseDuration) }
        .filter { it.isNotEmpty() }
        .maxWithOrNull(
            compareBy<List<SkipInterval>>(
                { intervals -> intervals.mapNotNull { segmentCategory(it.type) }.toSet().size },
                { it.size }
            )
        )
        .orEmpty()

/**
 * Anime-Skip timestamps only mark where a segment starts; each one ends where the next begins.
 * The last timestamp has no known end. Only an ending may run to the end of the episode, and only
 * when it starts in the second half of it (if the duration is known); an open-ended intro or recap
 * is dropped, since stretching it would skip the whole episode.
 */
internal fun List<AnimeSkipTimestamp>.toAnimeSkipIntervals(baseDuration: Double? = null): List<SkipInterval> {
    val sorted = sortedBy { it.at }
    return sorted.mapIndexedNotNull { i, ts ->
        val type = when (ts.type.name.lowercase()) {
            "intro", "new intro" -> "op"
            "credits", "new credits" -> "ed"
            "mixed intro" -> "mixed-op"
            "mixed credits" -> "mixed-ed"
            "recap" -> "recap"
            else -> return@mapIndexedNotNull null
        }
        val next = sorted.getOrNull(i + 1)
        val endTime = when {
            next != null -> next.at.takeIf { it > ts.at } ?: return@mapIndexedNotNull null
            segmentCategory(type) == "ending" && (baseDuration == null || ts.at >= baseDuration / 2) ->
                Double.MAX_VALUE
            else -> return@mapIndexedNotNull null
        }
        SkipInterval(startTime = ts.at, endTime = endTime, type = type, provider = "animeskip")
    }
}

internal fun segmentCategory(type: String): String? = skipSegmentCategory(type)
