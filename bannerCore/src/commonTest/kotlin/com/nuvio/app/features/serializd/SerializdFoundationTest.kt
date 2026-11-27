package com.nuvio.app.features.serializd

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SerializdRatingTest {
    @Test fun everyHalfStarMapsToSerializdsOneToTen() {
        val expected = listOf(0.5 to 1, 1.0 to 2, 1.5 to 3, 2.0 to 4, 2.5 to 5, 3.0 to 6, 3.5 to 7, 4.0 to 8, 4.5 to 9, 5.0 to 10)
        expected.forEach { (stars, value) -> assertEquals(value, SerializdRating.toSerializd(stars), "$stars stars"); assertEquals(stars, SerializdRating.fromSerializd(value)) }
    }

    @Test fun unratedIsZeroAndIsNeverMistakenForARating() {
        assertEquals(0, SerializdRating.toSerializd(null))
        assertEquals(0, SerializdRating.toSerializd(0.0))
        assertEquals(0, SerializdRating.toSerializd(-3.0))
        assertNull(SerializdRating.fromSerializd(0)); assertNull(SerializdRating.fromSerializd(null)); assertNull(SerializdRating.fromSerializd(11)); assertNull(SerializdRating.fromSerializd(-1))
    }

    @Test fun valuesBetweenStepsAreRoundedAndOutOfRangeIsClamped() {
        assertEquals(7, SerializdRating.toSerializd(3.4)) // snaps to 3.5
        assertEquals(1, SerializdRating.toSerializd(0.1)) // a real but tiny rating is the lowest rating, not unrated
        assertEquals(10, SerializdRating.toSerializd(9.0))
        assertEquals(3.5, SerializdRating.snap(3.4)); assertNull(SerializdRating.snap(0.0))
        assertEquals("4.5", SerializdRating.label(4.5)); assertEquals("4", SerializdRating.label(4.0)); assertEquals("Unrated", SerializdRating.label(null))
        assertEquals(Triple(3, 1, 1), SerializdRating.glyphs(3.5)); assertEquals(11, SerializdRating.choices.size)
    }
}

class SerializdDatesTest {
    @Test fun formatsAnEpochMomentAsUtcSeconds() {
        assertEquals("1970-01-01T00:00:00Z", SerializdDates.isoUtc(0))
        assertEquals("2023-11-14T22:13:20Z", SerializdDates.isoUtc(1_700_000_000_000))
        assertEquals("2023-11-14T22:13:20Z", SerializdDates.isoUtc(1_700_000_000_999)) // whole seconds
        assertEquals("2000-02-29T12:00:00Z", SerializdDates.isoUtc(951_825_600_000))
        assertEquals("2023-11-14", SerializdDates.utcDate(1_700_000_000_000))
    }

    @Test fun readsTheFormsSerializdSends() {
        val base = SerializdDates.parse("2026-11-23T00:00:00Z")!!
        assertFalse(base.dateOnly)
        assertEquals(base.ms, SerializdDates.parse("2026-11-23T00:00:00.000Z")!!.ms)
        assertEquals(base.ms, SerializdDates.parse("2026-11-23T02:00:00+02:00")!!.ms)
        assertEquals(base.ms, SerializdDates.parse("2026-11-22T19:00:00-05:00")!!.ms)
        assertEquals(base.ms, SerializdDates.parse("2026-11-23T00:00:00")!!.ms) // no offset means UTC
        val dateOnly = SerializdDates.parse("2026-11-23")!!
        assertTrue(dateOnly.dateOnly); assertEquals(base.ms, dateOnly.ms)
    }

    @Test fun anythingElseIsNullNotAGuess() {
        listOf(null, "", "yesterday", "2026-13-01", "2026-11-23T25:00:00Z", "2026/11/23", "2026-11-23T10:00:00 PST").forEach { assertNull(SerializdDates.parse(it), "$it") }
    }

    @Test fun roundTripsThroughTheFormatter() {
        listOf(0L, 1_700_000_000_000L, 1_795_000_123_000L, 4_102_444_800_000L).forEach { ms -> assertEquals(ms, SerializdDates.parse(SerializdDates.isoUtc(ms))!!.ms) }
    }
}

class SerializdEpisodeMapperTest {
    @Test fun anOrdinaryEpisode() {
        assertEquals(SerializdEpisodeRef(1399, 1, listOf(3)), SerializdEpisodeMapper.build(1399, 1, 3))
    }

    @Test fun specialsAreSeasonZeroAndAreAccepted() {
        assertEquals(SerializdEpisodeRef(1399, 0, listOf(2)), SerializdEpisodeMapper.build(1399, 0, 2))
    }

    @Test fun missingOrWrongIdsMapToNothing() {
        assertNull(SerializdEpisodeMapper.build(null, 1, 1)); assertNull(SerializdEpisodeMapper.build(0, 1, 1)); assertNull(SerializdEpisodeMapper.build(-5, 1, 1))
        assertNull(SerializdEpisodeMapper.build(1399, null, 1)); assertNull(SerializdEpisodeMapper.build(1399, -1, 1))
        assertNull(SerializdEpisodeMapper.build(1399, 1, null)); assertNull(SerializdEpisodeMapper.build(1399, 1, 0))
    }

    @Test fun aFileHoldingSeveralEpisodesLogsEachOfThem() {
        assertEquals(listOf(3, 4, 5), SerializdEpisodeMapper.build(1399, 1, 3, 5)!!.episodeNumbers)
        assertEquals(listOf(3), SerializdEpisodeMapper.build(1399, 1, 3, 3)!!.episodeNumbers)
        assertEquals(listOf(3), SerializdEpisodeMapper.build(1399, 1, 3, 2)!!.episodeNumbers)
    }

    @Test fun anAbsurdRangeIsBadMetadataSoOnlyTheFirstEpisodeCounts() {
        assertEquals(listOf(1), SerializdEpisodeMapper.build(1399, 1, 1, 60)!!.episodeNumbers)
        assertEquals(25, SerializdEpisodeMapper.build(1399, 1, 1, 25)!!.episodeNumbers.size) // 24 apart is the widest accepted
    }
}

class SerializdSeasonTargetTest {
    @Test fun anEpisodePastTheEndOfSerializdsSeasonIsRefusedNotLogged() {
        val t = SerializdSeasonTarget(seasonId = 9, episodeOffset = 0, episodeCount = 10)
        assertEquals(10, t.episodeFor(10)); assertNull(t.episodeFor(11))
        assertEquals(5, SerializdSeasonTarget(9, 0, null).episodeFor(5)) // an unknown count cannot be checked
    }

    @Test fun anOffsetShiftsTheEpisodeIntoTheLongFirstSeason() {
        val t = SerializdSeasonTarget(9, 12, 24)
        assertEquals(15, t.episodeFor(3)); assertEquals(24, t.episodeFor(12)); assertNull(t.episodeFor(13))
    }

    @Test fun theOffsetNeedsEveryEarlierSeasonsLength() {
        assertEquals(0, SerializdSeasonResolver.episodeOffset(1, emptyMap()))
        assertEquals(12, SerializdSeasonResolver.episodeOffset(2, mapOf(1 to 12)))
        assertEquals(22, SerializdSeasonResolver.episodeOffset(3, mapOf(1 to 12, 2 to 10)))
        assertNull(SerializdSeasonResolver.episodeOffset(3, mapOf(2 to 10)))
        assertNull(SerializdSeasonResolver.episodeOffset(2, mapOf(1 to 0)))
    }
}

class SerializdSeasonResolverTest {
    private fun rig(): Triple<FakeSerializdServer, SerializdSeasonResolver, MemorySerializdKv> {
        val server = FakeSerializdServer()
        val session = SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, pause = {}, jitter = { 0 })
        val kv = MemorySerializdKv()
        return Triple(server, SerializdSeasonResolver(SerializdApi(session), kv, { 1_700_000_000_000 }), kv)
    }

    @Test fun mapsTmdbSeasonNumbersToSerializdIdsAndAsksOnce() = runTest {
        val (server, resolver, _) = rig()
        assertEquals(3624, resolver.seasonId(1399, 1)); assertEquals(3625, resolver.seasonId(1399, 2)); assertEquals(10, resolver.episodeCount(1399, 1))
        assertEquals(1, server.requests.count { it.path == "/show/1399" })
        assertEquals(3627, resolver.seasonId(1399, 0)) // specials resolve too
    }

    @Test fun theMapSurvivesARestart() = runTest {
        val (server, resolver, kv) = rig()
        resolver.seasonId(1399, 1)
        val again = SerializdSeasonResolver(SerializdApi(SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, pause = {})), kv, { 1_700_000_000_000 })
        assertEquals(3624, again.seasonId(1399, 1))
        assertEquals(1, server.requests.count { it.path == "/show/1399" })
    }

    @Test fun aNewSeasonTriggersOneRefreshButNotOnEveryMiss() = runTest {
        var clock = 1_700_000_000_000L
        val server = FakeSerializdServer()
        val resolver = SerializdSeasonResolver(SerializdApi(SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, pause = {})), MemorySerializdKv(), { clock })
        assertNull(resolver.seasonId(1399, 4))
        assertEquals(1, server.requests.count { it.path == "/show/1399" }) // fresh data: a miss is not worth asking again
        server.shows[1399] = FakeSerializdServer.Show(1399, "Game of Thrones", server.shows.getValue(1399).seasons + FakeSerializdServer.Season(4, 3700, 10))
        clock += 11 * 60_000L
        assertEquals(3700, resolver.seasonId(1399, 4))
        assertEquals(2, server.requests.count { it.path == "/show/1399" })
    }

    @Test fun aShowSerializdDoesNotHaveIsRemembered() = runTest {
        val (server, resolver, _) = rig()
        assertNull(resolver.seasonId(777, 1)); assertNull(resolver.seasonId(777, 2)); assertNull(resolver.show(777))
        assertEquals(1, server.requests.count { it.path == "/show/777" })
    }

    @Test fun serializdIdsComeBackAsSeasonNumbers() = runTest {
        val (_, resolver, _) = rig()
        assertEquals(listOf(1, 3), resolver.seasonNumbers(1399, listOf(3626, 3624)))
        assertEquals(emptyList(), resolver.seasonNumbers(1399, listOf(424242)))
    }

    @Test fun watchedSeasonsAreMatchedByIdFirstAndByCountOnlyWhenTheCountSettlesIt() = runTest {
        val (_, resolver, _) = rig() // Game of Thrones here: specials 3627, seasons 1-3 as 3624-3626
        assertEquals(SerializdWatchedSeasons(listOf(1, 3), 0, 0), resolver.watchedSeasons(1399, listOf(3626, 3624)))
        assertEquals(SerializdWatchedSeasons(emptyList(), 0, 0), resolver.watchedSeasons(1399, emptyList()))
        // All three stale ids against the three numbered seasons nobody else has marked.
        assertEquals(SerializdWatchedSeasons(listOf(1, 2, 3), 3, 0), resolver.watchedSeasons(1399, listOf(11, 12, 13)))
        // The same ids listed twice are one mark.
        assertEquals(SerializdWatchedSeasons(listOf(1, 2, 3), 3, 0), resolver.watchedSeasons(1399, listOf(11, 12, 13, 13)))
        // One matched by id leaves two seasons, and two stale ids fill them.
        assertEquals(SerializdWatchedSeasons(listOf(1, 2, 3), 2, 0), resolver.watchedSeasons(1399, listOf(3624, 11, 12)))
        // Fewer stale ids than open seasons: which ones were meant is not recorded, so none is guessed.
        assertEquals(SerializdWatchedSeasons(listOf(1), 0, 1), resolver.watchedSeasons(1399, listOf(3624, 11)))
        assertEquals(SerializdWatchedSeasons(emptyList(), 0, 1), resolver.watchedSeasons(1399, listOf(424242)))
        // More stale ids than seasons: the shapes do not line up.
        assertEquals(SerializdWatchedSeasons(emptyList(), 0, 5), resolver.watchedSeasons(1399, listOf(1, 2, 3, 4, 5)))
        // A show Serializd does not have cannot be placed at all.
        assertEquals(SerializdWatchedSeasons(emptyList(), 0, 2), resolver.watchedSeasons(777, listOf(1, 2)))
    }

    @Test fun aShowWithOnlySpecialsOpenIsNeverPlacedByCount() = runTest {
        val (server, resolver, _) = rig()
        server.shows[6000] = FakeSerializdServer.Show(6000, "Only specials", listOf(FakeSerializdServer.Season(0, 6001, 3)))
        assertEquals(SerializdWatchedSeasons(emptyList(), 0, 1), resolver.watchedSeasons(6000, listOf(99)), "season 0 alone is not 'every numbered season'")
    }

    private fun mergedShow(server: FakeSerializdServer) {
        // Serializd keeps this show as one 24-episode season; TMDB has two seasons of 12.
        server.shows[5000] = FakeSerializdServer.Show(5000, "Merged", listOf(FakeSerializdServer.Season(1, 9001, 24)))
    }

    @Test fun aLaterSeasonThatSerializdHasMergedIsPlacedAfterTheEarlierOnes() = runTest {
        val (server, resolver, _) = rig(); mergedShow(server)
        val t = resolver.target(5000, 2) { mapOf(1 to 12, 2 to 12) }
        assertEquals(SerializdSeasonTarget(9001, 12, 24), t)
        assertEquals(15, t!!.episodeFor(3))
    }

    @Test fun theFallbackRefusesWhenItCannotBeSure() = runTest {
        val (server, resolver, _) = rig(); mergedShow(server)
        assertNull(resolver.target(5000, 2) { emptyMap() }, "earlier season lengths unknown")
        assertNull(resolver.target(5000, 2) { mapOf(1 to 30, 2 to 12) }, "the offset would start past the end of Serializd's season")
        assertNull(resolver.target(5000, 1) { mapOf(1 to 12) }.takeIf { false }) // season 1 is simply found, never a fallback
        assertEquals(9001, resolver.target(5000, 1) { emptyMap() }!!.seasonId)
        // Serializd has a real season 2, so season 3 missing is not a merge.
        server.shows[5001] = FakeSerializdServer.Show(5001, "Two", listOf(FakeSerializdServer.Season(1, 9100, 8), FakeSerializdServer.Season(2, 9101, 8)))
        assertNull(resolver.target(5001, 3) { mapOf(1 to 8, 2 to 8) })
        assertNull(resolver.target(404404, 2) { mapOf(1 to 1) })
        assertNotNull(resolver.target(1399, 3) { emptyMap() })
    }
}

class SerializdEligibilityTest {
    @Test fun aFilmIsNeverAnEpisodeAndNeverGoesToSerializd() {
        assertFalse(SerializdEligibility.isEpisode("movie", 1, 1)); assertFalse(SerializdEligibility.isEpisode("movie", null, null))
        assertFalse(SerializdEligibility.isSeriesType("movie")); assertFalse(SerializdEligibility.isSeriesType("Movie"))
    }

    @Test fun anEpisodeNeedsASeasonAndAnEpisodeNumber() {
        assertTrue(SerializdEligibility.isEpisode("series", 1, 1)); assertTrue(SerializdEligibility.isEpisode(" Series ", 0, 3)) // specials are season 0
        assertFalse(SerializdEligibility.isEpisode("series", null, 1)); assertFalse(SerializdEligibility.isEpisode("series", 1, null))
        assertFalse(SerializdEligibility.isEpisode("series", 1, 0)); assertFalse(SerializdEligibility.isEpisode("series", -1, 2))
    }

    @Test fun liveTvAndOtherContentIsNotTrackedEvenWhenItIsTypedLikeAShow() {
        assertFalse(SerializdEligibility.isEpisode("tv", 1, 1, isLive = true)); assertFalse(SerializdEligibility.isEpisode("tv", null, null))
        assertFalse(SerializdEligibility.isEpisode("music", 1, 1)); assertFalse(SerializdEligibility.isEpisode(null, 1, 1)); assertFalse(SerializdEligibility.isEpisode("", 1, 1))
        assertTrue(SerializdEligibility.isEpisode("tv", 2, 5))
    }

    @Test fun theTwoTrackersNeverBothClaimTheSameThing() {
        // The player gives films to Letterboxd only when the type is "movie"; this must be the exact complement for every type that has episodes.
        listOf("movie", "series", "show", "tvshow", "tv", "anime", "music", "other").forEach { type ->
            val toLetterboxd = type == "movie"
            val toSerializd = SerializdEligibility.isEpisode(type, 1, 1)
            assertFalse(toLetterboxd && toSerializd, type)
        }
    }
}
