package com.nuvio.app.features.personalization

import com.nuvio.app.features.playback.PlaybackStateStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sqrt

// ---------------------------------------------------------------------------------------------------------------------
// 3.1 Ratings from several services
// ---------------------------------------------------------------------------------------------------------------------

/** A rating as a service holds it, on that service's own scale. The original value is never discarded. */
data class ExternalRating(
    val source: String,
    val mediaKey: String,
    val value: Double,
    val scaleMin: Double,
    val scaleMax: Double,
    val ratedAtMs: Long,
)

data class NormalizedRating(
    val mediaKey: String,
    /** 0 (worst) to 1 (best) on every source's scale. */
    val normalized: Double,
    val chosen: ExternalRating,
    /** Every source that rated the title, for provenance. */
    val sources: List<String>,
)

/**
 * One rating per title from however many services have one. The rule is deterministic: the most recently made rating wins;
 * on an exact tie the source listed first in [sourcePriority] wins. The same rating reported twice (same source and title) is
 * one. A service that fails to load simply contributes nothing; it never removes another's rating.
 */
object RatingConsolidator {
    fun normalize(rating: ExternalRating): Double {
        val span = rating.scaleMax - rating.scaleMin
        if (!rating.value.isFinite() || span <= 0.0) return Double.NaN
        return ((rating.value - rating.scaleMin) / span).coerceIn(0.0, 1.0)
    }

    fun consolidate(ratings: List<ExternalRating>, sourcePriority: List<String> = emptyList()): List<NormalizedRating> {
        val valid = ratings.filter { !normalize(it).isNaN() }
        return valid.groupBy { it.mediaKey }.map { (key, group) ->
            val distinct = group.distinctBy { it.source }.let { bySource ->
                // Several entries from one source: keep that source's newest.
                group.groupBy { it.source }.map { (_, own) -> own.maxBy { it.ratedAtMs } }.ifEmpty { bySource }
            }
            val best = distinct.sortedWith(
                compareByDescending<ExternalRating> { it.ratedAtMs }
                    .thenBy { sourcePriority.indexOf(it.source).let { i -> if (i < 0) Int.MAX_VALUE else i } }
                    .thenBy { it.source },
            ).first()
            NormalizedRating(key, normalize(best), best, distinct.map { it.source }.sorted())
        }.sortedBy { it.mediaKey }
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// 3.2 Local preference feedback
// ---------------------------------------------------------------------------------------------------------------------

enum class PreferenceReaction(val tasteWeight: Double) {
    /** A negative taste signal. Not a one-star rating anywhere. */
    NOT_FOR_ME(-1.0),
    LIKE(0.6),
    LOVE(1.0),
}

@Serializable
data class FeedbackEntry(
    val mediaKey: String,
    val reaction: PreferenceReaction? = null,
    /** Hide this from recommendation surfaces. Separate from taste, and never touches history or search. */
    val notInterested: Boolean = false,
    val updatedAtMs: Long = 0L,
)

/**
 * Lightweight feedback that works with no external account, kept per profile. A reaction feeds taste; Not Interested only
 * suppresses recommendations; neither changes watch history, and both can be changed or removed.
 */
class PreferenceFeedbackStore(private val store: PlaybackStateStore, private val storeName: String = "preference_feedback") {
    private val json = Json { ignoreUnknownKeys = true }
    private val listSerializer = kotlinx.serialization.builtins.ListSerializer(FeedbackEntry.serializer())

    private fun load(profileId: Int): Map<String, FeedbackEntry> =
        store.get(storeName, "p$profileId")?.let { runCatching { json.decodeFromString(listSerializer, it) }.getOrNull() }
            ?.associateBy { it.mediaKey }.orEmpty()

    private fun save(profileId: Int, entries: Map<String, FeedbackEntry>) =
        store.put(storeName, "p$profileId", json.encodeToString(listSerializer, entries.values.filter { it.reaction != null || it.notInterested }.sortedBy { it.mediaKey }))

    fun setReaction(profileId: Int, mediaKey: String, reaction: PreferenceReaction?, nowMs: Long) {
        val all = load(profileId).toMutableMap()
        all[mediaKey] = (all[mediaKey] ?: FeedbackEntry(mediaKey)).copy(reaction = reaction, updatedAtMs = nowMs)
        save(profileId, all)
    }

    fun setNotInterested(profileId: Int, mediaKey: String, value: Boolean, nowMs: Long) {
        val all = load(profileId).toMutableMap()
        all[mediaKey] = (all[mediaKey] ?: FeedbackEntry(mediaKey)).copy(notInterested = value, updatedAtMs = nowMs)
        save(profileId, all)
    }

    fun reactionFor(profileId: Int, mediaKey: String): PreferenceReaction? = load(profileId)[mediaKey]?.reaction
    fun isSuppressed(profileId: Int, mediaKey: String): Boolean = load(profileId)[mediaKey]?.notInterested == true
    fun suppressedKeys(profileId: Int): Set<String> = load(profileId).values.filter { it.notInterested }.map { it.mediaKey }.toSet()

    /** Taste evidence from reactions: (title, weight). Titles marked Not Interested only are not counted as taste. */
    fun tasteSignals(profileId: Int): List<Pair<String, Double>> =
        load(profileId).values.mapNotNull { e -> e.reaction?.let { e.mediaKey to it.tasteWeight } }

    /** Forget everything for the profile (the reset action). Watch history is stored elsewhere and untouched. */
    fun reset(profileId: Int) = store.put(storeName, "p$profileId", "[]")
}

// ---------------------------------------------------------------------------------------------------------------------
// 3.3 When recommendations need rebuilding
// ---------------------------------------------------------------------------------------------------------------------

enum class RefreshDecision { REFRESH, SKIP_UNCHANGED, WAIT_DEBOUNCE }

object RecommendationRefreshPolicy {
    /**
     * A stable fingerprint of what the recommendations are built from. It changes when a value changes, not only when the
     * number of entries does, and does not depend on the order entries are listed in.
     */
    fun fingerprint(
        profileId: Int,
        ratings: Map<String, Double>,
        watchedKeys: Set<String>,
        watchlistKeys: Set<String>,
        feedback: Map<String, String>,
    ): Long {
        var h = fnv("profile$profileId")
        fun mix(tag: String, entries: List<String>) { h = h xor fnv(tag + entries.sorted().joinToString("|")); h *= PRIME }
        mix("r", ratings.map { "${it.key}=${it.value}" })
        mix("w", watchedKeys.toList())
        mix("l", watchlistKeys.toList())
        mix("f", feedback.map { "${it.key}=${it.value}" })
        return h
    }

    /** Rebuild only for a real change, at most once per [minIntervalMs], or when the cached result is too old. */
    fun decide(
        previous: Long?,
        current: Long,
        lastRefreshMs: Long?,
        nowMs: Long,
        minIntervalMs: Long = 60_000L,
        cacheMaxAgeMs: Long = 6 * 60 * 60_000L,
    ): RefreshDecision {
        val expired = lastRefreshMs == null || nowMs - lastRefreshMs >= cacheMaxAgeMs
        if (previous == current && !expired) return RefreshDecision.SKIP_UNCHANGED
        if (lastRefreshMs != null && !expired && nowMs - lastRefreshMs < minIntervalMs) return RefreshDecision.WAIT_DEBOUNCE
        return RefreshDecision.REFRESH
    }

    private const val PRIME = 1099511628211L
    private fun fnv(s: String): Long { var h = -3750763034362895579L; for (c in s) { h = h xor c.code.toLong(); h *= PRIME }; return h }
}

// ---------------------------------------------------------------------------------------------------------------------
// 3.4 Endless rows keep their meaning
// ---------------------------------------------------------------------------------------------------------------------

object EndlessRowPolicy {
    /**
     * The next page of a row. Extra titles pass the very same eligibility test as the first page, never repeat one already
     * shown, never include an excluded (watched, hidden, Not Interested) title, and an empty page means the row is over.
     */
    fun <T> nextPage(
        candidates: List<T>,
        key: (T) -> String,
        shown: Set<String>,
        excluded: Set<String>,
        eligible: (T) -> Boolean,
        pageSize: Int,
    ): List<T> {
        val seen = HashSet<String>()
        return candidates.filter { c ->
            val k = key(c)
            k !in shown && k !in excluded && eligible(c) && seen.add(k)
        }.take(pageSize)
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// 3.5 Hero selection
// ---------------------------------------------------------------------------------------------------------------------

data class HeroCandidate(
    val key: String,
    val genres: List<String>,
    val franchiseKey: String? = null,
    /** 0 to 1, from the recommendation scoring; 0 for a cold-start profile. */
    val relevance: Double = 0.0,
    val daysSinceRelease: Int? = null,
    val hasSuitableArtwork: Boolean = true,
)

object HeroSelector {
    /**
     * A diversified, stable set. Same profile and day give the same answer, so Home does not rearrange itself while it is
     * being browsed. No genre or franchise can fill the carousel, titles shown recently rank lower, and a cold-start profile
     * (no relevance at all) still gets a varied set.
     */
    fun select(
        candidates: List<HeroCandidate>,
        size: Int = 6,
        dayEpoch: Long,
        profileId: Int,
        recentlyShown: Set<String> = emptySet(),
        maxPerGenre: Int = 2,
        maxPerFranchise: Int = 1,
    ): List<HeroCandidate> {
        fun score(c: HeroCandidate): Double {
            val recency = c.daysSinceRelease?.let { (30 - it).coerceIn(0, 30) / 30.0 * 0.2 } ?: 0.0
            val repeat = if (c.key in recentlyShown) 0.3 else 0.0
            val jitter = (mix("$dayEpoch|$profileId|${c.key}") % 1000) / 1000.0 * 0.05 // deterministic tie-breaker
            return c.relevance * 0.6 + recency - repeat + jitter
        }
        val ranked = candidates.filter { it.hasSuitableArtwork }.distinctBy { it.key }.sortedByDescending { score(it) }
        val picked = ArrayList<HeroCandidate>()
        val genreCount = HashMap<String, Int>(); val franchiseCount = HashMap<String, Int>()
        for (c in ranked) {
            if (picked.size >= size) break
            val genre = c.genres.firstOrNull()
            if (genre != null && (genreCount[genre] ?: 0) >= maxPerGenre) continue
            val franchise = c.franchiseKey
            if (franchise != null && (franchiseCount[franchise] ?: 0) >= maxPerFranchise) continue
            picked += c
            genre?.let { genreCount[it] = (genreCount[it] ?: 0) + 1 }
            franchise?.let { franchiseCount[it] = (franchiseCount[it] ?: 0) + 1 }
        }
        return picked
    }

    private fun mix(s: String): Long { var h = 1469598103934665603L; for (c in s) { h = h xor c.code.toLong(); h *= 1099511628211L }; return h and Long.MAX_VALUE }
}

// ---------------------------------------------------------------------------------------------------------------------
// 3.6 / 3.7 Match presentation and explanations
// ---------------------------------------------------------------------------------------------------------------------

enum class MatchLabel { NONE, RECOMMENDED_FOR_YOU, STRONG_MATCH }

object MatchPresentation {
    private const val MIN_EVIDENCE_FOR_PERCENT = 30
    private const val MIN_DISTRIBUTION_FOR_PERCENT = 20
    private const val MIN_SPREAD = 0.05

    /** Where [score] sits among the candidates being compared, 0 (lowest) to 1 (highest). */
    fun percentile(score: Double, distribution: List<Double>): Double =
        if (distribution.isEmpty()) 0.0 else distribution.count { it <= score }.toDouble() / distribution.size

    /** A qualitative label that needs no calibration: only the standing among candidates. Too little evidence: no label. */
    fun label(score: Double, distribution: List<Double>, evidenceCount: Int): MatchLabel {
        if (evidenceCount < 5 || distribution.size < 5) return MatchLabel.NONE
        val p = percentile(score, distribution)
        return when {
            p >= 0.90 -> MatchLabel.STRONG_MATCH
            p >= 0.60 -> MatchLabel.RECOMMENDED_FOR_YOU
            else -> MatchLabel.NONE
        }
    }

    /**
     * A percentage only when the profile has enough history and the scores actually spread out. It is a relative standing,
     * not a probability: it is spread over 50 to 98 so only the very best candidates reach the nineties.
     */
    fun percent(score: Double, distribution: List<Double>, evidenceCount: Int): Int? {
        if (evidenceCount < MIN_EVIDENCE_FOR_PERCENT || distribution.size < MIN_DISTRIBUTION_FOR_PERCENT) return null
        val mean = distribution.average()
        val sd = sqrt(distribution.sumOf { (it - mean) * (it - mean) } / distribution.size)
        if (sd < MIN_SPREAD) return null
        val p = percentile(score, distribution)
        return (50 + 48 * p * p).roundToInt()
    }
}

enum class ReasonKind { BECAUSE_YOU_WATCHED, FAVOURITE_DIRECTOR, FAVOURITE_ACTOR, CONTINUE_FRANCHISE, SIMILAR_GENRE, SAVED_TO_YOUR_LIST }

/** One piece of scoring evidence for a candidate, as the recommendation engine recorded it. */
data class ReasonEvidence(val kind: ReasonKind, val subject: String, val weight: Double)

object RecommendationExplainer {
    /** The reason with the most weight behind it, or null: an explanation is only ever drawn from real evidence. */
    fun explain(evidence: List<ReasonEvidence>): ReasonEvidence? =
        evidence.filter { it.weight > 0.0 && it.subject.isNotBlank() }.maxWithOrNull(compareBy({ it.weight }, { -it.kind.ordinal }))
}

// ---------------------------------------------------------------------------------------------------------------------
// 3.8 Adaptive Home ordering
// ---------------------------------------------------------------------------------------------------------------------

data class HomeRowEntry(
    val id: String,
    /** Anchors keep their fixed place: hero, Continue Watching, Top 10, Recommended For You, Explore. */
    val anchorOrder: Int? = null,
    val relevance: Double = 0.0,
    val available: Boolean = true,
    /** The place the viewer gave it, when they customised the order. */
    val manualIndex: Int? = null,
)

object AdaptiveHomeOrder {
    /**
     * Anchors first in their fixed order. Below them, the viewer's own order when they customised one (or adaptive ordering
     * is off); otherwise rows by relevance. Rows with nothing to show are left out.
     */
    fun order(rows: List<HomeRowEntry>, adaptiveEnabled: Boolean, userCustomizedOrder: Boolean): List<HomeRowEntry> {
        val shown = rows.filter { it.available }
        val anchors = shown.filter { it.anchorOrder != null }.sortedBy { it.anchorOrder }
        val rest = shown.filter { it.anchorOrder == null }
        val ordered = if (userCustomizedOrder || !adaptiveEnabled) {
            rest.sortedWith(compareBy({ it.manualIndex ?: Int.MAX_VALUE }))
        } else {
            rest.sortedByDescending { it.relevance }
        }
        return anchors + ordered
    }

    /** While the viewer is scrolling the order does not change; the new order waits until they stop. */
    fun <T> keepWhileScrolling(current: List<T>, proposed: List<T>, isScrolling: Boolean): List<T> = if (isScrolling) current else proposed
}

// ---------------------------------------------------------------------------------------------------------------------
// 3.9 Artwork
// ---------------------------------------------------------------------------------------------------------------------

enum class ArtworkKind { POSTER, BACKDROP, LOGO }

data class ArtworkOption(
    val url: String,
    val kind: ArtworkKind,
    val language: String?,
    val width: Int,
    val height: Int,
    val voteAverage: Double = 0.0,
    val voteCount: Int = 0,
)

object ArtworkSelector {
    /**
     * Picks one image by plain, checkable facts: the right shape for the kind, the viewer's language, resolution, and how the
     * community rated it. No claim is made about what an image shows. The choice is a pure function of the inputs plus
     * [stableSeed] (profile + title + surface), so it never changes between visits. A viewer's own override always wins.
     */
    fun select(
        options: List<ArtworkOption>,
        kind: ArtworkKind,
        preferredLanguage: String?,
        stableSeed: String,
        userOverrideUrl: String? = null,
    ): String? {
        userOverrideUrl?.takeIf { it.isNotBlank() }?.let { return it }
        val fitting = options.filter { it.kind == kind && shapeFits(it) && it.width > 0 && it.height > 0 }
        fun score(o: ArtworkOption): Double {
            val language = when {
                o.language != null && o.language.equals(preferredLanguage, ignoreCase = true) -> 3.0
                o.language == null || o.language.isBlank() -> if (kind == ArtworkKind.LOGO) 0.5 else 1.5 // textless art is neutral
                else -> 0.0
            }
            val resolution = minOf(o.width, 2000) / 2000.0
            val votes = if (o.voteCount > 0) o.voteAverage / 10.0 * ln(o.voteCount + 1.0) / ln(100.0) else 0.0
            return language + resolution + votes.coerceAtMost(1.0)
        }
        return fitting.sortedWith(compareByDescending<ArtworkOption> { score(it) }.thenBy { tieBreak(stableSeed, it.url) }).firstOrNull()?.url
    }

    private fun shapeFits(o: ArtworkOption): Boolean {
        if (o.height == 0) return false
        val ratio = o.width.toDouble() / o.height
        return when (o.kind) {
            ArtworkKind.POSTER -> ratio in 0.60..0.72
            ArtworkKind.BACKDROP -> ratio in 1.65..1.90
            ArtworkKind.LOGO -> true
        }
    }

    private fun tieBreak(seed: String, url: String): Long { var h = 1469598103934665603L; for (c in "$seed|$url") { h = h xor c.code.toLong(); h *= 1099511628211L }; return h and Long.MAX_VALUE }
}
