package com.nuvio.app.features.playback

import com.nuvio.app.features.letterboxd.WatchedCoverage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CompletionEventsTest {
    private fun m(min: Int, sec: Int = 0) = (min * 60L + sec) * 1000L
    private val duration = m(130)
    private val credits = PlaybackSegment(PlaybackSegmentType.CREDITS, m(121), null, SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)

    private fun event(session: String = "s1", viewing: Int = 0, profile: Int = 1, key: String = "movie:tt1", ep: String? = null) =
        PlaybackCompletionEvent(profile, key, ep, session, PlaybackCompletionReason.NARRATIVE_COMPLETE, 1_000L, 0.9, m(121), viewing)

    /** Plays [minutes] of steady playback from [from], one sample per second. */
    private fun PlaybackSessionTracker.play(fromMs: Long, toMs: Long, wallStart: Long = 10_000_000L): PlaybackCompletionEvent? {
        var wall = wallStart; var pos = fromMs; var out: PlaybackCompletionEvent? = null
        while (pos <= toMs) { out = onSample(pos, duration, true, false, wall) ?: out; pos += 1_000; wall += 1_000 }
        return out
    }

    @Test fun theSameViewingIsRecordedOnce_whateverSessionReportsIt() {
        val ledger = CompletionLedger(InMemoryPlaybackStateStore())
        assertIs<CompletionRecord.Recorded>(ledger.record(event("s1")))
        assertIs<CompletionRecord.Duplicate>(ledger.record(event("s2-after-engine-fallback")))
        assertIs<CompletionRecord.Duplicate>(ledger.record(event("s1")))
        assertEquals(1, ledger.nextViewingIndex(1, "movie:tt1", null))
    }

    @Test fun aRewatchIsANewViewingAndKeepsHistory() {
        val ledger = CompletionLedger(InMemoryPlaybackStateStore())
        ledger.record(event(viewing = 0))
        assertIs<CompletionRecord.Recorded>(ledger.record(event("s9", viewing = ledger.nextViewingIndex(1, "movie:tt1", null))))
        assertEquals(2, ledger.nextViewingIndex(1, "movie:tt1", null))
    }

    @Test fun profilesAndEpisodesAreSeparate() {
        val ledger = CompletionLedger(InMemoryPlaybackStateStore())
        ledger.record(event(profile = 1, key = "series:tt9", ep = "s1e1"))
        assertTrue(ledger.hasCompleted(1, "series:tt9", "s1e1"))
        assertFalse(ledger.hasCompleted(2, "series:tt9", "s1e1"))
        assertFalse(ledger.hasCompleted(1, "series:tt9", "s1e2"))
    }

    @Test fun externalSyncIsQueuedPerProvider_andOneFailingProviderDoesNotTouchAnother() {
        val ledger = CompletionLedger(InMemoryPlaybackStateStore())
        val e = event()
        ledger.record(e, providers = setOf("trakt", "letterboxd"))
        assertEquals(listOf(e.eventId), ledger.pendingFor("trakt").map { it.eventId })
        ledger.markSynced("letterboxd", e.eventId) // Trakt is down: its entry simply stays
        assertEquals(1, ledger.pendingFor("trakt").size)
        assertTrue(ledger.pendingFor("letterboxd").isEmpty())
        // The local completion was never held back by either.
        assertTrue(ledger.hasCompleted(1, "movie:tt1", null))
    }

    @Test fun aDuplicateEventQueuesNothingTwice() {
        val ledger = CompletionLedger(InMemoryPlaybackStateStore())
        ledger.record(event(), setOf("trakt")); ledger.record(event("again"), setOf("trakt"))
        assertEquals(1, ledger.pendingFor("trakt").size)
    }

    @Test fun theLedgerSurvivesARestart() {
        val backing = InMemoryPlaybackStateStore()
        CompletionLedger(backing).record(event(), setOf("trakt"))
        val reopened = CompletionLedger(backing)
        assertTrue(reopened.hasCompleted(1, "movie:tt1", null))
        assertEquals(1, reopened.pendingFor("trakt").size)
        assertIs<CompletionRecord.Duplicate>(reopened.record(event()))
    }

    @Test fun coverageCarriesBetweenSessionsAndClearsAfterCompletion() {
        val backing = InMemoryPlaybackStateStore(); val store = CoverageStore(backing)
        store.save(1, "movie:tt1", null, WatchedCoverage().add(0, m(60)))
        assertEquals(m(60), store.load(1, "movie:tt1", null).totalMs)
        assertEquals(0L, store.load(2, "movie:tt1", null).totalMs) // another profile
        store.clear(1, "movie:tt1", null)
        assertEquals(0L, CoverageStore(backing).load(1, "movie:tt1", null).totalMs)
    }

    @Test fun aSessionEmitsExactlyOneEventWhenTheNarrativeIsWatched() {
        val tracker = PlaybackSessionTracker("s1", 1, "movie:tt1", null, 0)
        tracker.updateSegments(listOf(credits))
        val ev = assertNotNull(tracker.play(0, m(122)))
        assertEquals(PlaybackCompletionReason.NARRATIVE_COMPLETE, ev.reason)
        assertEquals(0, ev.viewingIndex); assertEquals(m(121), ev.narrativeEndMs)
        assertNull(tracker.play(m(122) + 1_000, m(124), wallStart = 99_000_000L)) // already emitted
    }

    @Test fun seekingToTheEndNeverEmits() {
        val tracker = PlaybackSessionTracker("s1", 1, "movie:tt1", null, 0)
        tracker.updateSegments(listOf(credits))
        tracker.onSample(0, duration, true, false, 1_000_000)
        assertNull(tracker.onSample(m(128), duration, true, false, 1_001_000))
        assertNull(tracker.onSample(duration, duration, false, true, 1_002_000))
    }

    @Test fun anEngineSwitchMidFilmKeepsTheCoverage_andStillCompletes() {
        val tracker = PlaybackSessionTracker("s1", 1, "movie:tt1", null, 0)
        tracker.updateSegments(listOf(credits))
        assertNull(tracker.play(0, m(60)))
        tracker.onInterrupted() // AetherEngine failed; libmpv takes over at the same position
        val ev = assertNotNull(tracker.play(m(60), m(122), wallStart = 50_000_000L))
        assertEquals("s1", ev.sessionId) // not an unrelated new viewing
    }

    @Test fun aSessionResumedFromStoredCoverageCompletesWithoutWatchingEverythingAgain() {
        val tracker = PlaybackSessionTracker("s2", 1, "movie:tt1", null, 0, initialCoverage = WatchedCoverage().add(0, m(100)))
        tracker.updateSegments(listOf(credits))
        assertNotNull(tracker.play(m(100), m(121, 30)))
    }
}

class SkippedOpeningCreditTest {
    private fun m(min: Int, sec: Int = 0) = (min * 60L + sec) * 1000L
    private val duration = m(45)
    private val intro = PlaybackSegment(PlaybackSegmentType.INTRO, m(1), m(2), SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)
    private val credits = PlaybackSegment(PlaybackSegmentType.CREDITS, m(42), null, SegmentSource.INTRODB, matchQuality = SegmentMatchQuality.DURATION_AGNOSTIC)

    private fun tracker() = PlaybackSessionTracker("s", 1, "series:tt1", "s1e1", 0).also { it.updateSegments(listOf(intro, credits)) }

    private fun PlaybackSessionTracker.watch(from: Long, to: Long, wall: Long): Long {
        var w = wall; var p = from
        while (p <= to) { onSample(p, duration, true, false, w); p += 1_000; w += 1_000 }
        return w
    }

    @Test fun pressingSkipIntroInsideTheIntroCreditsTheRestOfIt_andTheEpisodeStillCompletes() {
        val t = tracker()
        var wall = t.watch(0, m(1, 10), 1_000_000L)       // watch up to 1:10 (ten seconds into the intro)
        t.onSample(m(2), duration, true, false, wall + 1_000) // Skip Intro: jump to 2:00
        wall += 2_000
        t.watch(m(2), m(42, 5), wall)
        assertTrue(t.assess(m(42, 5), duration, false).completes)
    }

    @Test fun withoutTheCreditForTheSkippedIntroTheNarrativeCoverageIsStillHighEnoughHere_butTheCreditIsRecorded() {
        val t = tracker()
        val wall = t.watch(0, m(1, 10), 1_000_000L)
        t.onSample(m(2), duration, true, false, wall + 1_000)
        assertTrue(t.coverage.coveredIn(m(1, 10), m(2)) >= m(0, 49)) // the skipped stretch counts as seen
    }

    @Test fun jumpingOverTheWholeIntroFromBeforeItIsNotCredited() {
        val t = tracker()
        t.onSample(m(0, 30), duration, true, false, 1_000_000L)
        t.onSample(m(5), duration, true, false, 1_001_000L)
        assertEquals(0L, t.coverage.coveredIn(m(1), m(2)))
    }

    @Test fun steadyPlaybackAndBackwardSeeksCreditNothingExtra() {
        val t = tracker()
        t.watch(m(1), m(1, 30), 1_000_000L)
        val before = t.coverage.totalMs
        t.onSample(m(1, 10), duration, true, false, 1_040_000L) // backward
        assertEquals(before, t.coverage.totalMs)
    }

    @Test fun skippingTheCreditsIsNeverCreditedAsAnIntro() {
        val t = tracker()
        t.onSample(m(42), duration, true, false, 1_000_000L)
        t.onSample(m(44, 50), duration, true, false, 1_001_000L)
        assertEquals(0L, t.coverage.coveredIn(m(42), m(45)))
    }
}
