package com.nuvio.app.features.playback

/** A segment from one provider, carrying whatever the caller needs back (for the player: the original skip interval). */
data class SegmentCandidate<T>(val segment: PlaybackSegment, val payload: T)

data class ArbitratedSegment<T>(
    val candidate: SegmentCandidate<T>,
    /** Fit for auto-skip and for logic that acts without the viewer (see [SegmentAssessment.allowsAutomaticAction]). */
    val usableForAutomatic: Boolean,
    /** How many distinct providers marked (about) the same stretch. */
    val agreeingSources: Int,
)

/**
 * Chooses segments provider by provider-agnostic merit, per stretch of the runtime, instead of picking one provider for the
 * whole title. Order of trust, best first:
 *
 *  0. the viewer's own correction for this file
 *  1. chapters inside the file being played
 *  2. verified, edition/duration-matched external data
 *  3. verified data that two or more providers agree on
 *  4. verified data matched loosely (duration-agnostic, adjusted, unknown)
 *  5. low-confidence or approximate data (manual use only; never automatic)
 *
 * Several segments of one type are kept when they are different stretches (two credits sections, two recaps). Segments that
 * fail validation for the playing video are dropped. When the caller supplies [retime], a credits segment that covers a
 * protected scene is cut around it so credits skipping can never carry the viewer through a bonus scene.
 */
object SegmentArbiter {
    private const val SAME_STRETCH_START_TOLERANCE_MS = 5_000L
    private const val OPEN_END = Long.MAX_VALUE / 4

    fun <T> arbitrate(
        candidates: List<SegmentCandidate<T>>,
        durationMs: Long?,
        editionIdentity: String? = null,
        retime: ((T, PlaybackSegment) -> T)? = null,
        /**
         * How many stretches of a type to keep, best first. An episode has one intro and one outro, so two providers that
         * disagree must not show two Skip buttons; a movie's credits may legitimately come in sections, so it passes none.
         */
        limitPerType: Map<PlaybackSegmentType, Int> = emptyMap(),
    ): List<ArbitratedSegment<T>> {
        val valid = candidates.mapNotNull { c ->
            if (c.segment.type == PlaybackSegmentType.UNKNOWN) return@mapNotNull null
            val assessment = SegmentAssessment(
                c.segment,
                PlaybackSegmentValidator.validate(c.segment, durationMs, editionIdentity),
                c.segment.reliability(),
            )
            if (assessment.isValid) c to assessment else null
        }

        val winners = ArrayList<ArbitratedSegment<T>>()
        for ((type, ofType) in valid.groupBy { it.first.segment.type }) {
            val typeWinners = ArrayList<Pair<Int, ArbitratedSegment<T>>>()
            for (cluster in clusters(ofType)) {
                val agreeing = cluster.map { it.first.segment.source }.toSet().size
                val best = cluster.minWithOrNull(
                    compareBy<Pair<SegmentCandidate<T>, SegmentAssessment>>(
                        { rank(it.second, agreeing) },
                        { -(it.first.segment.confidence ?: 0.5) },
                        { -(it.first.segment.submissionCount ?: 0) },
                        { it.first.segment.source.ordinal },
                    ),
                ) ?: continue
                typeWinners += rank(best.second, agreeing) to ArbitratedSegment(best.first, best.second.allowsAutomaticAction, agreeing)
            }
            val limit = limitPerType[type]
            val kept = if (limit != null && typeWinners.size > limit) typeWinners.sortedBy { it.first }.take(limit) else typeWinners
            winners += kept.map { it.second }
        }
        val ordered = winners.sortedBy { it.candidate.segment.startMs }
        return if (retime != null && durationMs != null && durationMs > 0L) cutCreditsAroundScenes(ordered, durationMs, retime) else ordered
    }

    private fun rank(a: SegmentAssessment, agreeing: Int): Int {
        val s = a.segment
        return when {
            s.source == SegmentSource.USER_CORRECTION -> 0
            s.source == SegmentSource.CHAPTERS && a.reliability == SegmentReliability.VERIFIED -> 1
            a.reliability == SegmentReliability.LOW_CONFIDENCE -> 5
            s.matchQuality == SegmentMatchQuality.EXACT_EDITION || s.matchQuality == SegmentMatchQuality.DURATION_MATCHED -> 2
            agreeing >= 2 -> 3
            else -> 4
        }
    }

    /** Groups segments of one type that mark the same stretch: they overlap, or start within a few seconds of each other. */
    private fun <T> clusters(items: List<Pair<SegmentCandidate<T>, SegmentAssessment>>): List<List<Pair<SegmentCandidate<T>, SegmentAssessment>>> {
        val sorted = items.sortedBy { it.first.segment.startMs }
        val out = ArrayList<MutableList<Pair<SegmentCandidate<T>, SegmentAssessment>>>()
        var clusterEnd = Long.MIN_VALUE
        for (item in sorted) {
            val seg = item.first.segment
            val last = out.lastOrNull()
            val sameStretch = last != null &&
                (seg.startMs < clusterEnd || seg.startMs - last.maxOf { it.first.segment.startMs } <= SAME_STRETCH_START_TOLERANCE_MS)
            if (sameStretch) {
                last!!.add(item)
                clusterEnd = maxOf(clusterEnd, seg.endMs ?: OPEN_END)
            } else {
                out += mutableListOf(item)
                clusterEnd = seg.endMs ?: OPEN_END
            }
        }
        return out
    }

    private fun <T> cutCreditsAroundScenes(
        winners: List<ArbitratedSegment<T>>,
        durationMs: Long,
        retime: (T, PlaybackSegment) -> T,
    ): List<ArbitratedSegment<T>> {
        val scenes = winners.filter { it.candidate.segment.type.isProtectedScene }.map { it.candidate.segment }.sortedBy { it.startMs }
        if (scenes.isEmpty()) return winners
        val result = ArrayList<ArbitratedSegment<T>>()
        for (w in winners) {
            val seg = w.candidate.segment
            if (seg.type != PlaybackSegmentType.CREDITS) { result += w; continue }
            val pieces = PlaybackSegments.creditsAroundScenes(listOf(seg) + scenes, durationMs).filter { it.type == PlaybackSegmentType.CREDITS }
            for (piece in pieces) {
                result += w.copy(candidate = SegmentCandidate(piece, retime(w.candidate.payload, piece)))
            }
        }
        return result.sortedBy { it.candidate.segment.startMs }
    }
}
