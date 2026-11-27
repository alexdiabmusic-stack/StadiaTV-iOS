package com.nuvio.app.features.playback

import com.nuvio.app.features.player.skip.IntroDbSegmentsResponse
import com.nuvio.app.features.player.skip.SkipInterval
import com.nuvio.app.features.player.skip.creditsStartMs
import com.nuvio.app.features.player.skip.movieSkipIntervals
import com.nuvio.app.features.player.skip.toPlaybackSegment
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/**
 * The defect this guards: IntroDB's movie credits were stored as `movie-credits`, but the credits-timing code only knew
 * `outro`/`ed`/`mixed-ed`, so a movie with valid credits markers fell back to a "last four minutes" guess.
 */
class IntroDbMovieCreditsRegressionTest {
    private val json = Json { ignoreUnknownKeys = true }
    private val runtimeMs = 130 * 60_000L

    private fun movieResponse(body: String) = json.decodeFromString<IntroDbSegmentsResponse>(body)

    @Test
    fun movieCreditsFromIntroDbGiveTheCreditsStart() {
        val response = movieResponse(
            """{"imdb_id":"tt0111161","outro":{"start_ms":7260000,"end_ms":7800000,"confidence":0.92,"submission_count":6}}""",
        )
        val intervals = response.movieSkipIntervals()
        assertEquals(listOf("movie-credits"), intervals.map { it.type })
        assertEquals(7_260_000L, intervals.creditsStartMs(runtimeMs))
    }

    @Test
    fun theSameMarkerKeepsItsMovieProvenance() {
        val credits = movieResponse("""{"outro":{"start_ms":7260000,"end_ms":7800000}}""").movieSkipIntervals().single()
        val segment = assertNotNull(credits.toPlaybackSegment())
        assertEquals(PlaybackSegmentType.CREDITS, segment.type)
        assertEquals(SegmentMediaContext.MOVIE, segment.mediaContext)
        assertEquals(SegmentSource.INTRODB, segment.source)
        assertEquals(SegmentMatchQuality.DURATION_AGNOSTIC, segment.matchQuality)
    }

    @Test
    fun postCreditsSceneStopsTheCreditsSkip_andIsNotTreatedAsCredits() {
        val response = movieResponse(
            """{"outro":{"start_ms":7260000,"end_ms":7800000},"post_credits":{"start_ms":7740000,"end_ms":7785000}}""",
        )
        val intervals = response.movieSkipIntervals()
        val credits = intervals.single { it.type == "movie-credits" }
        assertEquals(7740.0, credits.endTime, 0.001) // trimmed to the scene start
        assertEquals(7_260_000L, intervals.creditsStartMs(runtimeMs)) // the scene never becomes "the credits start"
    }

    @Test
    fun episodeStyleOutroAndChapterEndingStillCount() {
        val episode = listOf(SkipInterval(2520.0, 2820.0, "outro", "introdb"))
        assertEquals(2_520_000L, episode.creditsStartMs(2_820_000L))
        val chapters = listOf(SkipInterval(2500.0, 2820.0, "ed", "chapters"))
        assertEquals(2_500_000L, chapters.creditsStartMs(2_820_000L))
    }

    @Test
    fun anOpeningMarkedAsCreditsNearTheStartIsRejectedOnceTheRuntimeIsKnown() {
        val mislabelled = listOf(SkipInterval(5.0, 130.0, "movie-credits", "introdb"))
        assertNull(mislabelled.creditsStartMs(runtimeMs))
    }

    @Test
    fun movieWithoutCreditsDataHasNoCreditsStart() {
        assertNull(movieResponse("""{"imdb_id":"tt0111161"}""").movieSkipIntervals().creditsStartMs(runtimeMs))
    }

    @Test
    fun impossibleTimestampsAreDropped() {
        val bad = movieResponse("""{"outro":{"start_ms":7800000,"end_ms":7260000}}""").movieSkipIntervals()
        assertEquals(emptyList(), bad)
    }
}
