package com.nuvio.app.features.playback

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PostPlayStateMachineTest {
    private fun m(min: Int, sec: Int = 0) = (min * 60L + sec) * 1000L
    private val episode = m(45)

    private fun ep(
        position: Long = m(43), ended: Boolean = false, threshold: Boolean = true,
        next: NextEpisodeAvailability = NextEpisodeAvailability.READY, autoplay: Boolean = true,
        readySince: Long? = 1_000L, now: Long = 3_000L, watchCredits: Boolean = false,
        interrupted: Boolean = false, still: Boolean = false, finale: Boolean = false, seriesRec: Boolean = false,
        segments: List<PlaybackSegment> = emptyList(),
    ) = PostPlayInput(
        isMovie = false, positionMs = position, durationMs = episode, isEnded = ended, segments = segments,
        atNextEpisodeThreshold = threshold, nextEpisode = next, autoplayNextEpisode = autoplay,
        countdownMs = 5_000L, nextEpisodeReadySinceMs = readySince, nowMs = now, watchCreditsChosen = watchCredits,
        interrupted = interrupted, stillWatchingPending = still, isSeriesFinale = finale, hasSeriesRecommendation = seriesRec,
    )

    // --- countdown ---

    @Test fun theCountdownRunsFiveSecondsFromWhenTheSourceIsReady() {
        val d = PostPlayStateMachine.decide(ep(readySince = 1_000L, now = 3_000L))
        assertEquals(PostPlayState.NextEpisodeCountdown, d.state)
        assertEquals(3_000L, d.countdownRemainingMs)
        assertEquals(0.4f, d.countdownProgress!!, 0.001f)
        assertFalse(d.startNextEpisode)
    }

    @Test fun theNextEpisodeStartsExactlyWhenTheCountdownReachesZero() {
        val d = PostPlayStateMachine.decide(ep(readySince = 1_000L, now = 6_000L))
        assertTrue(d.startNextEpisode); assertEquals(1f, d.countdownProgress)
    }

    @Test fun noCountdownIsShownUntilASourceIsReady() {
        assertEquals(PostPlayState.NextEpisodePreparing, PostPlayStateMachine.decide(ep(next = NextEpisodeAvailability.PREPARING, readySince = null)).state)
        val notYet = PostPlayStateMachine.decide(ep(readySince = null))
        assertEquals(PostPlayState.NextEpisodeReady, notYet.state)
        assertNull(notYet.countdownRemainingMs); assertFalse(notYet.startNextEpisode)
    }

    @Test fun withAutoplayOffThereIsNoCountdownAndNothingStartsOnItsOwn() {
        val d = PostPlayStateMachine.decide(ep(autoplay = false, readySince = 1_000L, now = 999_000L))
        assertEquals(PostPlayState.NextEpisodeReady, d.state)
        assertFalse(d.startNextEpisode); assertNull(d.countdownRemainingMs)
    }

    // --- Watch Credits ---

    @Test fun watchCreditsCancelsTheCountdownAndSuppressesAutoplay() {
        val d = PostPlayStateMachine.decide(ep(watchCredits = true, readySince = 1_000L, now = 999_000L))
        assertEquals(PostPlayState.WatchCredits, d.state)
        assertFalse(d.startNextEpisode); assertFalse(d.automaticTakeoverAllowed)
    }

    @Test fun watchCreditsStaysStickyThroughTheEndOfTheFileAndAFreshThreshold() {
        // One second left, then EOF: the choice is not undone and nothing starts.
        for (pos in listOf(m(44, 59), episode)) {
            val d = PostPlayStateMachine.decide(ep(position = pos, ended = pos == episode, watchCredits = true))
            assertEquals(PostPlayState.WatchCredits, d.state)
            assertFalse(d.startNextEpisode)
        }
    }

    @Test fun rewindingBeforeTheCreditsDoesNotClearTheChoiceItJustLeavesTheEndingLayer() {
        val rewound = PostPlayStateMachine.decide(ep(position = m(30), threshold = false, watchCredits = true))
        assertEquals(PostPlayState.NormalPlayback, rewound.state)
        // Coming back to the credits: still the viewer's choice.
        assertEquals(PostPlayState.WatchCredits, PostPlayStateMachine.decide(ep(position = m(43), watchCredits = true)).state)
    }

    // --- precedence ---

    @Test fun anInterruptionSuppressesEveryEndingOverlay() {
        assertEquals(PostPlayState.NormalPlayback, PostPlayStateMachine.decide(ep(interrupted = true)).state)
        assertFalse(PostPlayStateMachine.decide(ep(interrupted = true)).automaticTakeoverAllowed)
    }

    @Test fun anInEpisodeProtectedSceneHoldsEverythingBack() {
        val scene = PlaybackSegment(PlaybackSegmentType.POST_CREDITS_SCENE, m(44, 10), m(44, 50), SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)
        assertEquals(PostPlayState.ProtectedScene, PostPlayStateMachine.decide(ep(position = m(44, 20), segments = listOf(scene))).state)
        // A scene still ahead means no takeover yet.
        val before = PostPlayStateMachine.decide(ep(position = m(43), segments = listOf(scene)))
        assertFalse(before.automaticTakeoverAllowed); assertFalse(before.startNextEpisode)
        assertEquals(PostPlayState.NormalPlayback, before.state)
    }

    @Test fun stillWatchingBlocksTheNextEpisodeUntilAnswered() {
        val d = PostPlayStateMachine.decide(ep(still = true, readySince = 1_000L, now = 999_000L))
        assertEquals(PostPlayState.StillWatching, d.state); assertFalse(d.startNextEpisode)
    }

    @Test fun duringATransitionNothingElseShows() {
        assertEquals(PostPlayState.Transitioning, PostPlayStateMachine.decide(ep().copy(transitioning = true)).state)
    }

    // --- episodes with nothing to play next ---

    @Test fun theLastEpisodeOfASeriesGetsARecommendationNotADeadNextEpisodeCard() {
        val d = PostPlayStateMachine.decide(ep(ended = true, next = NextEpisodeAvailability.NONE, finale = true, seriesRec = true))
        assertEquals(PostPlayState.SeriesCompletionRecommendation, d.state)
    }

    @Test fun aSeasonFinaleWithAnUnreleasedNextSeasonJustFinishes() {
        assertEquals(PostPlayState.PlaybackFinished, PostPlayStateMachine.decide(ep(ended = true, next = NextEpisodeAvailability.NOT_RELEASED, finale = false)).state)
        assertEquals(PostPlayState.CreditsEligible, PostPlayStateMachine.decide(ep(ended = false, next = NextEpisodeAvailability.NOT_RELEASED)).state)
    }

    @Test fun beforeTheCreditsOnlySkippableSegmentsShowAndNormalPlaybackIsQuiet() {
        val intro = PlaybackSegment(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)
        assertEquals(PostPlayState.SkippableSegment, PostPlayStateMachine.decide(ep(position = m(1, 30), threshold = false, segments = listOf(intro))).state)
        assertEquals(PostPlayState.NormalPlayback, PostPlayStateMachine.decide(ep(position = m(20), threshold = false)).state)
    }

    // --- movies ---

    private fun movie(position: Long, stage: Int, rec: Boolean = true, dismissed: Boolean = false, ended: Boolean = false, watchCredits: Boolean = false, segs: List<PlaybackSegment> = emptyList()) =
        PostPlayInput(true, position, m(130), ended, segs, movieStage = stage, hasMovieRecommendation = rec, movieRecommendationDismissed = dismissed, watchCreditsChosen = watchCredits)

    @Test fun theMovieRecommendationShowsWhenTheStageIsReachedAndOneExists() {
        assertEquals(PostPlayState.MovieRecommendation, PostPlayStateMachine.decide(movie(m(121, 5), MovieEndingStage.FIRST)).state)
        assertEquals(PostPlayState.CreditsEligible, PostPlayStateMachine.decide(movie(m(121, 5), MovieEndingStage.FIRST, rec = false)).state)
    }

    @Test fun withNoRecommendationTheCreditsStayFullScreenAndTheEndJustFinishes() {
        assertEquals(PostPlayState.PlaybackFinished, PostPlayStateMachine.decide(movie(m(130), MovieEndingStage.ENDED, rec = false, ended = true)).state)
    }

    @Test fun aDismissedMovieCardDoesNotTakeOverAgainButTheEndStillShowsIt() {
        assertEquals(PostPlayState.CreditsEligible, PostPlayStateMachine.decide(movie(m(126), MovieEndingStage.FIRST, dismissed = true)).state)
        assertEquals(PostPlayState.MovieRecommendation, PostPlayStateMachine.decide(movie(m(130), MovieEndingStage.ENDED, dismissed = true, ended = true)).state)
    }

    @Test fun restoringFullScreenCreditsPutsTheMovieInWatchCredits() {
        assertEquals(PostPlayState.WatchCredits, PostPlayStateMachine.decide(movie(m(125), MovieEndingStage.FIRST, watchCredits = true)).state)
    }

    @Test fun aMovieWithABonusSceneAheadDoesNotTakeOverUntilItEnds() {
        val post = PlaybackSegment(PlaybackSegmentType.POST_CREDITS_SCENE, m(129), m(129, 45), SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)
        val during = PostPlayStateMachine.decide(movie(m(127), MovieEndingStage.FIRST, segs = listOf(post)))
        assertFalse(during.automaticTakeoverAllowed)
        assertTrue(during.state != PostPlayState.MovieRecommendation)
        assertEquals(PostPlayState.ProtectedScene, PostPlayStateMachine.decide(movie(m(129, 20), MovieEndingStage.FIRST, segs = listOf(post))).state)
        assertEquals(PostPlayState.MovieRecommendation, PostPlayStateMachine.decide(movie(m(129, 50), MovieEndingStage.FINAL, segs = listOf(post))).state)
    }
}

class UnattendedViewingTrackerTest {
    private val min = 60_000L

    @Test fun threeEpisodesInARowWithoutInteractionPromptsOnTheFourth() {
        val t = UnattendedViewingTracker()
        t.onEpisodeAutoAdvanced(0); t.onEpisodeAutoAdvanced(40 * min)
        assertFalse(t.shouldPrompt(80 * min))
        t.onEpisodeAutoAdvanced(80 * min)
        assertTrue(t.shouldPrompt(120 * min))
    }

    @Test fun anyRealInteractionResetsTheCount() {
        val t = UnattendedViewingTracker()
        repeat(2) { t.onEpisodeAutoAdvanced(it * 40 * min) }
        t.onInteraction(85 * min) // paused, sought, or pressed a control
        t.onEpisodeAutoAdvanced(90 * min)
        assertFalse(t.shouldPrompt(130 * min)); assertEquals(1, t.unattendedEpisodes)
    }

    @Test fun continueWatchingStartsTheCountAgain() {
        val t = UnattendedViewingTracker()
        repeat(3) { t.onEpisodeAutoAdvanced(it * 40 * min) }
        assertTrue(t.shouldPrompt(120 * min))
        t.onContinue(121 * min)
        assertFalse(t.shouldPrompt(122 * min))
    }

    @Test fun onATelevisionTheNinetyMinuteConditionAlsoApplies() {
        val t = UnattendedViewingTracker(isTelevision = true)
        t.onEpisodeAutoAdvanced(0); t.onEpisodeAutoAdvanced(10 * min); t.onEpisodeAutoAdvanced(20 * min)
        assertFalse(t.shouldPrompt(30 * min)) // three episodes but only half an hour
        assertTrue(t.shouldPrompt(95 * min))
    }

    @Test fun autoSkippingAnIntroIsNotInteractionBecauseNothingRecordsIt() {
        // The tracker only learns of interaction through onInteraction; the player never calls it for an automatic skip.
        val t = UnattendedViewingTracker()
        repeat(3) { t.onEpisodeAutoAdvanced(it * 40 * min) }
        assertTrue(t.shouldPrompt(120 * min))
        assertNotNull(t.unattendedEpisodes)
    }
}
