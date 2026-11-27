package com.nuvio.app.features.playback

import com.nuvio.app.features.player.skip.SkipInterval
import com.nuvio.app.features.player.skip.isTrustedForAutomaticAction
import com.nuvio.app.features.player.skip.toPlaybackSegment
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The behaviours the repository relies on from the shared pieces: providers merge by stretch, and trust gates automation. */
class SkipFlowSemanticsTest {
    private fun m(min: Int) = min * 60_000L

    @Test fun anIntroFromOneProviderDoesNotStopCreditsAndRecapFromAnotherFromBeingUsed_theOldEarlyReturnLostThem() {
        val introDb = listOf(SkipInterval(60.0, 120.0, "intro", "introdb", confidence = 0.9))
        val skipDb = listOf(
            SkipInterval(61.0, 119.0, "intro", "skipdb", confidence = 0.8, matchQuality = SegmentMatchQuality.DURATION_MATCHED),
            SkipInterval(2520.0, 2700.0, "outro", "skipdb", confidence = 0.8, matchQuality = SegmentMatchQuality.DURATION_MATCHED),
            SkipInterval(0.0, 30.0, "recap", "skipdb", confidence = 0.7, matchQuality = SegmentMatchQuality.DURATION_MATCHED),
        )
        val out = SegmentArbiter.arbitrate(
            (introDb + skipDb).mapNotNull { si -> si.toPlaybackSegment()?.let { SegmentCandidate(it, si) } },
            durationMs = m(45),
            limitPerType = mapOf(PlaybackSegmentType.INTRO to 1, PlaybackSegmentType.RECAP to 1, PlaybackSegmentType.CREDITS to 1),
        ).map { it.candidate.payload }
        assertEquals(setOf("intro", "recap", "outro"), out.map { it.type }.toSet())
        assertEquals(3, out.size) // one of each, not two intros
        // The duration-matched SkipDB intro outranks the duration-agnostic IntroDB one for the same stretch.
        assertEquals("skipdb", out.single { it.type == "intro" }.provider)
    }

    @Test fun mergedResultCoversAllThreeCategories() {
        val all = listOf(
            SkipInterval(60.0, 120.0, "intro", "introdb", confidence = 0.9),
            SkipInterval(2520.0, 2700.0, "outro", "skipdb", confidence = 0.8, matchQuality = SegmentMatchQuality.DURATION_MATCHED),
            SkipInterval(0.0, 30.0, "recap", "skipdb", confidence = 0.7, matchQuality = SegmentMatchQuality.DURATION_MATCHED),
        )
        val out = SegmentArbiter.arbitrate(all.mapNotNull { si -> si.toPlaybackSegment()?.let { SegmentCandidate(it, si) } }, m(45))
        assertEquals(setOf("intro", "outro", "recap"), out.map { it.candidate.payload.type }.toSet())
    }

    @Test fun onlyTrustedMarkersMayBeAutoSkipped() {
        assertTrue(SkipInterval(60.0, 120.0, "intro", "introdb", confidence = 0.9).isTrustedForAutomaticAction())
        assertTrue(SkipInterval(60.0, 120.0, "intro", "introdb").isTrustedForAutomaticAction()) // no confidence given: unchanged behaviour
        assertFalse(SkipInterval(60.0, 120.0, "intro", "introdb", confidence = 0.2).isTrustedForAutomaticAction())
        assertFalse(SkipInterval(2520.0, 2700.0, "outro", "skipdb", 0.9, SegmentMatchQuality.DURATION_APPROXIMATE).isTrustedForAutomaticAction())
        assertFalse(SkipInterval(Double.NaN, 120.0, "intro", "introdb").isTrustedForAutomaticAction())
    }
}
