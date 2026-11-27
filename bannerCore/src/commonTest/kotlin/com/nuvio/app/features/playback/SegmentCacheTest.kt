package com.nuvio.app.features.playback

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

class SegmentCacheTest {
    private var now = 1_000_000L
    private fun cache(max: Int = 3) = SegmentCache<String>(max, ttlMs = 1_000, negativeTtlMs = 400, staleGraceMs = 2_000, clock = { now })

    @Test fun aStoredAnswerIsReturnedUntilItExpires() {
        val c = cache(); c.put("k", "v")
        assertEquals("v", assertIs<SegmentCacheResult.Hit<String>>(c.get("k")).value)
        now += 900
        assertFalse(assertIs<SegmentCacheResult.Hit<String>>(c.get("k")).stale)
    }

    @Test fun anExpiredAnswerIsStaleInsideTheGraceWindowThenGone() {
        val c = cache(); c.put("k", "v")
        now += 1_500
        assertTrue(assertIs<SegmentCacheResult.Hit<String>>(c.get("k")).stale)
        now += 2_000
        assertIs<SegmentCacheResult.Miss>(c.get("k"))
    }

    @Test fun aNothingFoundAnswerExpiresSoonerAndHasNoStaleWindow() {
        val c = cache(); c.putNegative("k")
        assertIs<SegmentCacheResult.NegativeHit>(c.get("k"))
        now += 500
        assertIs<SegmentCacheResult.Miss>(c.get("k"))
    }

    @Test fun theLeastRecentlyUsedEntryIsEvictedFirst() {
        val c = cache(3)
        c.put("a", "1"); c.put("b", "2"); c.put("c", "3")
        c.get("a") // a is now the most recently used
        c.put("d", "4")
        assertEquals(3, c.size)
        assertIs<SegmentCacheResult.Miss>(c.get("b"))
        assertIs<SegmentCacheResult.Hit<String>>(c.get("a"))
    }

    @Test fun differentEditionsAndDurationsDoNotShareAnEntry() {
        val base = SegmentCache.key("skip", "tt0111161")
        assertFalse(base == SegmentCache.key("skip", "tt0111161", editionIdentity = "extended"))
        assertFalse(SegmentCache.key("skip", "tt0903747", 1, 1, durationSeconds = 2820) == SegmentCache.key("skip", "tt0903747", 1, 1, durationSeconds = 2400))
        assertEquals(SegmentCache.key("skip", "tt0903747", 1, 2), SegmentCache.key("skip", "TT0903747", 1, 2))
    }

    @Test fun keysNeverCarryUrlsTokensOrCredentials() {
        val dirty = SegmentCache.key("skip", "https://cdn.example/video.mkv?token=SECRET&sig=abc", editionIdentity = "tok@secret?x=1")
        assertFalse(dirty.contains("SECRET", ignoreCase = true))
        assertFalse(dirty.contains("sig=")); assertFalse(dirty.contains("://")); assertFalse(dirty.contains("?"))
    }

    @Test fun removeAndClearEmptyTheCache() {
        val c = cache(); c.put("a", "1"); c.put("b", "2")
        c.remove("a"); assertEquals(1, c.size)
        c.clear(); assertEquals(0, c.size)
    }
}
