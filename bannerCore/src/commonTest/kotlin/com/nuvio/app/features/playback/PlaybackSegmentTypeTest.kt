package com.nuvio.app.features.playback

import com.nuvio.app.features.player.skip.SkipInterval
import com.nuvio.app.features.player.skip.isCredits
import com.nuvio.app.features.player.skip.segmentType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PlaybackSegmentTypeTest {
    @Test
    fun everyIntroAliasIsIntro() {
        for (raw in listOf("intro", "op", "opening", "mixed-op", "Mixed Intro", "NEW_INTRO")) {
            assertEquals(PlaybackSegmentType.INTRO, PlaybackSegmentType.fromRaw(raw), raw)
        }
    }

    @Test
    fun everyEndCreditsAliasIsCredits_includingTheMovieOne() {
        for (raw in listOf("outro", "ed", "mixed-ed", "credits", "movie-credits", "ending", "end credits", "End_Credits", "closing-credits")) {
            assertEquals(PlaybackSegmentType.CREDITS, PlaybackSegmentType.fromRaw(raw), raw)
        }
    }

    @Test
    fun openingCreditsAreAnIntro_neverEndCredits() {
        assertEquals(PlaybackSegmentType.INTRO, PlaybackSegmentType.fromRaw("Opening Credits"))
        assertEquals(PlaybackSegmentType.INTRO, PlaybackSegmentType.fromRaw("opening-theme"))
    }

    @Test
    fun aLabelContainingTheWordCreditsIsNotGuessedAsCredits() {
        // Whole-label matching only: scene names stay unknown instead of being mistaken for the end credits.
        for (raw in listOf("The Credits Sequence Scene", "credits roll", "Credit Card", "opening credits scene 2")) {
            assertEquals(PlaybackSegmentType.UNKNOWN, PlaybackSegmentType.fromRaw(raw), raw)
        }
    }

    @Test
    fun scenesRecapAndPreviewMapToTheirOwnTypes() {
        assertEquals(PlaybackSegmentType.POST_CREDITS_SCENE, PlaybackSegmentType.fromRaw("post-credits"))
        assertEquals(PlaybackSegmentType.POST_CREDITS_SCENE, PlaybackSegmentType.fromRaw("After Credits"))
        assertEquals(PlaybackSegmentType.MID_CREDITS_SCENE, PlaybackSegmentType.fromRaw("mid-credits"))
        assertEquals(PlaybackSegmentType.RECAP, PlaybackSegmentType.fromRaw("recap"))
        assertEquals(PlaybackSegmentType.NEXT_EPISODE_PREVIEW, PlaybackSegmentType.fromRaw("preview"))
    }

    @Test
    fun blankNullAndUnknownLabelsAreUnknown() {
        assertEquals(PlaybackSegmentType.UNKNOWN, PlaybackSegmentType.fromRaw(null))
        assertEquals(PlaybackSegmentType.UNKNOWN, PlaybackSegmentType.fromRaw("   "))
        assertEquals(PlaybackSegmentType.UNKNOWN, PlaybackSegmentType.fromRaw("commercial"))
    }

    @Test
    fun protectedAndSkippableFlagsFollowTheType() {
        assertTrue(PlaybackSegmentType.POST_CREDITS_SCENE.isProtectedScene)
        assertTrue(PlaybackSegmentType.MID_CREDITS_SCENE.isProtectedScene)
        assertFalse(PlaybackSegmentType.CREDITS.isProtectedScene)
        assertTrue(PlaybackSegmentType.CREDITS.isSkippable)
        assertFalse(PlaybackSegmentType.POST_CREDITS_SCENE.isSkippable)
        assertFalse(PlaybackSegmentType.UNKNOWN.isSkippable)
    }

    @Test
    fun skipIntervalsReadThroughTheSameNormalizer() {
        assertTrue(SkipInterval(7260.0, 7740.0, "movie-credits", "introdb").isCredits())
        assertTrue(SkipInterval(2400.0, 2520.0, "ed", "animeskip").isCredits())
        assertFalse(SkipInterval(0.0, 90.0, "op", "animeskip").isCredits())
        assertEquals(PlaybackSegmentType.INTRO, SkipInterval(0.0, 90.0, "opening", "chapters").segmentType)
    }

    @Test
    fun sourcesAreRecognisedFromProviderNames() {
        assertEquals(SegmentSource.INTRODB, SegmentSource.fromProvider("introdb"))
        assertEquals(SegmentSource.ANIME_SKIP, SegmentSource.fromProvider("animeskip"))
        assertEquals(SegmentSource.CHAPTERS, SegmentSource.fromProvider("chapters"))
        assertEquals(SegmentSource.OTHER, SegmentSource.fromProvider("somewhere-new"))
    }
}
