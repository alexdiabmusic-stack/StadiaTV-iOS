package com.nuvio.app.features.playback

import com.nuvio.app.features.player.skip.SkipInterval
import com.nuvio.app.features.player.skip.automaticTakeoverAllowed
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MovieEndingStageTest {
    private fun m(minutes: Int, seconds: Int = 0) = (minutes * 60L + seconds) * 1000L
    private val duration = m(130)

    @Test fun withoutCreditsDataItFollowsTheLastFourMinutesAndThirtySeconds() {
        assertEquals(MovieEndingStage.NONE, MovieEndingStage.stage(m(100), duration, false))
        assertEquals(MovieEndingStage.FIRST, MovieEndingStage.stage(m(126, 30), duration, false))
        assertEquals(MovieEndingStage.FINAL, MovieEndingStage.stage(m(129, 40), duration, false))
        assertEquals(MovieEndingStage.ENDED, MovieEndingStage.stage(duration, duration, true))
    }

    @Test fun knownCreditsStartTheCardFourSecondsAfterTheyRoll_notFourMinutesFromTheEnd() {
        // Credits at 121:00 of a 130:00 film. Before the fix the credits were ignored and nothing showed until 126:00.
        assertEquals(MovieEndingStage.NONE, MovieEndingStage.stage(m(121, 3), duration, false, creditsStartMs = m(121)))
        assertEquals(MovieEndingStage.FIRST, MovieEndingStage.stage(m(121, 5), duration, false, creditsStartMs = m(121)))
        assertEquals(MovieEndingStage.NONE, MovieEndingStage.stage(m(121, 5), duration, false, creditsStartMs = null))
    }

    @Test fun aProtectedSceneAheadHoldsTheCardBack_butTheEndAlwaysShowsIt() {
        assertEquals(MovieEndingStage.NONE, MovieEndingStage.stage(m(121, 5), duration, false, m(121), protectedSceneAhead = true))
        assertEquals(MovieEndingStage.NONE, MovieEndingStage.stage(m(129, 40), duration, false, m(121), protectedSceneAhead = true))
        assertEquals(MovieEndingStage.ENDED, MovieEndingStage.stage(duration, duration, true, m(121), protectedSceneAhead = true))
    }

    @Test fun anUnknownDurationShowsNothingUntilTheEnd() {
        assertEquals(MovieEndingStage.NONE, MovieEndingStage.stage(5_000, 0, false, m(1)))
        assertEquals(MovieEndingStage.ENDED, MovieEndingStage.stage(5_000, 0, true))
    }

    @Test fun postCreditsDataFromIntroDbBlocksTheTakeoverUntilTheSceneEnds() {
        val skip = listOf(
            SkipInterval(7260.0, 7740.0, "movie-credits", "introdb"),
            SkipInterval(7740.0, 7785.0, "post-credits", "introdb"),
        )
        assertFalse(skip.automaticTakeoverAllowed(m(121, 5), duration))
        assertFalse(skip.automaticTakeoverAllowed(m(129, 20), duration))
        assertTrue(skip.automaticTakeoverAllowed(m(129, 50), duration))
    }

    @Test fun aSceneThatCannotFitTheRuntimeNeverHoldsTheCardBack() {
        val nonsense = listOf(SkipInterval(60.0, 100.0, "post-credits", "introdb")) // a "post-credits" scene in minute one
        assertTrue(nonsense.automaticTakeoverAllowed(m(121, 5), duration))
        assertTrue(emptyList<SkipInterval>().automaticTakeoverAllowed(m(121, 5), duration))
    }
}
