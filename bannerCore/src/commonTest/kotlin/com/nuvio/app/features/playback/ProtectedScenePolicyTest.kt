package com.nuvio.app.features.playback

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The roadmap's 130-minute example: credits at 121:00, mid scene 124:00-125:30, credits resume, post scene 129:00-129:45. */
class ProtectedScenePolicyTest {
    private fun m(minutes: Int, seconds: Int = 0) = (minutes * 60L + seconds) * 1000L
    private val duration = m(130)

    private fun s(type: PlaybackSegmentType, from: Long, to: Long?) =
        PlaybackSegment(type, from, to, SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)

    private val creditsAroundScenes = listOf(
        s(PlaybackSegmentType.CREDITS, m(121), m(124)),
        s(PlaybackSegmentType.MID_CREDITS_SCENE, m(124), m(125, 30)),
        s(PlaybackSegmentType.CREDITS, m(125, 30), m(129)),
        s(PlaybackSegmentType.POST_CREDITS_SCENE, m(129), m(129, 45)),
    )

    @Test fun atTheFirstCreditsTheSkipOffersTheBonusScene() {
        val target = assertNotNull(ProtectedScenePolicy.creditsSkipTarget(m(121), creditsAroundScenes, duration))
        assertEquals(m(124), target.targetMs)
        assertEquals(SkipTargetKind.BONUS_SCENE, target.kind)
    }

    @Test fun theProtectedSceneIsNeverSkippedThrough() {
        assertNull(ProtectedScenePolicy.creditsSkipTarget(m(124, 30), creditsAroundScenes, duration))
        assertTrue(ProtectedScenePolicy.isInsideProtectedScene(m(124, 30), creditsAroundScenes, duration))
        assertNull(ProtectedScenePolicy.creditsSkipTarget(m(129, 20), creditsAroundScenes, duration))
    }

    @Test fun whenTheCreditsResumeTheSkipOffersThePostCreditsScene() {
        val target = assertNotNull(ProtectedScenePolicy.creditsSkipTarget(m(125, 30), creditsAroundScenes, duration))
        assertEquals(m(129), target.targetMs)
        assertEquals(SkipTargetKind.POST_CREDITS_SCENE, target.kind)
    }

    @Test fun automaticTakeoverWaitsForTheLastProtectedScene() {
        assertFalse(ProtectedScenePolicy.automaticTakeoverAllowed(m(121), creditsAroundScenes, duration))
        assertFalse(ProtectedScenePolicy.automaticTakeoverAllowed(m(124, 30), creditsAroundScenes, duration))
        assertFalse(ProtectedScenePolicy.automaticTakeoverAllowed(m(127), creditsAroundScenes, duration))
        assertFalse(ProtectedScenePolicy.automaticTakeoverAllowed(m(129, 30), creditsAroundScenes, duration))
        assertTrue(ProtectedScenePolicy.automaticTakeoverAllowed(m(129, 50), creditsAroundScenes, duration))
    }

    @Test fun creditsWithoutScenesSkipToTheEnd() {
        val only = listOf(s(PlaybackSegmentType.CREDITS, m(121), null))
        val target = assertNotNull(ProtectedScenePolicy.creditsSkipTarget(m(122), only, duration))
        assertEquals(duration, target.targetMs)
        assertEquals(SkipTargetKind.END_OF_MEDIA, target.kind)
        assertTrue(ProtectedScenePolicy.automaticTakeoverAllowed(m(122), only, duration))

        val ending = listOf(s(PlaybackSegmentType.CREDITS, m(121), m(128)))
        assertEquals(SkipTargetKind.END_OF_CREDITS, ProtectedScenePolicy.creditsSkipTarget(m(122), ending, duration)?.kind)
    }

    @Test fun outsideCreditsThereIsNoSkip() {
        assertNull(ProtectedScenePolicy.creditsSkipTarget(m(60), creditsAroundScenes, duration))
    }

    @Test fun anUnexplainedStretchAfterTheLastKnownSegmentIsUncertainNotABonusScene() {
        assertEquals(m(129, 45), PlaybackSegments.uncertainTailStartMs(creditsAroundScenes, duration))
        assertNull(PlaybackSegments.uncertainTailStartMs(creditsAroundScenes, m(129, 47))) // under the tail minimum
        assertNull(PlaybackSegments.uncertainTailStartMs(emptyList(), duration))
        // And the policy never invents a scene for it: nothing is protected out there.
        assertTrue(ProtectedScenePolicy.automaticTakeoverAllowed(m(129, 50), creditsAroundScenes, duration))
    }

    @Test fun creditsThatCoverScenesAreCutIntoPiecesAroundThem() {
        val sloppy = listOf(
            s(PlaybackSegmentType.CREDITS, m(121), m(130)),
            s(PlaybackSegmentType.MID_CREDITS_SCENE, m(124), m(125, 30)),
            s(PlaybackSegmentType.POST_CREDITS_SCENE, m(129), m(129, 45)),
        )
        val cut = PlaybackSegments.creditsAroundScenes(sloppy, duration)
        val credits = cut.filter { it.type == PlaybackSegmentType.CREDITS }.map { it.startMs to it.endMs }
        assertEquals(listOf(m(121) to m(124), m(125, 30) to m(129), m(129, 45) to m(130)), credits)
        assertEquals(2, cut.count { it.type.isProtectedScene })
    }

    @Test fun creditsStartIgnoresScenesAndMislabelledOpenings() {
        assertEquals(m(121), PlaybackSegments.creditsStartMs(creditsAroundScenes, duration))
        val withBadOpening = creditsAroundScenes + s(PlaybackSegmentType.CREDITS, 5_000, 120_000)
        assertEquals(m(121), PlaybackSegments.creditsStartMs(withBadOpening, duration))
    }
}
