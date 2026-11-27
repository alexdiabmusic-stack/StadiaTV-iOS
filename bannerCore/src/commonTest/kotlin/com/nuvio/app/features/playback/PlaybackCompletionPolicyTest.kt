package com.nuvio.app.features.playback

import com.nuvio.app.features.letterboxd.WatchedCoverage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlaybackCompletionPolicyTest {
    private fun m(minutes: Int, seconds: Int = 0) = (minutes * 60L + seconds) * 1000L
    private val duration = m(130)

    private fun cov(vararg spans: Pair<Long, Long>) = spans.fold(WatchedCoverage()) { acc, (a, b) -> acc.add(a, b) }
    private fun credits(from: Long = m(121), to: Long? = null) =
        PlaybackSegment(PlaybackSegmentType.CREDITS, from, to, SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)
    private fun scene(type: PlaybackSegmentType, from: Long, to: Long) =
        PlaybackSegment(type, from, to, SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)

    private fun assess(position: Long, coverage: WatchedCoverage, segments: List<PlaybackSegment> = emptyList(), ended: Boolean = false, dur: Long = duration) =
        PlaybackCompletionPolicy.assess(position, dur, ended, coverage, segments)

    // --- known credits ---

    @Test fun watchingTheNarrativeAndReachingTheCreditsCompletes() {
        val a = assess(m(121, 5), cov(0L to m(121, 5)), listOf(credits()))
        assertTrue(a.completes)
        assertEquals(PlaybackCompletionReason.NARRATIVE_COMPLETE, a.reason)
        assertEquals(m(121), a.narrativeEndMs)
    }

    @Test fun completingDuringTheCreditsDoesNotNeedTheCreditsWatched() {
        assertTrue(assess(m(123), cov(0L to m(123)), listOf(credits())).completes)
    }

    @Test fun seekingStraightToTheEndOfAFilmIsNotWatchingIt() {
        // Dragged the timeline to 99%: five minutes really played, the player now sits at 128:50.
        val a = assess(m(128, 50), cov(0L to m(5)), listOf(credits()))
        assertFalse(a.completes)
        assertNull(a.reason)
    }

    @Test fun seekingToTheEndWithNoCreditsKnownIsNotCompleteEither() {
        assertFalse(assess(m(128, 50), cov(0L to m(5))).completes)
        // A bare 90% position (the old rule) no longer completes by itself.
        assertFalse(assess(m(117), cov(0L to m(10))).completes)
    }

    @Test fun anEndReportedAfterADragIsNotACompletion() {
        assertFalse(assess(duration, cov(0L to m(25)), ended = true).completes)
    }

    @Test fun aFilmWatchedAcrossTwoSessionsCompletes() {
        val evening1 = cov(0L to m(70))
        val evening2 = evening1.add(m(70), m(121, 10))
        assertTrue(assess(m(121, 10), evening2, listOf(credits())).completes)
        assertFalse(assess(m(70), evening1, listOf(credits())).completes)
    }

    @Test fun repeatedlyWatchingTheSameTenMinutesIsOnlyTenMinutes() {
        var c = WatchedCoverage()
        repeat(5) { c = c.add(0L, m(10)) }
        assertEquals(m(10), c.totalMs)
        assertFalse(assess(m(121), c, listOf(credits())).completes)
    }

    @Test fun aSkippedIntroCountsSoTheTitleStillCompletes() {
        val acc = PlaybackCoverageAccumulator(cov(m(2) to m(121, 5)))
        assertTrue(assess(m(121, 5), acc.coverage, listOf(credits())).narrativeCoverageFraction < 0.99)
        acc.creditSkipped(0L, m(2)) // the viewer pressed Skip Intro on a validated opening
        val a = assess(m(121, 5), acc.coverage, listOf(credits()))
        assertTrue(a.completes)
        assertTrue(a.narrativeCoverageFraction > 0.99)
    }

    @Test fun naturalEndWithEnoughWatchedCompletes_evenWithoutCreditsData() {
        val a = assess(duration, cov(0L to m(128)), ended = true)
        assertTrue(a.completes)
        assertEquals(PlaybackCompletionReason.PLAYER_REPORTED_END, a.reason)
    }

    @Test fun aFilmResumedLateStillCountsWhenEnoughOfItPlayed() {
        assertTrue(assess(duration, cov(0L to m(40), m(60) to m(130)), ended = true).completes)
    }

    // --- unknown credits fallback ---

    @Test fun noCreditsDataFallsBackToNinetySevenPercentWithCoverage() {
        assertTrue(assess(m(127), cov(0L to m(127))).completes)
        assertEquals(PlaybackCompletionReason.FALLBACK_THRESHOLD, assess(m(127), cov(0L to m(127))).reason)
        assertFalse(assess(m(120), cov(0L to m(120))).completes) // 92%: not yet
    }

    // --- protected scenes ---

    @Test fun exitingDuringTheMidCreditsSceneStillCompletes_andKeepsTheBonusResumable() {
        val segs = listOf(
            credits(m(121), m(124)),
            scene(PlaybackSegmentType.MID_CREDITS_SCENE, m(124), m(125, 30)),
            credits(m(125, 30), m(129)),
            scene(PlaybackSegmentType.POST_CREDITS_SCENE, m(129), m(129, 45)),
        )
        val coverage = cov(0L to m(121), m(124) to m(125)) // saw most of the mid scene, none of the post scene
        val a = assess(m(125), coverage, segs)
        assertTrue(a.completes)
        assertEquals(listOf(PlaybackSegmentType.POST_CREDITS_SCENE), a.unwatchedProtectedScenes.map { it.type })
        assertEquals(m(129), a.resumeTargetMs)
    }

    @Test fun whenEverySceneWasSeenThereIsNothingToResume() {
        val segs = listOf(credits(m(121), m(129)), scene(PlaybackSegmentType.POST_CREDITS_SCENE, m(129), m(129, 45)))
        val a = assess(duration, cov(0L to m(129, 45)), segs, ended = true)
        assertTrue(a.completes)
        assertTrue(a.unwatchedProtectedScenes.isEmpty())
        assertNull(a.resumeTargetMs)
    }

    // --- guards ---

    @Test fun shortErrorClipsNeverComplete() {
        val clip = 45_000L
        assertFalse(PlaybackCompletionPolicy.assess(clip, clip, true, cov(0L to clip), emptyList()).completes)
    }

    @Test fun aMislabelledCreditsMarkerDoesNotMakeAFilmCompleteEarly() {
        // "Credits" at 0:05 cannot be the end credits; the policy must ignore it and use the fallback.
        val bad = listOf(credits(5_000, 120_000))
        val a = assess(m(3), cov(0L to m(3)), bad)
        assertFalse(a.completes)
        assertNull(a.narrativeEndMs)
    }

    @Test fun aNewViewingStartsFromNothing() {
        val acc = PlaybackCoverageAccumulator(cov(0L to m(121)))
        assertTrue(assess(m(121), acc.coverage, listOf(credits())).completes)
        acc.reset()
        assertFalse(assess(m(121), acc.coverage, listOf(credits())).completes)
    }
}
