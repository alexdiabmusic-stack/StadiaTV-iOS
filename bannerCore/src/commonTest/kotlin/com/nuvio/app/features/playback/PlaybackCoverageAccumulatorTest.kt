package com.nuvio.app.features.playback

import com.nuvio.app.features.letterboxd.WatchedCoverage
import kotlin.test.Test
import kotlin.test.assertEquals

class PlaybackCoverageAccumulatorTest {
    @Test fun steadyPlaybackAccumulates() {
        val acc = PlaybackCoverageAccumulator()
        var wall = 1_000_000L
        var pos = 0L
        repeat(30) { acc.onSample(pos, true, wall); wall += 1_000; pos += 1_000 }
        // 29 one-second steps merge into one stretch.
        assertEquals(29_000L, acc.coverage.totalMs)
    }

    @Test fun aSeekIsAJumpNotWatching() {
        val acc = PlaybackCoverageAccumulator()
        acc.onSample(0, true, 1_000_000)
        acc.onSample(1_000, true, 1_001_000)
        acc.onSample(7_500_000, true, 1_002_000) // dragged to the end one second later
        acc.onSample(7_501_000, true, 1_003_000)
        assertEquals(2_000L, acc.coverage.totalMs) // 0-1s, then 7500-7501s; the jump itself adds nothing
    }

    @Test fun pausedTimeAddsNothing() {
        val acc = PlaybackCoverageAccumulator()
        acc.onSample(10_000, false, 1_000_000)
        acc.onSample(10_000, false, 1_001_000)
        acc.onSample(10_000, false, 1_002_000)
        assertEquals(0L, acc.coverage.totalMs)
    }

    @Test fun playbackAtDoubleSpeedStillCounts() {
        val acc = PlaybackCoverageAccumulator()
        acc.onSample(0, true, 1_000_000)
        acc.onSample(2_000, true, 1_001_000) // two seconds of video in one wall second
        assertEquals(2_000L, acc.coverage.totalMs)
    }

    @Test fun aGapInSamplesDoesNotCreditTheMissingTime() {
        val acc = PlaybackCoverageAccumulator()
        acc.onSample(0, true, 1_000_000)
        acc.onSample(60_000, true, 1_060_000) // the app slept for a minute
        assertEquals(0L, acc.coverage.totalMs)
    }

    @Test fun interruptingStartsTheNextSampleFresh_andCoverageCarriesAcrossSessions() {
        val acc = PlaybackCoverageAccumulator(WatchedCoverage().add(0, 60_000))
        acc.onSample(100_000, true, 1_000_000)
        acc.onInterrupted()
        acc.onSample(500_000, true, 2_000_000) // a stream switch: not a step from 100_000
        assertEquals(60_000L, acc.coverage.totalMs)
        acc.onSample(501_000, true, 2_001_000)
        assertEquals(61_000L, acc.coverage.totalMs)
    }
}
