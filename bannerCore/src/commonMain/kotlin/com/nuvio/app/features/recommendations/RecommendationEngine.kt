package com.nuvio.app.features.recommendations

import com.nuvio.app.features.explore.EXPLICIT_KEYWORDS
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.watched.watchedItemKeys
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** A personal row ready for Home: posters in order and an optional short label per title. */
data class PersonalRow(
    val kind: PersonalRowKind,
    val title: String,
    val items: List<MetaPreview>,
    val labels: Map<String, String> = emptyMap(),
)

data class RecommendationState(
    val profileId: Int? = null,
    /** False when the profile has too little history and the main list is the acclaimed-titles fallback. */
    val isPersonal: Boolean = false,
    /** Recommended For You. */
    val items: List<MetaPreview> = emptyList(),
    /** Why each title was picked (the seed title's name), by preview id. */
    val reasons: Map<String, String> = emptyMap(),
    /** The personal rows Home may show, most relevant first; the first [prominentRows] go higher up. */
    val rows: List<PersonalRow> = emptyList(),
    val prominentRows: Int = 0,
    val taste: TasteProfile = TasteProfile.EMPTY,
    /**
     * Watched keys for the TMDB ids ("tmdb:<id>") of finished films and completed series, so TMDB-based lists
     * (Explore) can mark them even when the history stores IMDb ids.
     */
    val watchedTmdbKeys: Set<String> = emptySet(),
    val completedSeriesTmdbKeys: Set<String> = emptySet(),
    val loaded: Boolean = false,
    /** Development builds only; null in release builds. */
    val diagnostics: RecommendationDiagnostics? = null,
)

/** Everything the engine reads, already scoped to the active profile by the repositories that hold it. */
data class RecommendationInputs(
    val profileId: Int,
    val watched: List<WatchedEvidence>,
    val fullyWatchedSeriesKeys: Set<String>,
    val progress: List<ProgressEvidence>,
    val saved: List<SavedEvidence>,
    /** The profile's own 1-10 ratings by "type:appId", when the tracking service has provided them. */
    val ratings: Map<String, Int> = emptyMap(),
    /**
     * TMDB ids of films the profile has watched that the engine has no reason to look up one by one (a big imported history,
     * for example Letterboxd). It looks up only the newest 150 titles, so without these everything older would count as
     * unseen: offered again in the rows, and missing from a franchise's "watched" count.
     */
    val extraWatchedMovieTmdb: Set<Int> = emptySet(),
)

/** A watched film or episode, in the app's own ids. The app maps its watched items to these. */
data class WatchedEvidence(
    val type: String,
    val id: String,
    val name: String,
    val season: Int? = null,
    val episode: Int? = null,
    val markedAtEpochMs: Long,
)

/** Playback progress on a title or episode. */
data class ProgressEvidence(
    val parentMetaType: String,
    val parentMetaId: String,
    val title: String,
    val isCompleted: Boolean,
    val progressPercent: Float? = null,
    val durationMs: Long = 0L,
    val lastPositionMs: Long = 0L,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val lastUpdatedEpochMs: Long,
)

/** A watchlist or library entry. */
data class SavedEvidence(
    val type: String,
    val id: String,
    val name: String,
    val savedAtEpochMs: Long,
)

/** Evidence for one title in the app's own ids, before TMDB ids are resolved. */
data class AppEvidence(val appType: String, val appId: String, val evidence: ViewingEvidence)

// ---------------------------------------------------------------------------------------------------- Evidence

object EvidenceAggregator {
    private fun String.isSeries() = equals("series", true) || equals("tv", true) || equals("show", true)

    /**
     * One record per title. Episodes are counted once each (whether they come from the watched list, completed
     * progress or both), with the time of each kept so the title can be placed across time windows.
     */
    fun aggregate(inputs: RecommendationInputs): List<AppEvidence> {
        class Acc(val type: String, val id: String, var name: String) {
            var finishedMovie = false
            var completed = false
            val episodes = HashMap<Pair<Int, Int>, Long>()
            var fraction: Float? = null
            var saved = false
            var savedAt: Long? = null
            var last = 0L
            val times = ArrayList<Long>()
        }
        val out = LinkedHashMap<String, Acc>()
        fun acc(type: String, id: String, name: String): Acc {
            val tv = type.isSeries()
            return out.getOrPut((if (tv) "series:" else "movie:") + id) { Acc(if (tv) "series" else "movie", id, name) }
        }
        inputs.watched.forEach { item ->
            if (!item.type.isSeries() && !item.type.equals("movie", true)) return@forEach
            val a = acc(item.type, item.id, item.name)
            a.last = maxOf(a.last, item.markedAtEpochMs)
            if (item.type.isSeries()) {
                val s = item.season
                val ep = item.episode
                if (s != null && ep != null) a.episodes[s to ep] = maxOf(a.episodes[s to ep] ?: 0L, item.markedAtEpochMs)
                if (watchedItemKeys(item.type, item.id).any(inputs.fullyWatchedSeriesKeys::contains)) a.completed = true
            } else if (item.season == null && item.episode == null) {
                a.finishedMovie = true
                a.times += item.markedAtEpochMs
            }
        }
        inputs.progress.forEach { entry ->
            val type = entry.parentMetaType
            if (!type.isSeries() && !type.equals("movie", true)) return@forEach
            val a = acc(type, entry.parentMetaId, entry.title)
            a.last = maxOf(a.last, entry.lastUpdatedEpochMs)
            val fraction = when {
                entry.isCompleted -> 1f
                entry.progressPercent != null -> (entry.progressPercent / 100f).coerceIn(0f, 1f)
                entry.durationMs > 0 -> (entry.lastPositionMs.toFloat() / entry.durationMs).coerceIn(0f, 1f)
                else -> 0f
            }
            if (type.isSeries()) {
                val s = entry.seasonNumber
                val ep = entry.episodeNumber
                if (entry.isCompleted && s != null && ep != null) a.episodes[s to ep] = maxOf(a.episodes[s to ep] ?: 0L, entry.lastUpdatedEpochMs)
                else if (!entry.isCompleted) a.fraction = maxOf(a.fraction ?: 0f, fraction)
            } else if (entry.isCompleted) {
                if (!a.finishedMovie) a.times += entry.lastUpdatedEpochMs
                a.finishedMovie = true
            } else {
                a.fraction = maxOf(a.fraction ?: 0f, fraction)
            }
        }
        inputs.saved.forEach { item ->
            if (!item.type.isSeries() && !item.type.equals("movie", true)) return@forEach
            val a = acc(item.type, item.id, item.name)
            a.saved = true
            a.savedAt = item.savedAtEpochMs.takeIf { it > 0 }
            if (a.last == 0L) a.last = item.savedAtEpochMs
        }
        return out.values.map { a ->
            val tv = a.type == "series"
            AppEvidence(
                a.type, a.id,
                ViewingEvidence(
                    tmdbId = 0, tv = tv, name = a.name,
                    finishedMovie = a.finishedMovie,
                    episodesWatched = a.episodes.size,
                    seriesCompleted = a.completed,
                    inProgressFraction = a.fraction,
                    saved = a.saved,
                    savedAtEpochMs = a.savedAt,
                    rating = inputs.ratings["${a.type}:${a.id}"],
                    lastActivityEpochMs = a.last,
                    activityEpochMs = if (tv) a.episodes.values.toList() else a.times,
                ),
            )
        }
    }
}

/**
 * Which of the profile's titles the engine looks up one by one (each costs a request and shapes taste). Newest-first alone
 * makes taste whatever happened last month, so the sample is three groups: the newest, the profile's own favourites (rated
 * 4.5 stars or more) and an even spread across everything in between. Every other watched title is still known by id and
 * excluded; it just doesn't add taste.
 */
object SampleSelection {
    const val RECENT = 100
    const val LOVED = 80
    const val SPREAD = 60
    /** Ratings are 1..10; 9 is 4.5 stars. */
    const val LOVED_RATING = 9

    fun history(started: List<AppEvidence>): List<AppEvidence> {
        if (started.size <= RECENT + LOVED + SPREAD) return started.sortedByDescending { it.evidence.lastActivityEpochMs }
        val byRecency = started.sortedByDescending { it.evidence.lastActivityEpochMs }
        val recent = byRecency.take(RECENT)
        val recentKeys = recent.mapTo(HashSet()) { it.appType + ":" + it.appId }
        val loved = byRecency.filter { (it.evidence.rating ?: 0) >= LOVED_RATING && (it.appType + ":" + it.appId) !in recentKeys }
            .sortedWith(compareByDescending<AppEvidence> { it.evidence.rating ?: 0 }.thenByDescending { it.evidence.lastActivityEpochMs })
            .take(LOVED)
        val taken = recentKeys + loved.map { it.appType + ":" + it.appId }
        val rest = byRecency.filter { (it.appType + ":" + it.appId) !in taken }
        // Evenly spaced through the remaining history, oldest to newest.
        val spread = if (rest.size <= SPREAD) rest else (0 until SPREAD).map { i -> rest[(i.toLong() * rest.size / SPREAD).toInt()] }
        return recent + loved + spread
    }
}

// ---------------------------------------------------------------------------------------------------- Builder

/**
 * Builds the recommendations for one profile. Steps, all through [RecommendationData]:
 *  1. Resolve the profile's titles to TMDB ids and fetch their details (genres, keywords, cast, creators, the film
 *     series they belong to, and TMDB's recommendations and similar titles).
 *  2. Build the taste profile over the whole history (TasteProfile), actor affinity and window-balanced seeds.
 *  3. Gather candidates: seeds' recommendations, genre affinity, favourite actors' and directors' work, acclaimed
 *     older titles. Everything the profile watched, started, saved or disliked is excluded.
 *  4. Score, enrich the shortlist with full details, and rerank with MMR under a soft franchise cap and format mix.
 *  5. Build the five personal rows, check which picks can be watched at home, and coordinate them.
 */
class RecommendationBuilder(
    private val data: RecommendationData,
    private val universes: List<UniverseDef> = Continuities.all,
    private val tasteRules: TasteRules = TasteRules(),
    private val rowRules: RowRules = RowRules(),
    private val withDiagnostics: Boolean = false,
) {
    private val index = FranchiseIndex(universes)
    private val franchiseOf: (TitleMeta) -> String? = { index.franchiseKey(it) }

    private companion object {
        const val MAX_SAVED_TITLES = 60
        const val SHORTLIST = 48
        const val TOP_ACTORS = 10
        const val TOP_CREATORS = 3
        val TV_GENRES = setOf(10759, 16, 35, 80, 99, 18, 10751, 10762, 9648, 10764, 10765, 10766, 10768, 37)
        val MOVIE_GENRES = setOf(28, 12, 16, 35, 80, 99, 18, 10751, 14, 36, 27, 10402, 9648, 10749, 878, 53, 10752, 37)
        val MOVIE_TO_TV = mapOf(28 to 10759, 12 to 10759, 878 to 10765, 14 to 10765, 10752 to 10768)
        val TV_TO_MOVIE = mapOf(10759 to 28, 10765 to 878, 10768 to 10752)
    }

    suspend fun build(inputs: RecommendationInputs, nowMs: Long): RecommendationState = coroutineScope {
        val today = data.today()
        val diag = if (withDiagnostics) DiagnosticsCollector() else null
        val appEvidence = EvidenceAggregator.aggregate(inputs)
        diag?.history(inputs, appEvidence)

        // 1. TMDB ids and details for the titles that matter: everything watched or started, and a share of saved ones.
        val activity = SampleSelection.history(appEvidence.filter { it.evidence.started })
        val savedOnly = appEvidence.filter { it.evidence.saved && !it.evidence.started }.sortedByDescending { it.evidence.savedAtEpochMs ?: 0L }
        // Half the newest and half the oldest saved titles, so the forgotten row sees both ends of the list.
        val savedPick = (savedOnly.take(MAX_SAVED_TITLES / 2) + savedOnly.takeLast(MAX_SAVED_TITLES / 2)).distinct()
        // Each lookup ends as 0 (no TMDB id), 1 (no details) or a resolved title.
        val lookups = (activity + savedPick).map { a ->
            async {
                val id = data.tmdbId(a.appType, a.appId) ?: return@async 0 to null
                val e = a.evidence.copy(tmdbId = id)
                val d = data.details(e.tv, id) ?: return@async 1 to null
                2 to Triple(a, e, d)
            }
        }.awaitAll()
        val resolved = lookups.mapNotNull { it.second }.distinctBy { it.second.key }
        diag?.resolved(lookups.size, resolved.size, lookups.count { it.first == 0 }, lookups.count { it.first == 1 })

        val evidence = resolved.associateTo(HashMap()) { it.second.key to it.second }
        // Films known to be watched without a lookup: they count as finished (so a franchise sees them, and nothing offers them
        // again) but add no taste, since there is no detail to learn from.
        inputs.extraWatchedMovieTmdb.forEach { id ->
            val key = titleKey(false, id)
            if (key !in evidence) evidence[key] = ViewingEvidence(tmdbId = id, tv = false, name = "", finishedMovie = true, lastActivityEpochMs = 0L)
        }
        val history = resolved.map { it.second to it.third.meta }
        val watchedHistory = history.filter { it.first.started }
        val excluded = resolved.filter { it.second.started || it.second.saved || it.second.disliked }.mapTo(HashSet()) { it.second.key }
            .also { set -> inputs.extraWatchedMovieTmdb.forEach { set += titleKey(false, it) } }
        val watchedTmdbKeys = evidence.values.filter { !it.tv && it.finishedMovie }
            .flatMapTo(HashSet()) { watchedItemKeys("movie", "tmdb:${it.tmdbId}") }
        val completedSeriesTmdbKeys = resolved.filter { it.second.tv && it.second.seriesCompleted }
            .flatMapTo(HashSet()) { watchedItemKeys("series", "tmdb:${it.second.tmdbId}") }

        // 2. Taste, actors, seeds.
        val taste = TasteProfile.build(history, nowMs, tasteRules, franchiseOf)
        val affinities = ActorAffinities.compute(watchedHistory, nowMs, franchiseOf = franchiseOf)
        val actorScores = affinities.firstOrNull()?.score?.let { top -> affinities.associate { it.person.id to it.score / top } }.orEmpty()
        val seeds = SeedSelection.select(history, taste, nowMs, tasteRules, franchiseOf)
        diag?.taste(taste, affinities, seeds)

        if (seeds.isEmpty() || taste.isEmpty) {
            val fallback = fallback(excluded, today)
            val forgotten = PersonalRows.forgottenWatchlist(history.filter { it.first.saved }, taste, actorScores, nowMs, rowRules)
            val plan = PersonalRows.coordinate(fallback.map { RowPick(it, 0.0, null) }, listOf(forgotten), rowRules) { true }
            diag?.plan(plan, emptyList())
            return@coroutineScope state(inputs.profileId, false, plan, taste, watchedTmdbKeys, completedSeriesTmdbKeys, diag)
        }

        // 3. Candidates.
        val pool = HashMap<String, Candidate>()
        fun add(meta: TitleMeta, source: CandidateSource, hit: SeedHit? = null) {
            if (meta.key in excluded || !meta.releasedBy(today) || meta.voteCount < 40 || meta.preview == null) return
            val existing = pool[meta.key]
            pool[meta.key] = if (existing == null) Candidate(meta, setOf(source), listOfNotNull(hit))
            else existing.copy(sources = existing.sources + source, hits = existing.hits + listOfNotNull(hit))
        }
        val detailsByKey = resolved.associate { it.second.key to it.third }
        for (seed in seeds) {
            val d = detailsByKey[seed.meta.key] ?: continue
            d.recommendations.forEachIndexed { rank, m -> add(m, CandidateSource.Recommended, SeedHit(seed.meta.key, seed.meta.name, seed.weight, rank, false)) }
            d.similar.take(12).forEachIndexed { rank, m -> add(m, CandidateSource.Similar, SeedHit(seed.meta.key, seed.meta.name, seed.weight, rank, true)) }
        }
        val topGenres = taste.genres.entries.sortedByDescending { it.value }.take(4).map { it.key }
        val formats = when {
            taste.seriesShare < 0.15 -> listOf(false)
            taste.seriesShare > 0.85 -> listOf(true)
            else -> listOf(false, true)
        }
        val genrePairs = formats.flatMap { tv -> topGenres.mapNotNull { g -> genreFor(g, tv)?.let { tv to it } } }.distinct()
        val genreLists = genrePairs.map { (tv, g) ->
            async {
                data.discover(
                    tv,
                    mapOf(
                        "with_genres" to g.toString(), "sort_by" to "popularity.desc", "vote_average.gte" to "7.0",
                        "vote_count.gte" to if (tv) "200" else "500", "include_adult" to "false",
                        "without_keywords" to EXPLICIT_KEYWORDS, "without_genres" to "10767,10763",
                    ),
                )
            }
        }
        val actorCredits = affinities.take(TOP_ACTORS).map { a -> async { a.person.id to data.personCredits(a.person.id) } }
        val topCreators = taste.creators.entries.sortedByDescending { it.value }.take(TOP_CREATORS).map { it.key }
        val creatorCredits = topCreators.map { id -> async { id to data.personCredits(id) } }
        val cutoff = (today.take(4).toIntOrNull() ?: 2000) - rowRules.missedMinAgeYears
        val olderLists = genrePairs.map { (tv, g) ->
            async {
                data.discover(
                    tv,
                    mapOf(
                        "with_genres" to g.toString(), "sort_by" to "vote_count.desc", "vote_average.gte" to "7.2",
                        "vote_count.gte" to if (tv) "150" else "300",
                        (if (tv) "first_air_date.lte" else "primary_release_date.lte") to "$cutoff-12-31",
                        "include_adult" to "false", "without_keywords" to EXPLICIT_KEYWORDS, "without_genres" to "10767,10763",
                    ),
                )
            }
        }
        genreLists.awaitAll().flatten().forEach { add(it, CandidateSource.Genre) }
        val creditsByActor = actorCredits.awaitAll().mapNotNull { (id, c) -> c?.let { id to it } }.toMap()
        val actorNames = affinities.associate { it.person.id to it.person.name }
        creditsByActor.forEach { (actorId, credits) ->
            credits.cast.filter { PersonalRows.isRealRole(it) }.forEach { c ->
                add(c.meta.copy(cast = listOf(Person(actorId, actorNames[actorId] ?: "", c.order ?: 0))), CandidateSource.Actor)
            }
        }
        val creatorNames = history.flatMap { it.second.creators }.associate { it.id to it.name }
        val directedOlder = ArrayList<TitleMeta>()
        creatorCredits.awaitAll().forEach { (id, c) ->
            c?.directed?.forEach { m ->
                val withCreator = m.copy(creators = listOf(Person(id, creatorNames[id] ?: "")))
                add(withCreator, CandidateSource.Creator)
                directedOlder += withCreator
            }
        }
        val older = olderLists.awaitAll().flatten()
        older.forEach { add(it, CandidateSource.Acclaimed) }
        diag?.candidates(pool.values.toList())

        // 4. Score, enrich the shortlist, rerank for diversity.
        val collabMax = pool.values.maxOfOrNull { CandidateScoring.collaborative(it) } ?: 0.0
        val firstPass = pool.values.map { CandidateScoring.score(it, taste, actorScores, collabMax) }.sortedByDescending { it.relevance }
        val shortlist = firstPass.take(SHORTLIST).map { s ->
            async {
                val full = data.details(s.meta.tv, s.meta.tmdbId)?.meta
                val merged = if (full == null) s.meta else full.copy(preview = s.meta.preview ?: full.preview)
                CandidateScoring.score(s.candidate.copy(meta = merged), taste, actorScores, collabMax)
            }
        }.awaitAll()
        val franchisePenalty = Diversity.franchisePenalty(rowRules.mainSize, rowRules.maxFranchiseShare, franchiseOf)
        val formatPenalty = Diversity.formatPenalty(taste.seriesShare)
        val mainRanked = Diversity.mmr(
            shortlist,
            size = rowRules.mainSize * 2,
            relevance = { it.relevance },
            similarity = { a, b -> Diversity.similarity(a.meta, b.meta, franchiseOf) },
            penalty = { c, picked ->
                val metas = picked.map { it.meta }
                franchisePenalty(c.meta, metas) + formatPenalty(c.meta, metas)
            },
        )
        diag?.main(mainRanked, franchiseOf)

        // 5. Personal rows.
        val units = franchiseUnits(history, today)
        val complete = PersonalRows.completeFranchise(units, evidence, nowMs, rowRules)
        val universeUnits = universeUnits(history, today, nowMs)
        val universe = PersonalRows.continueUniverse(
            universeUnits, evidence, taste, nowMs, today,
            excluded = complete.ranked.take(rowRules.rowSize).mapTo(HashSet()) { it.meta.key }, rules = rowRules,
        )
        val forgotten = PersonalRows.forgottenWatchlist(history.filter { it.first.saved }, taste, actorScores, nowMs, rowRules)
        val actors = PersonalRows.favouriteActors(affinities.take(TOP_ACTORS), creditsByActor.mapValues { it.value.cast }, taste, excluded, today, rowRules, franchiseOf)
        val actorLabels = affinities.take(TOP_ACTORS).associate { it.person.id to (it.score to it.person.name) }
        val olderCandidates = (older + directedOlder + firstPass.map { it.meta }).filter { it.key !in excluded && it.preview != null }
        val mainstream = watchedHistory.count { it.second.popularity >= 40 || it.second.voteCount >= 5000 }.toDouble() /
            watchedHistory.size.coerceAtLeast(1)
        val missed = PersonalRows.mightHaveMissed(olderCandidates, taste, actorLabels, today, rowRules, mainstream)
        val rows = listOf(complete, universe, forgotten, actors, missed)

        val mainPicks = mainRanked.map { RowPick(it.meta, it.relevance, it.reason) }
        val toCheck = (mainPicks.take(rowRules.mainSize + 12) + rows.flatMap { it.ranked.take(rowRules.rowSize + 8) })
            .map { it.meta }.distinctBy { it.key }
        val availability = toCheck.map { m -> async { m.key to data.available(m) } }.awaitAll().toMap()
        val plan = PersonalRows.coordinate(mainPicks, rows, rowRules) { availability[it.key] == true }
        diag?.rows(rows)
        diag?.plan(plan, toCheck.filter { availability[it.key] != true }.map { it.name })

        state(inputs.profileId, true, plan, taste, watchedTmdbKeys, completedSeriesTmdbKeys, diag)
    }

    private fun state(
        profileId: Int,
        personal: Boolean,
        plan: PersonalRows.Plan,
        taste: TasteProfile,
        watched: Set<String>,
        completed: Set<String>,
        diag: DiagnosticsCollector?,
    ): RecommendationState = RecommendationState(
        profileId = profileId,
        isPersonal = personal,
        items = plan.main.mapNotNull { it.meta.preview },
        reasons = plan.main.mapNotNull { p -> p.label?.let { r -> p.meta.preview?.id?.let { it to r } } }.toMap(),
        rows = plan.rows.map { (kind, picks) ->
            PersonalRow(
                kind, kind.title, picks.mapNotNull { it.meta.preview },
                picks.mapNotNull { p -> p.label?.let { l -> p.meta.preview?.id?.let { it to l } } }.toMap(),
            )
        },
        prominentRows = plan.prominent,
        taste = taste,
        watchedTmdbKeys = watched,
        completedSeriesTmdbKeys = completed,
        loaded = true,
        diagnostics = diag?.result(),
    )

    private fun genreFor(genre: Int, tv: Boolean): Int? = when {
        tv && genre in TV_GENRES -> genre
        tv -> MOVIE_TO_TV[genre]
        genre in MOVIE_GENRES -> genre
        else -> TV_TO_MOVIE[genre]
    }

    /** Film series the profile has films in: every TMDB movie collection of a watched or started film. */
    private suspend fun franchiseUnits(history: List<Pair<ViewingEvidence, TitleMeta>>, today: String): List<FranchiseUnit> = coroutineScope {
        history.filter { it.first.started && !it.first.tv }.mapNotNull { it.second.collectionId }.distinct().map { id ->
            async {
                val c = data.movieCollection(id) ?: return@async null
                FranchiseUnit("coll:$id", c.name, index.groupOf(id, c.parts), c.parts.filter { it.releasedBy(today) })
            }
        }.awaitAll().filterNotNull()
    }

    /** Universes the profile has meaningfully watched something in, with all their released titles. */
    private suspend fun universeUnits(history: List<Pair<ViewingEvidence, TitleMeta>>, today: String, nowMs: Long): List<UniverseUnit> = coroutineScope {
        val engaged = universes.filter { u ->
            history.any { (e, m) ->
                RecommendationScoring.meaningful(e, nowMs) && (m.key in u.refs || (m.collectionId != null && m.collectionId in u.collectionIds))
            }
        }
        engaged.map { u ->
            async {
                val fromRefs = u.refs.map { key ->
                    async {
                        val parts = key.split(":")
                        data.details(parts[0] == "tv", parts[1].toInt())?.meta
                    }
                }.awaitAll().filterNotNull()
                val fromCollections = u.collectionIds.map { id -> async { data.movieCollection(id)?.parts.orEmpty() } }.awaitAll().flatten()
                val members = (fromRefs + fromCollections).distinctBy { it.key }.filter { it.releasedBy(today) && it.preview != null }
                UniverseUnit(u.id, u.name, members)
            }
        }.awaitAll()
    }

    /** For a profile without enough history: popular, well-reviewed films and series. Shown under its own title. */
    private suspend fun fallback(excluded: Set<String>, today: String): List<TitleMeta> = coroutineScope {
        val films = async {
            data.discover(
                false,
                mapOf("vote_average.gte" to "7.5", "vote_count.gte" to "3000", "sort_by" to "popularity.desc", "include_adult" to "false", "without_keywords" to EXPLICIT_KEYWORDS),
            )
        }
        val shows = async {
            data.discover(true, mapOf("vote_average.gte" to "8", "vote_count.gte" to "1500", "sort_by" to "popularity.desc", "without_genres" to "10767,10763,10764,16"))
        }
        val a = films.await().filter { it.key !in excluded && it.releasedBy(today) }
        val b = shows.await().filter { it.key !in excluded && it.releasedBy(today) }
        (0 until maxOf(a.size, b.size)).flatMap { listOfNotNull(a.getOrNull(it), b.getOrNull(it)) }
    }
}

// ---------------------------------------------------------------------------------------------------- Engine

/**
 * Recommended For You and the personal rows for the active profile. Builds run in the background, one at a time;
 * results are cached per profile and rebuilt only when that profile's history, watchlist or ratings change, or after
 * a few hours. A build that hits network failures never replaces a good row with an empty one. Switching profiles
 * never shows another profile's results.
 */
object RecommendationEngine {
    private const val REFRESH_MS = 6L * 60 * 60 * 1000

    /** Development builds collect diagnostics (shown under Settings › Advanced › Debug logs). */
    var diagnosticsEnabled: Boolean = false

    /** The metadata provider; set once by the host app with [install] (the core has no network of its own). */
    var data: RecommendationData? = null
        private set

    /** Connects the engine to a metadata provider. Safe to call repeatedly; the first provider stays until replaced. */
    fun install(provider: RecommendationData, diagnostics: Boolean = false) {
        data = provider
        diagnosticsEnabled = diagnostics
    }

    private fun nowMs(): Long = kotlin.time.Clock.System.now().toEpochMilliseconds()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val _state = MutableStateFlow(RecommendationState())
    val state: StateFlow<RecommendationState> = _state.asStateFlow()

    private val lock = Mutex()
    private val byProfile = HashMap<Int, Triple<String, Long, RecommendationState>>()
    private val cacheEvents = ArrayList<String>()
    private var job: Job? = null
    private var jobKey: String? = null

    /** What changed in the cache recently (diagnostics). */
    fun cacheLog(): List<String> = cacheEvents.toList()

    private fun log(event: String) {
        if (!diagnosticsEnabled) return
        cacheEvents += event
        if (cacheEvents.size > 40) cacheEvents.removeAt(0)
    }

    /** A fingerprint of what the recommendations depend on, so unchanged history doesn't trigger a rebuild. */
    fun signature(inputs: RecommendationInputs): String = listOf(
        inputs.watched.size, inputs.watched.maxOfOrNull { it.markedAtEpochMs } ?: 0L, inputs.fullyWatchedSeriesKeys.size,
        inputs.progress.size, inputs.progress.maxOfOrNull { it.lastUpdatedEpochMs } ?: 0L,
        inputs.saved.size, inputs.saved.maxOfOrNull { it.savedAtEpochMs } ?: 0L, inputs.ratings.hashCode(),
        inputs.extraWatchedMovieTmdb.size, inputs.extraWatchedMovieTmdb.hashCode(),
    ).joinToString("|")

    fun refresh(inputs: RecommendationInputs, force: Boolean = false) {
        val source = data ?: return
        val signature = signature(inputs)
        val key = "${inputs.profileId}#$signature"
        scope.launch {
            val cached = lock.withLock { byProfile[inputs.profileId] }
            if (_state.value.profileId != inputs.profileId) {
                _state.value = cached?.third ?: RecommendationState(profileId = inputs.profileId)
                log("profile ${inputs.profileId}: ${if (cached != null) "showing cached results" else "nothing cached yet"}")
            }
            val now = nowMs()
            if (!force && cached != null && cached.first == signature && now - cached.second < REFRESH_MS) {
                log("profile ${inputs.profileId}: cache still valid")
                return@launch
            }
            lock.withLock {
                if (job?.isActive == true && jobKey == key) return@launch
                job?.cancel()
                jobKey = key
                log(
                    when {
                        cached == null -> "profile ${inputs.profileId}: first build"
                        cached.first != signature -> "profile ${inputs.profileId}: history, watchlist or ratings changed; rebuilding"
                        else -> "profile ${inputs.profileId}: cache expired; rebuilding"
                    },
                )
                job = scope.launch {
                    val failuresBefore = source.failureCount
                    val built = runCatching {
                        RecommendationBuilder(source, withDiagnostics = diagnosticsEnabled).build(inputs, nowMs())
                    }.getOrNull() ?: return@launch
                    val networkTrouble = source.failureCount > failuresBefore
                    val result = if (networkTrouble && cached != null) keepGood(cached.third, built) else built
                    if (networkTrouble) log("profile ${inputs.profileId}: some requests failed; kept earlier rows where the new ones came back empty")
                    lock.withLock { byProfile[inputs.profileId] = Triple(signature, nowMs(), result) }
                    if (_state.value.profileId == inputs.profileId || _state.value.profileId == null) _state.value = result
                }
            }
        }
    }

    /** After a build that hit failures: keep the earlier main list and rows wherever the new ones came back empty. */
    fun keepGood(old: RecommendationState, new: RecommendationState): RecommendationState {
        val items = if (new.items.isEmpty()) old.items else new.items
        val newKinds = new.rows.map { it.kind }.toSet()
        val rows = new.rows + old.rows.filter { it.kind !in newKinds }
        return new.copy(items = items, rows = rows, prominentRows = maxOf(new.prominentRows, minOf(old.prominentRows, rows.size)))
    }
}
