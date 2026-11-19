package com.nuvio.app.features.recommendations

import com.nuvio.app.features.home.MetaPreview
import kotlin.math.ceil
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/*
 * The pure part of the recommendations: what a viewing says about taste, the taste profile built from the whole
 * history, actor affinity, candidate scoring and diversity-aware reranking. No network and no repositories, so every
 * rule here is unit-tested with fixture data (see RecommendationScoringTest and RecommendationScenarioTest).
 */

const val DAY_MS: Long = 24L * 60 * 60 * 1000

/** "movie:603" / "tv:1396": the TMDB identity every recommendation works in. */
fun titleKey(tv: Boolean, tmdbId: Int): String = (if (tv) "tv:" else "movie:") + tmdbId

data class Person(val id: Int, val name: String, val order: Int = 0)

/** What the recommendations know about a title. Lists come back with genres and scores only; details add the rest. */
data class TitleMeta(
    val tmdbId: Int,
    val tv: Boolean,
    val name: String,
    val genres: List<Int> = emptyList(),
    val keywords: List<Int> = emptyList(),
    /** Billed cast, in billing order. */
    val cast: List<Person> = emptyList(),
    /** Directors (films) or creators (series). */
    val creators: List<Person> = emptyList(),
    val language: String? = null,
    /** TMDB movie collection (the provider's own verified film series), if any. */
    val collectionId: Int? = null,
    val releaseDate: String? = null,
    val voteAverage: Double = 0.0,
    val voteCount: Int = 0,
    val popularity: Double = 0.0,
    val preview: MetaPreview? = null,
) {
    val key: String get() = titleKey(tv, tmdbId)
    val year: Int? get() = releaseDate?.take(4)?.toIntOrNull()
    fun releasedBy(today: String): Boolean = releaseDate?.let { it.isNotBlank() && it <= today } == true
}

/** Genres that say nothing about taste in a list of recommendations: talk shows, news. */
val NON_TASTE_GENRES = setOf(10767, 10763)

/** What the profile did with one title, aggregated at the title level (a series is one title, not N episodes). */
data class ViewingEvidence(
    val tmdbId: Int,
    val tv: Boolean,
    val name: String,
    /** A film watched to the end (or marked watched). */
    val finishedMovie: Boolean = false,
    /** Distinct episodes of a series watched. */
    val episodesWatched: Int = 0,
    /** Every episode of the series watched. */
    val seriesCompleted: Boolean = false,
    /** Furthest progress through a title still in progress (0..1), or null. */
    val inProgressFraction: Float? = null,
    /** Saved to My List / the library. */
    val saved: Boolean = false,
    /** When it was saved, if the library recorded it. */
    val savedAtEpochMs: Long? = null,
    /** The profile's own rating, 1..10, when one is available. */
    val rating: Int? = null,
    /** When the profile last did anything with the title. */
    val lastActivityEpochMs: Long,
    /** When each viewing event happened (each episode, or the film), used to place the title in time windows. */
    val activityEpochMs: List<Long> = emptyList(),
) {
    val key: String get() = titleKey(tv, tmdbId)
    val watched: Boolean get() = finishedMovie || seriesCompleted || episodesWatched > 0
    val started: Boolean get() = watched || (inProgressFraction ?: 0f) > 0f
    val disliked: Boolean get() = rating != null && rating <= 4
}

object RecommendationScoring {
    /** Progress below this is treated as "opened it", not as watching: it barely counts. */
    const val BRIEF_OPEN_FRACTION = 0.15f
    private const val ABANDONED_MAX_EPISODES = 2
    private const val ABANDONED_AFTER_DAYS = 120

    /**
     * How strongly a title says the profile enjoys this kind of thing, 0..~1.4, ignoring when it happened (time is
     * handled by the windows in [TasteProfile]). A series is one title however many episodes were watched: engagement
     * grows with episodes but saturates around 20, so Shark Tank's 300 episodes count as one strong title, not 300.
     */
    fun engagement(e: ViewingEvidence, nowMs: Long): Double {
        if (e.disliked) return 0.0
        val ageDays = max(0L, nowMs - e.lastActivityEpochMs) / DAY_MS
        val watching = when {
            e.tv && e.seriesCompleted -> 1.2
            e.tv && e.episodesWatched >= 3 -> 0.6 + 0.4 * min(1.0, ln(1.0 + e.episodesWatched) / ln(21.0))
            e.tv && e.episodesWatched in 1..ABANDONED_MAX_EPISODES -> if (ageDays > ABANDONED_AFTER_DAYS) 0.1 else 0.3
            !e.tv && e.finishedMovie -> 1.0
            else -> 0.0
        }
        val f = e.inProgressFraction
        val progress = when {
            f == null -> 0.0
            f < BRIEF_OPEN_FRACTION -> 0.0
            else -> 0.2 + 0.5 * f.coerceAtMost(1f)
        }
        val ratingBoost = when (val r = e.rating) {
            null -> 0.0
            in 8..10 -> 0.3
            in 6..7 -> 0.1
            else -> 0.0
        }
        val base = max(watching, progress)
        return if (base == 0.0) 0.0 else base + ratingBoost
    }

    /** Explicit positive feedback: a high rating, or saving a title (a weaker signal of intent). */
    fun explicitStrength(e: ViewingEvidence): Double {
        if (e.disliked) return 0.0
        val rated = when (val r = e.rating) { null -> 0.0; in 8..10 -> 1.0; in 6..7 -> 0.4; else -> 0.0 }
        val saved = if (e.saved) 0.5 else 0.0
        return max(rated, saved)
    }

    /** True when the title meaningfully engaged the profile (finished, several episodes, or well into it). */
    fun meaningful(e: ViewingEvidence, nowMs: Long): Boolean = engagement(e, nowMs) >= 0.3
}

// ---------------------------------------------------------------------------------------------------- Taste windows

enum class TasteWindow { LongTerm, MediumTerm, Recent, Explicit }

/** Tunable rules. The percentages are starting points from the product spec, adjusted by evidence size. */
data class TasteRules(
    val recentDays: Int = 21,
    val mediumDays: Int = 120,
    val weights: Map<TasteWindow, Double> = mapOf(
        TasteWindow.LongTerm to 0.45,
        TasteWindow.MediumTerm to 0.25,
        TasteWindow.Recent to 0.15,
        TasteWindow.Explicit to 0.15,
    ),
    /** A window with fewer titles than this gets a proportionally smaller share; the rest goes to the others. */
    val fullConfidenceTitles: Int = 4,
)

/** One window's normalized preferences (each map sums to 1) and how many titles it was built from. */
data class WindowTaste(
    val titles: Int,
    val genres: Map<Int, Double>,
    val seriesShare: Double,
)

/**
 * Preferences over genres, keywords, creators, languages, formats and franchises.
 *
 * Built from four windows that never share an event: long-term (activity older than [TasteRules.mediumDays]),
 * medium-term (between [TasteRules.recentDays] and that), recent, and explicit feedback (saved and rated titles). A
 * series watched across months is split across windows in proportion to when its episodes were watched. Each window
 * is normalized on its own and then weighted, so twenty films logged this week can move at most the recent window's
 * share of the profile, not the whole of it. A window with too few titles hands part of its weight to the others.
 *
 * Maps used for matching are scaled so the strongest entry is 1.
 */
data class TasteProfile(
    val genres: Map<Int, Double>,
    val keywords: Map<Int, Double>,
    val creators: Map<Int, Double>,
    val languages: Map<String, Double>,
    /** Share of the profile's attention that goes to series (0..1). */
    val seriesShare: Double,
    /** Share of attention per franchise key, for diagnostics and concentration checks. */
    val franchises: Map<String, Double> = emptyMap(),
    val windows: Map<TasteWindow, WindowTaste> = emptyMap(),
    /** The window weights actually used after redistribution. */
    val effectiveWeights: Map<TasteWindow, Double> = emptyMap(),
) {
    val isEmpty: Boolean get() = genres.isEmpty()

    /** Genre match of a title, 0..1. */
    fun genreMatch(genres: List<Int>): Double = matchList(genres, this.genres)
    fun keywordMatch(keywords: List<Int>): Double = matchList(keywords, this.keywords)
    fun creatorMatch(creators: List<Person>): Double = creators.maxOfOrNull { this.creators[it.id] ?: 0.0 } ?: 0.0
    fun windowGenreMatch(window: TasteWindow, genres: List<Int>): Double {
        val g = windows[window]?.genres ?: return 0.0
        val top = g.values.maxOrNull() ?: return 0.0
        return matchList(genres, g.mapValues { it.value / top })
    }

    companion object {
        val EMPTY = TasteProfile(emptyMap(), emptyMap(), emptyMap(), emptyMap(), 0.5)

        internal fun matchList(items: List<Int>, weights: Map<Int, Double>): Double {
            if (items.isEmpty() || weights.isEmpty()) return 0.0
            return min(1.0, items.sumOf { weights[it] ?: 0.0 } / sqrt(items.size.toDouble()))
        }

        /** How a title's attention is split over the windows (shares sum to 1; explicit is handled separately). */
        internal fun windowShares(e: ViewingEvidence, nowMs: Long, rules: TasteRules): Map<TasteWindow, Double> {
            val times = e.activityEpochMs.ifEmpty { listOf(e.lastActivityEpochMs) }
            val counts = HashMap<TasteWindow, Int>()
            times.forEach { t ->
                val days = max(0L, nowMs - t) / DAY_MS
                val w = when {
                    days <= rules.recentDays -> TasteWindow.Recent
                    days <= rules.mediumDays -> TasteWindow.MediumTerm
                    else -> TasteWindow.LongTerm
                }
                counts[w] = (counts[w] ?: 0) + 1
            }
            return counts.mapValues { it.value.toDouble() / times.size }
        }

        fun build(
            history: List<Pair<ViewingEvidence, TitleMeta>>,
            nowMs: Long,
            rules: TasteRules = TasteRules(),
            franchiseOf: (TitleMeta) -> String? = { it.collectionId?.let { id -> "coll:$id" } },
        ): TasteProfile {
            class Acc {
                val genres = HashMap<Int, Double>()
                val keywords = HashMap<Int, Double>()
                val creators = HashMap<Int, Double>()
                val languages = HashMap<String, Double>()
                val franchises = HashMap<String, Double>()
                val titles = HashSet<String>()
                var series = 0.0
                var mass = 0.0
            }
            val acc = TasteWindow.entries.associateWith { Acc() }
            val keywordTitles = HashMap<Int, Int>()
            val creatorTitles = HashMap<Int, Int>()

            fun add(window: TasteWindow, w: Double, e: ViewingEvidence, m: TitleMeta) {
                if (w <= 0.0) return
                val a = acc.getValue(window)
                val genres = m.genres.filterNot { it in NON_TASTE_GENRES }
                // A title spreads its weight over its genres, so a four-genre title isn't four times a one-genre one.
                genres.forEach { a.genres[it] = (a.genres[it] ?: 0.0) + w / genres.size }
                val kws = m.keywords.take(12)
                kws.forEach { a.keywords[it] = (a.keywords[it] ?: 0.0) + w / sqrt(kws.size.toDouble()) }
                m.creators.forEach { a.creators[it.id] = (a.creators[it.id] ?: 0.0) + w }
                m.language?.let { a.languages[it] = (a.languages[it] ?: 0.0) + w }
                franchiseOf(m)?.let { a.franchises[it] = (a.franchises[it] ?: 0.0) + w }
                if (e.tv) a.series += w
                a.mass += w
                a.titles += e.key
            }

            for ((e, m) in history) {
                val engagement = RecommendationScoring.engagement(e, nowMs)
                if (engagement > 0.0) {
                    windowShares(e, nowMs, rules).forEach { (window, share) -> add(window, engagement * share, e, m) }
                }
                add(TasteWindow.Explicit, RecommendationScoring.explicitStrength(e), e, m)
                if (engagement > 0.0 || RecommendationScoring.explicitStrength(e) > 0.0) {
                    m.keywords.take(12).forEach { keywordTitles[it] = (keywordTitles[it] ?: 0) + 1 }
                    m.creators.forEach { creatorTitles[it.id] = (creatorTitles[it.id] ?: 0) + 1 }
                }
            }

            // Effective window weights: scaled down for windows with few titles, then renormalized (redistribution).
            val raw = TasteWindow.entries.associateWith { w ->
                val a = acc.getValue(w)
                if (a.mass <= 0.0) 0.0 else (rules.weights[w] ?: 0.0) * min(1.0, a.titles.size.toDouble() / rules.fullConfidenceTitles)
            }
            val total = raw.values.sum()
            if (total <= 0.0) return EMPTY
            val weights = raw.mapValues { it.value / total }

            fun <K> blend(select: (Acc) -> Map<K, Double>): Map<K, Double> {
                val out = HashMap<K, Double>()
                for (w in TasteWindow.entries) {
                    val a = acc.getValue(w)
                    val ww = weights.getValue(w)
                    if (ww <= 0.0 || a.mass <= 0.0) continue
                    select(a).forEach { (k, v) -> out[k] = (out[k] ?: 0.0) + ww * v / a.mass }
                }
                return out
            }

            val totalTitles = history.size
            // A keyword or person seen in only one title is noise, unless the history is tiny.
            val minRepeat = if (totalTitles < 5) 1 else 2
            return TasteProfile(
                genres = blend { it.genres }.scaledToMax(),
                keywords = blend { it.keywords }.filterKeys { (keywordTitles[it] ?: 0) >= minRepeat }.scaledToMax(),
                creators = blend { it.creators }.filterKeys { (creatorTitles[it] ?: 0) >= minRepeat }.scaledToMax(),
                languages = blend { it.languages }.scaledToMax(),
                seriesShare = TasteWindow.entries.sumOf { w ->
                    val a = acc.getValue(w)
                    if (a.mass <= 0.0) 0.0 else weights.getValue(w) * a.series / a.mass
                },
                franchises = blend { it.franchises },
                windows = TasteWindow.entries.associateWith { w ->
                    val a = acc.getValue(w)
                    WindowTaste(
                        titles = a.titles.size,
                        genres = if (a.mass <= 0.0) emptyMap() else a.genres.mapValues { it.value / a.mass },
                        seriesShare = if (a.mass <= 0.0) 0.0 else a.series / a.mass,
                    )
                },
                effectiveWeights = weights,
            )
        }

        private fun <K> Map<K, Double>.scaledToMax(): Map<K, Double> {
            val top = values.maxOrNull() ?: return emptyMap()
            return if (top <= 0.0) emptyMap() else mapValues { it.value / top }
        }
    }
}

// ---------------------------------------------------------------------------------------------------- Actors

data class ActorAffinity(
    val person: Person,
    val score: Double,
    /** Distinct titles the actor had a billed role in. */
    val titles: List<String>,
    val genreCount: Int,
    /** The franchises (or standalone titles) the actor was seen in; their own titles aren't recommended again. */
    val groups: Set<String> = emptySet(),
)

object ActorAffinities {
    /** Billing positions that count as a real role; deeper billing is mostly supporting or one-scene parts. */
    const val MAX_BILLING = 6

    /**
     * Actors the profile keeps coming back to. Each title counts once (a long series doesn't make its whole cast
     * favourites), only meaningfully watched titles count, and leads count more than supporting roles.
     *
     * Titles in the same franchise count together as one, plus a little for each extra film, and an actor seen across
     * several franchises or standalone titles ranks well above one seen in a single franchise: watching six MCU films
     * says more about the MCU than about any one Avenger. An actor needs at least [minTitles] distinct titles. Range
     * across genres adds a little.
     */
    fun compute(
        history: List<Pair<ViewingEvidence, TitleMeta>>,
        nowMs: Long,
        minTitles: Int = 2,
        franchiseOf: (TitleMeta) -> String? = { null },
    ): List<ActorAffinity> {
        class Acc(val person: Person) {
            val titles = LinkedHashSet<String>()
            val genres = HashSet<Int>()
            val byGroup = HashMap<String, MutableList<Double>>()
            val score: Double get() = byGroup.values.sumOf { scores ->
                val sorted = scores.sortedDescending()
                sorted.first() + 0.25 * sorted.drop(1).sum()
            }
        }
        val acc = HashMap<Int, Acc>()
        for ((e, m) in history) {
            val engagement = RecommendationScoring.engagement(e, nowMs)
            if (engagement < 0.3) continue
            val w = min(1.0, engagement)
            m.cast.filter { it.order < MAX_BILLING }.distinctBy { it.id }.forEach { p ->
                val billing = when { p.order <= 1 -> 1.0; p.order <= 3 -> 0.8; else -> 0.6 }
                val a = acc.getOrPut(p.id) { Acc(p) }
                if (a.titles.add(m.name)) {
                    a.byGroup.getOrPut(franchiseOf(m) ?: m.key) { mutableListOf() } += w * billing
                    a.genres += m.genres
                }
            }
        }
        return acc.values.filter { it.titles.size >= minTitles }
            .map { a ->
                val range = 1 + 0.1 * (min(a.genres.size, 4) - 1).coerceAtLeast(0)
                val spread = 1 + 0.35 * (min(a.byGroup.size, 4) - 1)
                ActorAffinity(a.person, a.score * range * spread, a.titles.toList(), a.genres.size, a.byGroup.keys.toSet())
            }
            .sortedByDescending { it.score }
    }
}

// ---------------------------------------------------------------------------------------------------- Seeds

data class Seed(val evidence: ViewingEvidence, val meta: TitleMeta, val window: TasteWindow, val weight: Double)

object SeedSelection {
    /** Seeds drawn from each window, so recommendations come from the whole history and not the latest few titles. */
    private val PER_WINDOW = mapOf(TasteWindow.LongTerm to 7, TasteWindow.MediumTerm to 5, TasteWindow.Recent to 3, TasteWindow.Explicit to 3)

    /**
     * Picks seed titles window by window, each window's seeds sharing that window's weight, at most two per franchise
     * and preferring a spread of genres. A title belongs to the window that holds most of its activity.
     */
    fun select(
        history: List<Pair<ViewingEvidence, TitleMeta>>,
        taste: TasteProfile,
        nowMs: Long,
        rules: TasteRules = TasteRules(),
        franchiseOf: (TitleMeta) -> String? = { null },
    ): List<Seed> {
        val byWindow = HashMap<TasteWindow, MutableList<Pair<ViewingEvidence, TitleMeta>>>()
        for ((e, m) in history) {
            val engagement = RecommendationScoring.engagement(e, nowMs)
            val window = if (engagement >= 0.3) {
                TasteProfile.windowShares(e, nowMs, rules).maxByOrNull { it.value }?.key ?: continue
            } else if (RecommendationScoring.explicitStrength(e) >= 0.5 && !e.started) {
                TasteWindow.Explicit
            } else continue
            byWindow.getOrPut(window) { mutableListOf() } += e to m
        }
        val seeds = ArrayList<Seed>()
        val perFranchise = HashMap<String, Int>()
        for ((window, limit) in PER_WINDOW) {
            val pool = byWindow[window].orEmpty().sortedByDescending { (e, _) ->
                if (window == TasteWindow.Explicit) RecommendationScoring.explicitStrength(e) else RecommendationScoring.engagement(e, nowMs)
            }
            val picked = ArrayList<Pair<ViewingEvidence, TitleMeta>>()
            val usedGenres = HashSet<Int>()
            for (candidate in pool) {
                if (picked.size >= limit) break
                val franchise = franchiseOf(candidate.second)
                if (franchise != null && (perFranchise[franchise] ?: 0) >= 2) continue
                // Prefer seeds that bring a new main genre; fall back to the rest once those run out.
                val main = candidate.second.genres.firstOrNull()
                if (main != null && main in usedGenres && pool.size - pool.indexOf(candidate) > limit - picked.size) continue
                picked += candidate
                main?.let { usedGenres += it }
                franchise?.let { perFranchise[it] = (perFranchise[it] ?: 0) + 1 }
            }
            val share = taste.effectiveWeights[window] ?: 0.0
            picked.forEach { (e, m) -> seeds += Seed(e, m, window, if (picked.isEmpty()) 0.0 else share / picked.size) }
        }
        return seeds.filter { it.weight > 0.0 }
    }
}

// ---------------------------------------------------------------------------------------------------- Candidates

enum class CandidateSource { Recommended, Similar, Genre, Actor, Creator, Acclaimed }

/** A seed that pointed at a candidate, and how high up its list. */
data class SeedHit(val seedKey: String, val seedName: String, val seedWeight: Double, val rank: Int, val similarOnly: Boolean)

data class Candidate(
    val meta: TitleMeta,
    val sources: Set<CandidateSource>,
    val hits: List<SeedHit> = emptyList(),
)

data class ScoredCandidate(
    val candidate: Candidate,
    val relevance: Double,
    val parts: Map<String, Double>,
    val reason: String?,
) {
    val meta: TitleMeta get() = candidate.meta
}

object CandidateScoring {
    /**
     * Seed agreement with diminishing returns: the strongest hit counts fully, the next half, the next a quarter, and
     * so on. Several seeds from one franchise pointing at the same sequel no longer add up to a huge score.
     */
    fun collaborative(c: Candidate): Double =
        c.hits.map { it.seedWeight * (if (it.similarOnly) 0.6 else 1.0) / (1 + 0.1 * it.rank) }
            .sortedDescending()
            .mapIndexed { i, v -> v * 0.5.pow(i) }
            .sum()

    fun quality(m: TitleMeta): Double {
        val confidence = min(1.0, ln(m.voteCount + 1.0) / ln(3000.0))
        return (((m.voteAverage - 6.0) / 2.5).coerceIn(-0.5, 1.0)) * confidence
    }

    fun score(c: Candidate, taste: TasteProfile, actors: Map<Int, Double>, collabMax: Double): ScoredCandidate {
        val m = c.meta
        val collab = if (collabMax > 0) collaborative(c) / collabMax else 0.0
        val genre = taste.genreMatch(m.genres)
        val keyword = taste.keywordMatch(m.keywords)
        val cast = m.cast.take(5).maxOfOrNull { actors[it.id] ?: 0.0 } ?: 0.0
        val creator = taste.creatorMatch(m.creators)
        val language = m.language?.let { taste.languages[it] } ?: 0.0
        val quality = quality(m)
        val media = if (m.tv) taste.seriesShare else 1 - taste.seriesShare
        val parts = mapOf(
            "collab" to collab, "genre" to genre, "keyword" to keyword, "cast" to cast,
            "creator" to creator, "language" to language, "quality" to quality, "media" to media,
        )
        val relevance = 0.30 * collab + 0.26 * genre + 0.10 * keyword + 0.08 * cast + 0.06 * creator +
            0.05 * language + 0.10 * quality + 0.05 * media
        val reason = c.hits.maxByOrNull { it.seedWeight / (1 + 0.1 * it.rank) }?.seedName
        return ScoredCandidate(c, relevance, parts, reason)
    }
}

// ---------------------------------------------------------------------------------------------------- Diversity

object Diversity {
    fun jaccard(a: Collection<Int>, b: Collection<Int>): Double {
        if (a.isEmpty() || b.isEmpty()) return 0.0
        val sa = a.toSet(); val sb = b.toSet()
        return sa.intersect(sb).size.toDouble() / sa.union(sb).size
    }

    /** How alike two titles are for a viewer: genres, franchise, lead actors and themes. */
    fun similarity(a: TitleMeta, b: TitleMeta, franchiseOf: (TitleMeta) -> String?): Double {
        val fa = franchiseOf(a)
        val sameFranchise = fa != null && fa == franchiseOf(b)
        val sharedLead = a.cast.take(3).map { it.id }.intersect(b.cast.take(3).map { it.id }.toSet()).isNotEmpty()
        return 0.45 * jaccard(a.genres, b.genres) + (if (sameFranchise) 0.3 else 0.0) +
            (if (sharedLead) 0.15 else 0.0) + 0.10 * jaccard(a.keywords, b.keywords)
    }

    /**
     * Maximal Marginal Relevance: repeatedly takes the item with the best balance of relevance and difference from
     * what is already picked. [penalty] adds soft constraints (franchise share, format mix) on top.
     */
    fun <T> mmr(
        items: List<T>,
        size: Int,
        relevance: (T) -> Double,
        similarity: (T, T) -> Double,
        lambda: Double = 0.72,
        penalty: (T, List<T>) -> Double = { _, _ -> 0.0 },
    ): List<T> {
        val pool = items.toMutableList()
        val picked = ArrayList<T>()
        while (picked.size < size && pool.isNotEmpty()) {
            val best = pool.maxByOrNull { c ->
                val redundancy = picked.maxOfOrNull { similarity(c, it) } ?: 0.0
                lambda * relevance(c) - (1 - lambda) * redundancy - penalty(c, picked)
            } ?: break
            pool.remove(best)
            picked += best
        }
        return picked
    }

    /**
     * The penalty that keeps one franchise to roughly [maxShare] of a row of [size]. It is soft: an item from a
     * franchise at its cap is pushed down, not removed, so a profile that really is mostly one franchise still sees it.
     */
    fun franchisePenalty(size: Int, maxShare: Double, franchiseOf: (TitleMeta) -> String?): (TitleMeta, List<TitleMeta>) -> Double {
        val cap = max(1, ceil(size * maxShare).toInt())
        return { c, picked ->
            val f = franchiseOf(c)
            if (f == null) 0.0 else {
                val n = picked.count { franchiseOf(it) == f }
                if (n >= cap) 0.4 + 0.1 * (n - cap) else 0.0
            }
        }
    }

    /** Keeps films and series near the profile's own mix when it watches both. */
    fun formatPenalty(seriesShare: Double): (TitleMeta, List<TitleMeta>) -> Double {
        if (seriesShare < 0.1 || seriesShare > 0.9) return { _, _ -> 0.0 }
        val target = seriesShare.coerceIn(0.2, 0.8)
        return { c, picked ->
            if (picked.size < 3) 0.0 else {
                val series = picked.count { it.tv } + if (c.tv) 1 else 0
                val share = series.toDouble() / (picked.size + 1)
                if (kotlin.math.abs(share - target) > 0.2) 0.12 else 0.0
            }
        }
    }
}
