package com.nuvio.app.features.playback

/**
 * What a stretch of a title is, independent of which provider (or chapter title) described it and of what that provider
 * calls it. Every decision about skipping, credits timing and completion reads this, never a raw provider string.
 */
enum class PlaybackSegmentType {
    INTRO,
    RECAP,

    /** The end credits (an episode's outro/ED, a movie's end credits). Opening credits are [INTRO], never this. */
    CREDITS,
    MID_CREDITS_SCENE,
    POST_CREDITS_SCENE,
    NEXT_EPISODE_PREVIEW,
    UNKNOWN,
    ;

    /** A scene the viewer may want to see, which automatic actions must never skip through. */
    val isProtectedScene: Boolean get() = this == MID_CREDITS_SCENE || this == POST_CREDITS_SCENE

    /** Something a Skip button can offer to jump over. */
    val isSkippable: Boolean get() = this == INTRO || this == RECAP || this == CREDITS || this == NEXT_EPISODE_PREVIEW

    companion object {
        /**
         * Maps what a provider or chapter calls a segment. Matching is on the whole label (case, spaces and underscores
         * ignored), never on a word inside it: "credits" alone is the end credits, "opening credits" is the intro, and
         * anything not listed is [UNKNOWN] rather than a guess.
         */
        fun fromRaw(raw: String?): PlaybackSegmentType {
            val key = raw?.trim()?.lowercase()?.replace('_', '-')?.replace(' ', '-')?.takeIf { it.isNotEmpty() }
                ?: return UNKNOWN
            return ALIASES[key] ?: UNKNOWN
        }

        private val ALIASES: Map<String, PlaybackSegmentType> = mapOf(
            "intro" to INTRO, "new-intro" to INTRO, "op" to INTRO, "opening" to INTRO, "mixed-op" to INTRO,
            "mixed-intro" to INTRO, "opening-credits" to INTRO, "opening-theme" to INTRO, "title-sequence" to INTRO,
            "recap" to RECAP, "previously" to RECAP,
            "outro" to CREDITS, "ed" to CREDITS, "mixed-ed" to CREDITS, "mixed-credits" to CREDITS, "new-credits" to CREDITS,
            "credits" to CREDITS, "movie-credits" to CREDITS, "end-credits" to CREDITS, "ending-credits" to CREDITS,
            "closing-credits" to CREDITS, "ending" to CREDITS, "ending-theme" to CREDITS,
            "mid-credits" to MID_CREDITS_SCENE, "midcredits" to MID_CREDITS_SCENE, "mid-credits-scene" to MID_CREDITS_SCENE,
            "post-credits" to POST_CREDITS_SCENE, "postcredits" to POST_CREDITS_SCENE, "post-credits-scene" to POST_CREDITS_SCENE,
            "after-credits" to POST_CREDITS_SCENE, "end-credits-scene" to POST_CREDITS_SCENE,
            "preview" to NEXT_EPISODE_PREVIEW, "next-episode-preview" to NEXT_EPISODE_PREVIEW, "next-time-on" to NEXT_EPISODE_PREVIEW,
        )
    }
}

/** Where a segment came from, in the order trust is normally ranked when providers disagree (see [SegmentArbiter]). */
enum class SegmentSource {
    USER_CORRECTION,
    CHAPTERS,
    INTRODB,
    SKIPDB,
    THEINTRODB,
    ANIME_SKIP,
    ANISKIP,
    HEURISTIC,
    OTHER,
    ;

    companion object {
        fun fromProvider(provider: String?): SegmentSource = when (provider?.trim()?.lowercase()) {
            "user", "user-correction" -> USER_CORRECTION
            "chapters", "chapter" -> CHAPTERS
            "introdb" -> INTRODB
            "skipdb" -> SKIPDB
            "theintrodb" -> THEINTRODB
            "animeskip", "anime-skip" -> ANIME_SKIP
            "aniskip" -> ANISKIP
            "heuristic" -> HEURISTIC
            else -> OTHER
        }
    }
}

/** How well a provider's timestamps are known to fit the video being played. A shared IMDb id alone proves nothing. */
enum class SegmentMatchQuality {
    /** The provider identified this exact edition/release (or the user corrected it for this file). */
    EXACT_EDITION,

    /** The provider matched the video's duration to the one the timestamps were made on. */
    DURATION_MATCHED,

    /** The provider shifted the timestamps to fit a slightly different duration (conservative adjustment). */
    DURATION_ADJUSTED,

    /** The provider says the match is loose (for example a season-level estimate). Manual use only. */
    DURATION_APPROXIMATE,

    /** The provider keys data by episode or title and never looked at the duration (IntroDB). */
    DURATION_AGNOSTIC,
    UNKNOWN,
}

/** Whether a marker was made for a movie, an episode or an anime episode. Kept so "credits" never loses where it came from. */
enum class SegmentMediaContext { MOVIE, EPISODE, ANIME_EPISODE, UNKNOWN }

/**
 * One marked stretch of a title. All times are milliseconds. A title can have several segments of the same type (two
 * credits sections around a mid-credits scene, more than one recap).
 */
data class PlaybackSegment(
    val type: PlaybackSegmentType,
    val startMs: Long,
    /** Null when the segment is known to start but not where it ends (Anime-Skip's last timestamp). */
    val endMs: Long?,
    val source: SegmentSource,
    val confidence: Double? = null,
    /** The duration of the video the timestamps were made on, when the provider says. */
    val referenceDurationMs: Long? = null,
    val matchQuality: SegmentMatchQuality = SegmentMatchQuality.UNKNOWN,
    val submissionCount: Int? = null,
    val verifiedAtMs: Long? = null,
    /** A provider's own identifier of the release the timestamps belong to. Never a stream URL or anything secret. */
    val editionIdentity: String? = null,
    val mediaContext: SegmentMediaContext = SegmentMediaContext.UNKNOWN,
) {
    /** The end, with an open-ended segment running to [durationMs]. */
    fun resolvedEndMs(durationMs: Long): Long = endMs ?: durationMs

    fun contains(positionMs: Long, durationMs: Long): Boolean = positionMs >= startMs && positionMs < resolvedEndMs(durationMs)

    companion object {
        /** Anime-Skip and others mark "to the end" with a huge double; anything this large means open-ended. */
        private const val OPEN_ENDED_SECONDS = 1.0e15

        /**
         * Builds a segment from provider seconds. Returns null for numbers that cannot be times (NaN, infinite, negative
         * start). An end at or beyond [OPEN_ENDED_SECONDS] (the `Double.MAX_VALUE` sentinel) becomes an open end.
         */
        fun fromSeconds(
            type: PlaybackSegmentType,
            startSeconds: Double,
            endSeconds: Double?,
            source: SegmentSource,
            confidence: Double? = null,
            referenceDurationMs: Long? = null,
            matchQuality: SegmentMatchQuality = SegmentMatchQuality.UNKNOWN,
            submissionCount: Int? = null,
            verifiedAtMs: Long? = null,
            editionIdentity: String? = null,
            mediaContext: SegmentMediaContext = SegmentMediaContext.UNKNOWN,
        ): PlaybackSegment? {
            if (!startSeconds.isFinite() || startSeconds < 0.0) return null
            val endMs: Long? = when {
                endSeconds == null -> null
                endSeconds.isNaN() -> return null
                endSeconds >= OPEN_ENDED_SECONDS -> null
                !endSeconds.isFinite() -> return null
                else -> (endSeconds * 1000.0).toLong()
            }
            return PlaybackSegment(
                type = type,
                startMs = (startSeconds * 1000.0).toLong(),
                endMs = endMs,
                source = source,
                confidence = confidence,
                referenceDurationMs = referenceDurationMs,
                matchQuality = matchQuality,
                submissionCount = submissionCount,
                verifiedAtMs = verifiedAtMs,
                editionIdentity = editionIdentity,
                mediaContext = mediaContext,
            )
        }
    }
}

/**
 * What a segment lookup answered. The cases are kept apart on purpose: "the provider confirms there is none" must not look
 * like "we have no data", and neither may look like a failed request.
 */
sealed interface SegmentLookupOutcome {
    data class Segments(val segments: List<PlaybackSegment>) : SegmentLookupOutcome

    /** The provider answered and says this title has no segment of these types. Safe to remember for a while. */
    data class ConfirmedAbsent(val types: Set<PlaybackSegmentType>) : SegmentLookupOutcome

    /** The provider knows nothing about this title. Worth asking again later. */
    data object NoData : SegmentLookupOutcome

    /** The request failed (network, rate limit, server error). Never cached as an answer. */
    data class ProviderError(val reason: String, val retryable: Boolean = true) : SegmentLookupOutcome

    /** The provider answered with something unusable (impossible timestamps, wrong schema). */
    data class Invalid(val reason: String) : SegmentLookupOutcome
}

enum class SegmentReliability { VERIFIED, LOW_CONFIDENCE }

/** Trust in a segment's data itself, before checking it against the video that is playing. */
fun PlaybackSegment.reliability(): SegmentReliability = when {
    source == SegmentSource.USER_CORRECTION || source == SegmentSource.CHAPTERS -> SegmentReliability.VERIFIED
    source == SegmentSource.HEURISTIC -> SegmentReliability.LOW_CONFIDENCE
    matchQuality == SegmentMatchQuality.DURATION_APPROXIMATE -> SegmentReliability.LOW_CONFIDENCE
    confidence != null && confidence < LOW_CONFIDENCE_BELOW -> SegmentReliability.LOW_CONFIDENCE
    submissionCount != null && submissionCount < 1 -> SegmentReliability.LOW_CONFIDENCE
    else -> SegmentReliability.VERIFIED
}

private const val LOW_CONFIDENCE_BELOW = 0.5
