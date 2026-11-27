package com.nuvio.app.features.playback

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SegmentValidationTest {
    private val duration = 130 * 60_000L // a 130-minute film

    private fun seg(
        type: PlaybackSegmentType = PlaybackSegmentType.CREDITS,
        start: Long = 121 * 60_000L,
        end: Long? = duration,
        source: SegmentSource = SegmentSource.INTRODB,
        quality: SegmentMatchQuality = SegmentMatchQuality.DURATION_AGNOSTIC,
        reference: Long? = null,
        edition: String? = null,
        confidence: Double? = null,
        submissions: Int? = null,
    ) = PlaybackSegment(type, start, end, source, confidence, reference, quality, submissions, null, edition)

    @Test fun aSaneSegmentIsValid() = assertNull(PlaybackSegmentValidator.validate(seg(), duration))

    @Test fun nonFiniteSecondsNeverBecomeASegment() {
        assertNull(PlaybackSegment.fromSeconds(PlaybackSegmentType.INTRO, Double.NaN, 90.0, SegmentSource.INTRODB))
        assertNull(PlaybackSegment.fromSeconds(PlaybackSegmentType.INTRO, 10.0, Double.NaN, SegmentSource.INTRODB))
        assertNull(PlaybackSegment.fromSeconds(PlaybackSegmentType.INTRO, 10.0, Double.NEGATIVE_INFINITY, SegmentSource.INTRODB))
        assertNull(PlaybackSegment.fromSeconds(PlaybackSegmentType.INTRO, -1.0, 90.0, SegmentSource.INTRODB))
    }

    @Test fun theMaxValueSentinelBecomesAnOpenEnd() {
        val open = assertNotNull(PlaybackSegment.fromSeconds(PlaybackSegmentType.CREDITS, 2500.0, Double.MAX_VALUE, SegmentSource.ANIME_SKIP))
        assertNull(open.endMs)
        assertEquals(2_820_000L, open.resolvedEndMs(2_820_000L))
    }

    @Test fun endBeforeOrAtStartIsRejected() {
        assertEquals(SegmentIssue.END_NOT_AFTER_START, PlaybackSegmentValidator.validate(seg(start = 100, end = 100), duration))
        assertEquals(SegmentIssue.END_NOT_AFTER_START, PlaybackSegmentValidator.validate(seg(start = 200, end = 100), duration))
    }

    @Test fun segmentsOutsideTheVideoAreRejected() {
        assertEquals(SegmentIssue.STARTS_AFTER_VIDEO_END, PlaybackSegmentValidator.validate(seg(start = duration + 1, end = duration + 90_000), duration))
        assertEquals(SegmentIssue.EXTENDS_PAST_VIDEO_END, PlaybackSegmentValidator.validate(seg(end = duration + 60_000), duration))
        // A couple of seconds past the end is rounding, not an error.
        assertNull(PlaybackSegmentValidator.validate(seg(end = duration + 1_500), duration))
    }

    @Test fun mislabelledLocationIsImplausible() {
        assertEquals(SegmentIssue.IMPLAUSIBLE_LOCATION, PlaybackSegmentValidator.validate(seg(start = 30_000, end = 150_000), duration)) // "credits" at 0:30
        assertEquals(SegmentIssue.IMPLAUSIBLE_LOCATION, PlaybackSegmentValidator.validate(seg(PlaybackSegmentType.INTRO, 125 * 60_000L, duration), duration))
        assertEquals(SegmentIssue.IMPLAUSIBLE_LOCATION, PlaybackSegmentValidator.validate(seg(PlaybackSegmentType.POST_CREDITS_SCENE, 10 * 60_000L, 11 * 60_000L), duration))
    }

    @Test fun anExtendedCutIsNotTheTheatricalCut() {
        val theatrical = seg(quality = SegmentMatchQuality.DURATION_MATCHED, reference = 130 * 60_000L)
        assertNull(PlaybackSegmentValidator.validate(theatrical, 130 * 60_000L + 20_000))
        assertEquals(SegmentIssue.DURATION_INCOMPATIBLE, PlaybackSegmentValidator.validate(theatrical, 143 * 60_000L)) // extended cut
    }

    @Test fun durationAgnosticAndApproximateDataSkipTheDurationComparison() {
        val agnostic = seg(quality = SegmentMatchQuality.DURATION_AGNOSTIC, reference = 90 * 60_000L)
        assertNull(PlaybackSegmentValidator.validate(agnostic, duration))
    }

    @Test fun differentEditionIdentitiesDoNotMatch_butMissingOnesDo() {
        assertEquals(SegmentIssue.EDITION_MISMATCH, PlaybackSegmentValidator.validate(seg(edition = "theatrical-2021"), duration, "extended-2021"))
        assertNull(PlaybackSegmentValidator.validate(seg(edition = "Theatrical-2021"), duration, "theatrical-2021"))
        assertNull(PlaybackSegmentValidator.validate(seg(edition = null), duration, "extended-2021"))
    }

    @Test fun errorClipsAndPlaceholdersInvalidateEverything() {
        assertEquals(SegmentIssue.PLACEHOLDER_VIDEO, PlaybackSegmentValidator.validate(seg(), 45_000L))
    }

    @Test fun unknownDurationRunsOnlyTheBasicChecks() {
        assertNull(PlaybackSegmentValidator.validate(seg(), null))
        assertNull(PlaybackSegmentValidator.validate(seg(), 0L))
        assertEquals(SegmentIssue.NEGATIVE_START, PlaybackSegmentValidator.validate(seg(start = -5), null))
    }

    @Test fun lowConfidenceAndApproximateDataAllowManualButNotAutomaticSkips() {
        val low = PlaybackSegmentValidator.assess(listOf(seg(confidence = 0.2)), duration).single()
        assertTrue(low.allowsManualSkip); assertFalse(low.allowsAutomaticAction)
        assertEquals(SegmentReliability.LOW_CONFIDENCE, low.reliability)

        val approximate = PlaybackSegmentValidator.assess(
            listOf(seg(source = SegmentSource.SKIPDB, quality = SegmentMatchQuality.DURATION_APPROXIMATE, confidence = 0.9)), duration,
        ).single()
        assertTrue(approximate.allowsManualSkip); assertFalse(approximate.allowsAutomaticAction)

        val verified = PlaybackSegmentValidator.assess(listOf(seg(confidence = 0.9, submissions = 4)), duration).single()
        assertTrue(verified.allowsAutomaticAction)
        val noSubmissions = PlaybackSegmentValidator.assess(listOf(seg(submissions = 0)), duration).single()
        assertFalse(noSubmissions.allowsAutomaticAction)
    }

    @Test fun userCorrectionsAndChaptersAreTrusted() {
        assertEquals(SegmentReliability.VERIFIED, seg(source = SegmentSource.USER_CORRECTION, confidence = 0.1).reliability())
        assertEquals(SegmentReliability.VERIFIED, seg(source = SegmentSource.CHAPTERS).reliability())
        assertEquals(SegmentReliability.LOW_CONFIDENCE, seg(source = SegmentSource.HEURISTIC).reliability())
    }

    @Test fun lookupOutcomesStayDistinct() {
        val outcomes: List<SegmentLookupOutcome> = listOf(
            SegmentLookupOutcome.Segments(emptyList()),
            SegmentLookupOutcome.ConfirmedAbsent(setOf(PlaybackSegmentType.INTRO)),
            SegmentLookupOutcome.NoData,
            SegmentLookupOutcome.ProviderError("HTTP 503"),
            SegmentLookupOutcome.Invalid("end before start"),
        )
        assertEquals(5, outcomes.map { it::class }.toSet().size)
    }
}
