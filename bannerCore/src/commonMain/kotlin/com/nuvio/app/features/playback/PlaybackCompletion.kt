package com.nuvio.app.features.playback

import com.nuvio.app.features.letterboxd.WatchedCoverage

/**
 * Turns the player's position samples into viewing coverage: stretches of the runtime that actually played, merged so a
 * stretch watched twice counts once. A seek is a jump, not watching, so dragging the timeline to 99% adds nothing. Coverage
 * can be carried between sessions (pass it back in), and a deliberately skipped, validated segment can be credited with
 * [creditSkipped] so skipping a real opening never stops a title from completing.
 *
 * This is the same steady-playback rule `LetterboxdPlaybackTracker` uses, in a form every consumer can share.
 */
class PlaybackCoverageAccumulator(initial: WatchedCoverage = WatchedCoverage()) {
    var coverage: WatchedCoverage = initial
        private set

    private var lastPositionMs = -1L
    private var lastWallMs = -1L
    private var lastPlaying = false

    /** One look at the player. [wallMs] is the clock in epoch milliseconds; it is what tells playing from jumping. */
    fun onSample(positionMs: Long, isPlaying: Boolean, wallMs: Long): WatchedCoverage {
        if (lastPlaying && isPlaying && lastPositionMs >= 0 && lastWallMs >= 0) {
            val wallDelta = wallMs - lastWallMs
            val posDelta = positionMs - lastPositionMs
            if (wallDelta in 1..MAX_SAMPLE_GAP_MS && posDelta in 1..((wallDelta * MAX_SPEED).toLong() + SLACK_MS)) {
                coverage = coverage.add(lastPositionMs, positionMs)
            }
        }
        lastPositionMs = positionMs
        lastWallMs = wallMs
        lastPlaying = isPlaying
        return coverage
    }

    /** The viewer skipped this validated segment on purpose: count it as seen. */
    fun creditSkipped(startMs: Long, endMs: Long) {
        coverage = coverage.add(startMs, endMs)
    }

    /** The player went away (stopped, backgrounded, switched stream or engine): the next sample starts fresh. */
    fun onInterrupted() {
        lastPlaying = false
        lastPositionMs = -1
        lastWallMs = -1
    }

    /** A new viewing of the same title starts from nothing. */
    fun reset() {
        coverage = WatchedCoverage()
        onInterrupted()
    }

    private companion object {
        const val MAX_SAMPLE_GAP_MS = 5_000L
        const val MAX_SPEED = 2.5
        const val SLACK_MS = 600L
    }
}

enum class PlaybackCompletionReason {
    /** The player reported the end after most of the title had really been watched. */
    PLAYER_REPORTED_END,

    /** The narrative (everything before the credits) was watched and the credits have begun. */
    NARRATIVE_COMPLETE,

    /** No credits are known; the conservative end-of-runtime fallback was reached with enough watched. */
    FALLBACK_THRESHOLD,

    /** The viewer marked it watched. Set by the caller; the policy never decides this. */
    USER_MARKED,
}

/** BannerTV's defaults, not any service's internal numbers. Tuned by tests and real playback. */
data class PlaybackCompletionConfig(
    /** With no credits known: how far into the runtime counts as the end. */
    val unknownCreditsFraction: Double = 0.97,

    /** With credits known: how much of the narrative (before the credits) must have played. */
    val narrativeCoverage: Double = 0.85,

    /** With no credits known: how much of the whole runtime must have played at the end-of-runtime mark. */
    val fallbackCoverage: Double = 0.80,

    /** When the player reports the end: how much of the whole runtime must have played (a film resumed late still counts). */
    val endedMinCoverage: Double = 0.60,
)

data class PlaybackCompletionAssessment(
    val completes: Boolean,
    val reason: PlaybackCompletionReason?,

    /** Where the narrative ends (the credits start), or null when no valid credits are known. */
    val narrativeEndMs: Long?,

    /** The share of the narrative that played, 0 to 1 (0 when there is no known narrative end). */
    val narrativeCoverageFraction: Double,

    /** Verified protected scenes the viewer has not really watched. Completion is not held back by them. */
    val unwatchedProtectedScenes: List<PlaybackSegment>,

    /**
     * Set when the title completes before an unwatched protected scene: where that scene starts, so a "watch the bonus
     * scene" resume stays possible without un-completing the title.
     */
    val resumeTargetMs: Long?,
)

/**
 * The one decision on when a title counts as watched, shared by every platform and consumer. It reads position, duration,
 * real viewing coverage and the validated segments; engines and providers feed it, they do not each decide.
 */
object PlaybackCompletionPolicy {
    fun assess(
        positionMs: Long,
        durationMs: Long,
        isEnded: Boolean,
        coverage: WatchedCoverage,
        validatedSegments: List<PlaybackSegment>,
        config: PlaybackCompletionConfig = PlaybackCompletionConfig(),
    ): PlaybackCompletionAssessment {
        if (durationMs < PlaybackSegmentValidator.MIN_REAL_CONTENT_DURATION_MS) return notComplete(emptyList())

        val unwatched = validatedSegments.filter { it.type.isProtectedScene && !coverage.mostlyCovers(it, durationMs) }
        val creditsStart = PlaybackSegments.creditsStartMs(validatedSegments, durationMs)
        val wholeFraction = coverage.fraction(durationMs)
        val narrativeFraction = if (creditsStart != null && creditsStart > 0L) {
            (coverage.coveredIn(0L, creditsStart).toDouble() / creditsStart.toDouble()).coerceIn(0.0, 1.0)
        } else {
            0.0
        }

        val reason: PlaybackCompletionReason? = when {
            isEnded && wholeFraction >= config.endedMinCoverage -> PlaybackCompletionReason.PLAYER_REPORTED_END
            creditsStart != null && positionMs >= creditsStart && narrativeFraction >= config.narrativeCoverage ->
                PlaybackCompletionReason.NARRATIVE_COMPLETE
            creditsStart == null &&
                positionMs.toDouble() >= durationMs.toDouble() * config.unknownCreditsFraction &&
                wholeFraction >= config.fallbackCoverage -> PlaybackCompletionReason.FALLBACK_THRESHOLD
            else -> null
        }

        val resumeTarget = if (reason != null) {
            unwatched.filter { it.startMs > positionMs }.minOfOrNull { it.startMs }
        } else {
            null
        }
        return PlaybackCompletionAssessment(
            completes = reason != null,
            reason = reason,
            narrativeEndMs = creditsStart,
            narrativeCoverageFraction = narrativeFraction,
            unwatchedProtectedScenes = unwatched,
            resumeTargetMs = resumeTarget,
        )
    }

    private fun notComplete(unwatched: List<PlaybackSegment>) = PlaybackCompletionAssessment(
        completes = false,
        reason = null,
        narrativeEndMs = null,
        narrativeCoverageFraction = 0.0,
        unwatchedProtectedScenes = unwatched,
        resumeTargetMs = null,
    )
}

/** How many milliseconds of [startMs, endMs) played. */
internal fun WatchedCoverage.coveredIn(startMs: Long, endMs: Long): Long {
    if (endMs <= startMs) return 0L
    var total = 0L
    for (span in ranges) {
        val from = maxOf(span.start, startMs)
        val to = minOf(span.end, endMs)
        if (to > from) total += to - from
    }
    return total
}

/** A scene counts as watched once at least half of it has played. */
internal fun WatchedCoverage.mostlyCovers(segment: PlaybackSegment, durationMs: Long): Boolean {
    val end = segment.resolvedEndMs(durationMs)
    val length = end - segment.startMs
    if (length <= 0L) return true
    return coveredIn(segment.startMs, end).toDouble() >= length * 0.5
}
