package com.nuvio.app.features.letterboxd

import kotlinx.serialization.Serializable

/**
 * How much of a film has really been watched, as ranges of its runtime (milliseconds), merged so a stretch watched twice
 * counts once. Persisted between player sessions, so a film watched across two evenings is still one viewing.
 */
@Serializable
data class WatchedCoverage(val ranges: List<Span> = emptyList()) {
    @Serializable data class Span(val start: Long, val end: Long)

    fun add(start: Long, end: Long): WatchedCoverage {
        if (end <= start) return this
        val all = (ranges + Span(start, end)).sortedBy { it.start }
        val merged = ArrayList<Span>()
        for (r in all) {
            val last = merged.lastOrNull()
            if (last != null && r.start <= last.end + MERGE_GAP_MS) merged[merged.lastIndex] = Span(last.start, maxOf(last.end, r.end)) else merged += r
        }
        return WatchedCoverage(merged)
    }

    val totalMs: Long get() = ranges.sumOf { it.end - it.start }

    fun fraction(durationMs: Long): Double = if (durationMs <= 0) 0.0 else (totalMs.toDouble() / durationMs).coerceIn(0.0, 1.0)

    private companion object { const val MERGE_GAP_MS = 1_500L }
}

enum class LetterboxdCompletionReason { PlayerReportedEnd, ThresholdReached }

/** A film the member has finished. */
data class LetterboxdCompletion(
    val sessionId: String,
    val profileId: Int,
    val tmdbId: Int,
    val title: String,
    val completedAtMs: Long,
    val reason: LetterboxdCompletionReason,
    val watchedFraction: Double,
)

/**
 * Decides when a film counts as watched. Fed the player's position about once a second, it counts only playing time that
 * moves forward in step with the clock (allowing for playback speed): a seek is a jump, not watching, so skipping to 95% is
 * not watching 95%. A film is complete when the player reports its end after most of it was watched, or when the watched
 * share reaches the threshold. Stopping the player never completes a film. One completion per session.
 */
class LetterboxdPlaybackTracker(
    val sessionId: String,
    val profileId: Int,
    val tmdbId: Int,
    val title: String,
    initialCoverage: WatchedCoverage = WatchedCoverage(),
    private val threshold: Double = 0.95,
    /** Share that must have been watched when the player reports the end (a film resumed late still counts). */
    private val endedMinCoverage: Double = 0.6,
    /** Shortest runtime that counts as something to track. Films keep the default; a TV episode can be much shorter. */
    private val minRuntimeMs: Long = MIN_RUNTIME_MS,
) {
    var coverage: WatchedCoverage = initialCoverage; private set
    var completed: Boolean = false; private set

    private var lastPositionMs = -1L
    private var lastWallMs = -1L
    private var lastPlaying = false

    /**
     * One look at the player. Returns the completion the first time the film qualifies, else null. [wallMs] is the clock in epoch
     * milliseconds: it tells playing from jumping, and is the completion time the viewing's local date comes from.
     */
    fun onSample(positionMs: Long, durationMs: Long, isPlaying: Boolean, isEnded: Boolean, wallMs: Long): LetterboxdCompletion? {
        if (durationMs < minRuntimeMs) { reset(positionMs, wallMs, isPlaying); return null }
        if (lastPlaying && isPlaying && lastPositionMs >= 0 && lastWallMs >= 0) {
            val wallDelta = wallMs - lastWallMs
            val posDelta = positionMs - lastPositionMs
            // Steady playback moves the position forward about as fast as the clock (up to a fast speed).
            if (wallDelta in 1..MAX_SAMPLE_GAP_MS && posDelta in 1..((wallDelta * MAX_SPEED).toLong() + SLACK_MS)) {
                coverage = coverage.add(lastPositionMs, positionMs)
            }
        }
        reset(positionMs, wallMs, isPlaying)
        if (completed) return null
        val fraction = coverage.fraction(durationMs)
        val reason = when {
            isEnded && fraction >= endedMinCoverage -> LetterboxdCompletionReason.PlayerReportedEnd
            fraction >= threshold -> LetterboxdCompletionReason.ThresholdReached
            else -> null
        } ?: return null
        completed = true
        return LetterboxdCompletion(sessionId, profileId, tmdbId, title, wallMs, reason, fraction)
    }

    /** After a completion the next viewing of the same film starts from nothing. */
    fun resetCoverage() { coverage = WatchedCoverage(); completed = false }

    private fun reset(pos: Long, wall: Long, playing: Boolean) { lastPositionMs = pos; lastWallMs = wall; lastPlaying = playing }

    /** Called when the player goes away (stopped, backgrounded, switched stream): the next sample starts fresh. */
    fun onInterrupted() { lastPlaying = false; lastPositionMs = -1; lastWallMs = -1 }

    private companion object {
        const val MIN_RUNTIME_MS = 20 * 60_000L / 4 // five minutes: shorter media is not a film
        const val MAX_SAMPLE_GAP_MS = 5_000L
        const val MAX_SPEED = 2.5
        const val SLACK_MS = 600L
    }
}
