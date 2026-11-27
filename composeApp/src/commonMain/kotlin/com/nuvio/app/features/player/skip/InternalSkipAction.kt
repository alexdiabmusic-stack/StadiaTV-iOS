package com.nuvio.app.features.player.skip

import com.nuvio.app.features.playback.PlaybackSegmentType
import com.nuvio.app.features.watching.domain.isShortPlaceholderDuration

internal data class InternalSkipAction(
    val targetMs: Long,
    val skipsToPostCredits: Boolean,
)

internal fun SkipInterval.internalSkipAction(
    intervals: List<SkipInterval>,
    durationMs: Long = 0L,
): InternalSkipAction? {
    if (isShortPlaceholderDuration(durationMs)) return null
    // A mid- or post-credits scene is something to watch, never something a button skips.
    if (isProtectedScene()) return null
    val isMovieCredits = this.isMovieCredits
    // Episode providers may use Double.MAX_VALUE as an open-ended segment sentinel.
    if (isMovieCredits && !hasValidSeekTimes()) return null
    // Repository intervals (including post-credits) remain intact for external players.
    val canHavePostCredits = isCredits()
    val scene = if (canHavePostCredits) {
        intervals.filter {
            it.segmentType == PlaybackSegmentType.POST_CREDITS_SCENE && it.hasValidSeekTimes() &&
                it.startTime >= endTime &&
                (durationMs <= 0L || it.startTime < durationMs / 1000.0)
        }.minByOrNull { it.startTime }
    } else null
    val hasPostCreditsTail = canHavePostCredits && hasValidSeekTimes() && durationMs > 0L &&
        durationMs - (endTime * 1000.0).toLong() > POST_CREDITS_GAP_MS
    return InternalSkipAction(
        targetMs = ((scene?.startTime ?: endTime) * 1000.0).toLong(),
        skipsToPostCredits = scene != null || hasPostCreditsTail,
    )
}

private const val POST_CREDITS_GAP_MS = 5_000L

private fun SkipInterval.hasValidSeekTimes(): Boolean =
    startTime.isFinite() && endTime.isFinite() && startTime >= 0 && endTime > startTime &&
        endTime * 1000.0 < Long.MAX_VALUE.toDouble()
