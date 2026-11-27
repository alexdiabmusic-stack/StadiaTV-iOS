package com.nuvio.app.features.player.skip

import com.nuvio.app.features.playback.PlaybackSegmentType

enum class AutoSkipSegmentType(val storedValue: String) {
    INTRO("intro"),
    RECAP("recap"),
    OUTRO("outro"),
    MOVIE_CREDITS("movie-credits");

    companion object {
        fun fromStoredValue(value: String): AutoSkipSegmentType? =
            entries.firstOrNull { it.storedValue == value }

        fun fromSkipIntervalType(type: String): AutoSkipSegmentType? = when (PlaybackSegmentType.fromRaw(type)) {
            PlaybackSegmentType.INTRO -> INTRO
            PlaybackSegmentType.RECAP -> RECAP
            // A movie's credits keep their own switch (a viewer may auto-skip episode outros but not film credits).
            PlaybackSegmentType.CREDITS -> if (type.trim().lowercase().replace('_', '-') == "movie-credits") MOVIE_CREDITS else OUTRO
            else -> null
        }
    }
}

internal fun SkipInterval.shouldAutoSkip(selectedTypes: Set<AutoSkipSegmentType>): Boolean =
    startTime.isFinite() && endTime.isFinite() && startTime >= 0 && endTime > startTime &&
        AutoSkipSegmentType.fromSkipIntervalType(type) in selectedTypes &&
        // Loose or low-confidence markers (an out-of-range SkipDB match, a 0.2-confidence guess) only ever get a button.
        isTrustedForAutomaticAction()

internal fun List<SkipInterval>.intervalsAtSeekPositions(fromMs: Long, toMs: Long): List<SkipInterval> =
    filter { interval ->
        AutoSkipSegmentType.fromSkipIntervalType(interval.type) != null &&
            listOf(fromMs, toMs).any { position ->
                val seconds = position / 1000.0
                seconds >= interval.startTime && seconds < interval.endTime
            }
    }
