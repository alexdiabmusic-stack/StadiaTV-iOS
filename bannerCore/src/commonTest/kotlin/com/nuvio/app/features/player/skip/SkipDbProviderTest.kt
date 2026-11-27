package com.nuvio.app.features.player.skip

import com.nuvio.app.features.addons.AddonHttp
import com.nuvio.app.features.addons.RawHttpResponse
import com.nuvio.app.features.playback.PlaybackSegmentType
import com.nuvio.app.features.playback.SegmentArbiter
import com.nuvio.app.features.playback.SegmentCandidate
import com.nuvio.app.features.playback.SegmentLookupOutcome
import com.nuvio.app.features.playback.SegmentMatchQuality
import com.nuvio.app.features.playback.SegmentMediaContext
import com.nuvio.app.features.playback.SegmentSource
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SkipDbProviderTest {
    /** The example response from skipdb.tv/docs, with the elided fields filled in. */
    private val docsExample = """{"imdb_id":"tt0903747","season":1,"episode":1,"segments":{
        "intro":{"start_ms":61000,"end_ms":91000,"match":"exact","adjusted":false,"offset_ms":0,"confidence":0.93},
        "recap":null,
        "outro":{"start_ms":2760000,"end_ms":2820000,"match":"shifted","adjusted":true,"offset_ms":4000,"confidence":0.8},
        "preview":{"start_ms":2700000,"end_ms":2760000,"match":"out-of-range","adjusted":false,"offset_ms":0,"confidence":0.4}},
        "intro_length_estimate_ms":30000}"""

    private class FakeHttp(val status: Int = 200, val body: String = "", val fail: Exception? = null) : AddonHttp.Backend {
        var lastUrl: String? = null
        override suspend fun getText(url: String) = error("unused")
        override suspend fun postJson(url: String, body: String) = error("unused")
        override suspend fun getTextWithHeaders(url: String, headers: Map<String, String>) = error("unused")
        override suspend fun postJsonWithHeaders(url: String, body: String, headers: Map<String, String>) = error("unused")
        override suspend fun requestRaw(method: String, url: String, headers: Map<String, String>, body: String, followRedirects: Boolean, maxResponseBodyBytes: Int, bodyBytes: ByteArray?): RawHttpResponse {
            lastUrl = url
            fail?.let { throw it }
            return RawHttpResponse(status, "", url, this.body, emptyMap())
        }
    }

    private suspend fun <T> withHttp(http: FakeHttp, block: suspend () -> T): T {
        val previous = AddonHttp.backend
        AddonHttp.backend = http
        try { return block() } finally { AddonHttp.backend = previous }
    }

    @Test fun theDocsExampleMapsToTypedSegmentsWithMatchQuality() {
        val outcome = assertIs<SegmentLookupOutcome.Segments>(SkipDbProvider.parse(docsExample, SegmentMediaContext.EPISODE))
        val byType = outcome.segments.associateBy { it.type }
        assertEquals(setOf(PlaybackSegmentType.INTRO, PlaybackSegmentType.CREDITS, PlaybackSegmentType.NEXT_EPISODE_PREVIEW), byType.keys)
        assertEquals(61_000L, byType.getValue(PlaybackSegmentType.INTRO).startMs)
        assertEquals(SegmentMatchQuality.DURATION_MATCHED, byType.getValue(PlaybackSegmentType.INTRO).matchQuality)
        assertEquals(SegmentMatchQuality.DURATION_ADJUSTED, byType.getValue(PlaybackSegmentType.CREDITS).matchQuality)
        assertEquals(SegmentMatchQuality.DURATION_APPROXIMATE, byType.getValue(PlaybackSegmentType.NEXT_EPISODE_PREVIEW).matchQuality)
        assertTrue(outcome.segments.all { it.source == SegmentSource.SKIPDB })
    }

    @Test fun anOutOfRangeMatchIsNeverUsedAutomatically() {
        val outcome = assertIs<SegmentLookupOutcome.Segments>(SkipDbProvider.parse(docsExample, SegmentMediaContext.EPISODE))
        val outro = outcome.segments.single { it.type == PlaybackSegmentType.CREDITS }.copy(matchQuality = SegmentMatchQuality.DURATION_APPROXIMATE)
        val arbitrated = SegmentArbiter.arbitrate(listOf(SegmentCandidate(outro, Unit)), 2_820_000L)
        assertEquals(1, arbitrated.size)
        assertFalse(arbitrated.single().usableForAutomatic) // still offered as a manual skip
    }

    @Test fun previewsAreNotSurfacedAsSkipButtons() {
        val intervals = SkipDbProvider.parse(docsExample, SegmentMediaContext.EPISODE).toSkipIntervals("skipdb")
        assertEquals(listOf("intro", "outro"), intervals.map { it.type })
        assertEquals(61.0, intervals.first().startTime, 0.001)
        assertEquals("skipdb", intervals.first().provider)
        assertEquals(0.93, intervals.first().confidence!!, 0.001)
    }

    @Test fun movieCreditsKeepTheirMovieType() {
        val body = """{"imdb_id":"tt0111161","segments":{"intro":null,"recap":null,"outro":{"start_ms":7260000,"end_ms":7800000,"match":"agnostic","confidence":0.7},"preview":null}}"""
        val intervals = SkipDbProvider.parse(body, SegmentMediaContext.MOVIE).toSkipIntervals("skipdb")
        assertEquals(listOf("movie-credits"), intervals.map { it.type })
    }

    @Test fun nullSegmentsAreNoData_notConfirmedAbsent() {
        val none = """{"imdb_id":"tt1","season":1,"episode":1,"segments":{"intro":null,"recap":null,"outro":null,"preview":null}}"""
        assertIs<SegmentLookupOutcome.NoData>(SkipDbProvider.parse(none, SegmentMediaContext.EPISODE))
        assertIs<SegmentLookupOutcome.NoData>(SkipDbProvider.parse("""{"imdb_id":"tt1"}""", SegmentMediaContext.EPISODE))
    }

    @Test fun impossibleTimestampsAndGarbageAreInvalid() {
        val bad = """{"segments":{"intro":{"start_ms":90000,"end_ms":60000,"match":"exact"},"recap":null,"outro":null,"preview":null}}"""
        assertIs<SegmentLookupOutcome.Invalid>(SkipDbProvider.parse(bad, SegmentMediaContext.EPISODE))
        assertIs<SegmentLookupOutcome.Invalid>(SkipDbProvider.parse("<html>not json</html>", SegmentMediaContext.EPISODE))
    }

    @Test fun requestUrlsFollowTheDocumentedShape() {
        assertEquals(
            "https://api.skipdb.tv/api/segments?imdb_id=tt0903747&season=1&episode=1&duration=2820&adjust=conservative",
            SkipDbProvider.requestUrl("tt0903747", 1, 1, 2_820_000L),
        )
        // A movie omits season and episode; no duration is sent until the real one is known.
        assertEquals("https://api.skipdb.tv/api/segments?imdb_id=tt0111161&adjust=conservative", SkipDbProvider.requestUrl("tt0111161", null, null, null))
        assertNull(SkipDbProvider.requestUrl("not-an-id&x=1", 1, 1, null))
    }

    @Test fun statusCodesBecomeDistinctOutcomes() = runTest {
        suspend fun outcome(status: Int, body: String = "") = withHttp(FakeHttp(status, body)) { SkipDbProvider.fetch("tt0903747", 1, 1, null) }
        assertIs<SegmentLookupOutcome.Segments>(outcome(200, docsExample))
        assertIs<SegmentLookupOutcome.NoData>(outcome(404))
        assertTrue(assertIs<SegmentLookupOutcome.ProviderError>(outcome(429)).retryable)
        assertTrue(assertIs<SegmentLookupOutcome.ProviderError>(outcome(503)).retryable)
        assertIs<SegmentLookupOutcome.Invalid>(outcome(400))
        assertIs<SegmentLookupOutcome.Invalid>(outcome(422))
        assertFalse(assertIs<SegmentLookupOutcome.ProviderError>(outcome(418)).retryable)
    }

    @Test fun aNetworkFailureIsAProviderErrorNeverEmptyData() = runTest {
        val result = withHttp(FakeHttp(fail = RuntimeException("offline"))) { SkipDbProvider.fetch("tt0903747", 1, 1, null) }
        assertIs<SegmentLookupOutcome.ProviderError>(result)
    }

    @Test fun theRequestSendsTheDurationOnlyWhenKnown() = runTest {
        val http = FakeHttp(200, docsExample)
        withHttp(http) { SkipDbProvider.fetch("tt0903747", 1, 1, 2_820_000L) }
        assertTrue(http.lastUrl!!.contains("duration=2820"))
    }
}
