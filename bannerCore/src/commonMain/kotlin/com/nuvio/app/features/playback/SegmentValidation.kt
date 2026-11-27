package com.nuvio.app.features.playback

import kotlin.math.abs
import kotlin.math.max

/** Why a segment cannot be used against the video that is playing. */
enum class SegmentIssue {
    NEGATIVE_START,
    END_NOT_AFTER_START,
    STARTS_AFTER_VIDEO_END,
    EXTENDS_PAST_VIDEO_END,

    /** The type and where it sits in the runtime do not fit (end credits in the first minute, an intro near the end). */
    IMPLAUSIBLE_LOCATION,

    /** The timestamps were made on a video of a different length than this one. */
    DURATION_INCOMPATIBLE,

    /** The provider's release identifier differs from the one playing. */
    EDITION_MISMATCH,

    /** The video is a short error or placeholder clip, not the title. Nothing about it can be trusted. */
    PLACEHOLDER_VIDEO,
}

/** A segment together with the verdict on it for the current video. */
data class SegmentAssessment(
    val segment: PlaybackSegment,
    val issue: SegmentIssue?,
    val reliability: SegmentReliability,
) {
    val isValid: Boolean get() = issue == null

    /** Fit for a Skip button the viewer chooses to press. Loose or low-confidence data is allowed here, clearly labelled. */
    val allowsManualSkip: Boolean get() = isValid

    /**
     * Fit for something that happens without the viewer asking: auto-skip, and a Post-Play takeover that relies on where
     * the credits are. Needs a valid, trusted segment that is not an approximate match.
     */
    val allowsAutomaticAction: Boolean
        get() = isValid && reliability == SegmentReliability.VERIFIED &&
            segment.matchQuality != SegmentMatchQuality.DURATION_APPROXIMATE
}

object PlaybackSegmentValidator {
    /** Streams shorter than this are error clips or cache placeholders (matches the app's placeholder guard). */
    const val MIN_REAL_CONTENT_DURATION_MS = 121_000L

    private const val END_TOLERANCE_MS = 2_000L
    private const val MIN_DURATION_TOLERANCE_MS = 30_000L
    private const val DURATION_TOLERANCE_DIVISOR = 50L // 2%

    // Where in the runtime a type can sensibly start. Deliberately wide: these catch mislabels (credits at 0:30), not taste.
    private const val INTRO_STARTS_BEFORE = 0.60
    private const val RECAP_STARTS_BEFORE = 0.45
    private const val CREDITS_START_AFTER = 0.40
    private const val SCENE_STARTS_AFTER = 0.50
    private const val PREVIEW_STARTS_AFTER = 0.70

    /**
     * Checks [segment] against the playing video. [observedDurationMs] null or not positive means the duration is not known
     * yet, so only the checks that do not need it run. Never throws.
     */
    fun validate(
        segment: PlaybackSegment,
        observedDurationMs: Long?,
        observedEditionIdentity: String? = null,
    ): SegmentIssue? {
        if (segment.startMs < 0L) return SegmentIssue.NEGATIVE_START
        val end = segment.endMs
        if (end != null && end <= segment.startMs) return SegmentIssue.END_NOT_AFTER_START

        val duration = observedDurationMs?.takeIf { it > 0L }
        if (duration != null) {
            if (duration < MIN_REAL_CONTENT_DURATION_MS) return SegmentIssue.PLACEHOLDER_VIDEO
            if (segment.startMs >= duration) return SegmentIssue.STARTS_AFTER_VIDEO_END
            if (end != null && end > duration + END_TOLERANCE_MS) return SegmentIssue.EXTENDS_PAST_VIDEO_END
            if (!locationIsPlausible(segment.type, segment.startMs, duration)) return SegmentIssue.IMPLAUSIBLE_LOCATION
            val reference = segment.referenceDurationMs
            if (reference != null && reference > 0L && comparesDuration(segment.matchQuality) &&
                abs(reference - duration) > durationTolerance(duration)
            ) {
                return SegmentIssue.DURATION_INCOMPATIBLE
            }
        }

        val known = segment.editionIdentity?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        val playing = observedEditionIdentity?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        if (known != null && playing != null && known != playing) return SegmentIssue.EDITION_MISMATCH
        return null
    }

    fun assess(
        segments: List<PlaybackSegment>,
        observedDurationMs: Long?,
        observedEditionIdentity: String? = null,
    ): List<SegmentAssessment> = segments.map {
        SegmentAssessment(it, validate(it, observedDurationMs, observedEditionIdentity), it.reliability())
    }

    /** The two-percent (at least thirty seconds) window inside which two durations count as the same video. */
    fun durationTolerance(durationMs: Long): Long = max(MIN_DURATION_TOLERANCE_MS, durationMs / DURATION_TOLERANCE_DIVISOR)

    private fun comparesDuration(quality: SegmentMatchQuality): Boolean = when (quality) {
        // The provider never looked at the duration, or said outright that the match is loose: nothing to compare against.
        SegmentMatchQuality.DURATION_AGNOSTIC, SegmentMatchQuality.DURATION_APPROXIMATE -> false
        else -> true
    }

    private fun locationIsPlausible(type: PlaybackSegmentType, startMs: Long, durationMs: Long): Boolean {
        val at = startMs.toDouble() / durationMs.toDouble()
        return when (type) {
            PlaybackSegmentType.INTRO -> at <= INTRO_STARTS_BEFORE
            PlaybackSegmentType.RECAP -> at <= RECAP_STARTS_BEFORE
            PlaybackSegmentType.CREDITS -> at >= CREDITS_START_AFTER
            PlaybackSegmentType.MID_CREDITS_SCENE, PlaybackSegmentType.POST_CREDITS_SCENE -> at >= SCENE_STARTS_AFTER
            PlaybackSegmentType.NEXT_EPISODE_PREVIEW -> at >= PREVIEW_STARTS_AFTER
            PlaybackSegmentType.UNKNOWN -> true
        }
    }
}
