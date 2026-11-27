package com.nuvio.app.features.playback

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class SegmentArbiterTest {
    private fun m(min: Int, sec: Int = 0) = (min * 60L + sec) * 1000L
    private val duration = m(45) // an episode

    private fun seg(
        type: PlaybackSegmentType, from: Long, to: Long?, source: SegmentSource,
        quality: SegmentMatchQuality = SegmentMatchQuality.DURATION_AGNOSTIC, confidence: Double? = null,
        submissions: Int? = null,
    ) = SegmentCandidate(PlaybackSegment(type, from, to, source, confidence, null, quality, submissions), "${source.name}:${type.name}:$from")

    private fun run(vararg c: SegmentCandidate<String>, dur: Long? = duration) = SegmentArbiter.arbitrate(c.toList(), dur)

    @Test fun anIntroFromOneProviderDoesNotHideCreditsFromAnother() {
        val out = run(
            seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB),
            seg(PlaybackSegmentType.CREDITS, m(42), m(45), SegmentSource.SKIPDB, SegmentMatchQuality.DURATION_MATCHED),
        )
        assertEquals(setOf(PlaybackSegmentType.INTRO, PlaybackSegmentType.CREDITS), out.map { it.candidate.segment.type }.toSet())
    }

    @Test fun chaptersInsideTheFileBeatAnExternalGuessForTheSameStretch() {
        val out = run(
            seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB, confidence = 0.9),
            seg(PlaybackSegmentType.INTRO, m(1, 2), m(2, 1), SegmentSource.CHAPTERS, SegmentMatchQuality.EXACT_EDITION),
        )
        assertEquals(1, out.size)
        assertEquals(SegmentSource.CHAPTERS, out.single().candidate.segment.source)
    }

    @Test fun aUserCorrectionBeatsEverything() {
        val out = run(
            seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.CHAPTERS, SegmentMatchQuality.EXACT_EDITION),
            seg(PlaybackSegmentType.INTRO, m(1, 3), m(2, 5), SegmentSource.USER_CORRECTION, SegmentMatchQuality.EXACT_EDITION),
        )
        assertEquals(SegmentSource.USER_CORRECTION, out.single().candidate.segment.source)
    }

    @Test fun editionMatchedDataBeatsDurationAgnosticData() {
        val out = run(
            seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB, confidence = 0.95),
            seg(PlaybackSegmentType.INTRO, m(1, 1), m(2, 1), SegmentSource.SKIPDB, SegmentMatchQuality.DURATION_MATCHED, 0.8),
        )
        assertEquals(SegmentSource.SKIPDB, out.single().candidate.segment.source)
        assertEquals(2, out.single().agreeingSources)
    }

    @Test fun agreementBetweenProvidersIsRecordedAndLowConfidenceLoses() {
        val out = run(
            seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB, confidence = 0.9),
            seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.ANIME_SKIP, confidence = 0.2),
        )
        assertEquals(SegmentSource.INTRODB, out.single().candidate.segment.source)
        assertEquals(2, out.single().agreeingSources)
    }

    @Test fun approximateAndLowConfidenceDataStaysManualOnly() {
        val approx = run(seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.SKIPDB, SegmentMatchQuality.DURATION_APPROXIMATE, 0.9)).single()
        assertFalse(approx.usableForAutomatic)
        val low = run(seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB, confidence = 0.1)).single()
        assertFalse(low.usableForAutomatic)
        val good = run(seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB, confidence = 0.9)).single()
        assertTrue(good.usableForAutomatic)
    }

    @Test fun separateStretchesOfOneTypeAreAllKept() {
        val out = run(
            seg(PlaybackSegmentType.RECAP, m(0), m(1), SegmentSource.INTRODB),
            seg(PlaybackSegmentType.RECAP, m(20), m(21), SegmentSource.ANIME_SKIP),
        )
        assertEquals(2, out.size)
    }

    @Test fun invalidSegmentsAreDropped() {
        val out = run(
            seg(PlaybackSegmentType.CREDITS, m(1), m(2), SegmentSource.INTRODB), // credits in minute one: implausible
            seg(PlaybackSegmentType.INTRO, m(3), m(2), SegmentSource.INTRODB),   // ends before it starts
            seg(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB),
        )
        assertEquals(1, out.size)
    }

    @Test fun aDifferentEditionsDataIsRejected() {
        val ext = SegmentCandidate(PlaybackSegment(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.SKIPDB, editionIdentity = "extended"), "x")
        assertTrue(SegmentArbiter.arbitrate(listOf(ext), duration, editionIdentity = "theatrical").isEmpty())
        assertEquals(1, SegmentArbiter.arbitrate(listOf(ext), duration, editionIdentity = "extended").size)
    }

    @Test fun creditsThatCoverAProtectedSceneAreCutAroundIt() {
        val film = m(130)
        val cands = listOf(
            SegmentCandidate(PlaybackSegment(PlaybackSegmentType.CREDITS, m(121), m(130), SegmentSource.CHAPTERS, matchQuality = SegmentMatchQuality.EXACT_EDITION), "credits"),
            SegmentCandidate(PlaybackSegment(PlaybackSegmentType.POST_CREDITS_SCENE, m(129), m(129, 45), SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC), "scene"),
        )
        val out = SegmentArbiter.arbitrate(cands, film, retime = { payload, seg -> "$payload@${seg.startMs}-${seg.endMs}" })
        val credits = out.filter { it.candidate.segment.type == PlaybackSegmentType.CREDITS }.map { it.candidate.segment.startMs to it.candidate.segment.endMs }
        assertEquals(listOf(m(121) to m(129), m(129, 45) to m(130)), credits)
        assertTrue(out.any { it.candidate.segment.type == PlaybackSegmentType.POST_CREDITS_SCENE })
        assertTrue(out.first { it.candidate.segment.type == PlaybackSegmentType.CREDITS }.candidate.payload.contains("@"))
    }
}

class SegmentArbiterLimitTest {
    private fun m(min: Int) = min * 60_000L
    private fun cand(type: PlaybackSegmentType, from: Long, to: Long, source: SegmentSource, confidence: Double) =
        SegmentCandidate(PlaybackSegment(type, from, to, source, confidence, null, SegmentMatchQuality.DURATION_AGNOSTIC), source.name)

    @Test fun anEpisodeKeepsOneIntroEvenWhenProvidersDisagreeWidely() {
        val cands = listOf(
            cand(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB, 0.9),
            cand(PlaybackSegmentType.INTRO, m(10), m(11), SegmentSource.ANISKIP, 0.6),
        )
        val unlimited = SegmentArbiter.arbitrate(cands, m(45))
        assertEquals(2, unlimited.size)
        val limited = SegmentArbiter.arbitrate(cands, m(45), limitPerType = mapOf(PlaybackSegmentType.INTRO to 1))
        assertEquals(listOf("INTRODB"), limited.map { it.candidate.payload })
    }
}
