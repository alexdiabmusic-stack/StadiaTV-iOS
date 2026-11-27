package com.nuvio.app.features.player.skip

import com.nuvio.app.core.ui.TvDevice
import com.nuvio.app.features.playback.UnattendedViewingTracker
import com.nuvio.app.features.watchprogress.WatchProgressClock

/** The app's one count of episodes that started on their own, kept across episodes within a viewing session. */
internal object UnattendedViewing {
    private var tracker = UnattendedViewingTracker(isTelevision = TvDevice.isTelevision)
    private var lastActivityMs = 0L

    private fun trackerFor(now: Long): UnattendedViewingTracker {
        // A long gap means a different sitting: start counting from nothing rather than prompting about last night.
        if (lastActivityMs != 0L && now - lastActivityMs > SESSION_GAP_MS) tracker = UnattendedViewingTracker(isTelevision = TvDevice.isTelevision)
        lastActivityMs = now
        return tracker
    }

    fun noteInteraction() = trackerFor(WatchProgressClock.nowEpochMs()).onInteraction(WatchProgressClock.nowEpochMs())
    fun noteAutoAdvanced() = trackerFor(WatchProgressClock.nowEpochMs()).onEpisodeAutoAdvanced(WatchProgressClock.nowEpochMs())
    fun shouldPrompt(): Boolean = trackerFor(WatchProgressClock.nowEpochMs()).shouldPrompt(WatchProgressClock.nowEpochMs())
    fun onContinue() = trackerFor(WatchProgressClock.nowEpochMs()).onContinue(WatchProgressClock.nowEpochMs())

    private const val SESSION_GAP_MS = 6 * 60 * 60 * 1000L
}
