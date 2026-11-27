package com.nuvio.app.features.player.skip

import com.nuvio.app.features.playback.PlaybackSegment
import com.nuvio.app.features.playback.PlaybackSegmentType
import com.nuvio.app.features.playback.PlaybackSegments
import com.nuvio.app.features.playback.ProtectedScenePolicy
import com.nuvio.app.features.playback.SegmentMatchQuality
import com.nuvio.app.features.playback.SegmentReliability
import com.nuvio.app.features.playback.reliability
import com.nuvio.app.features.playback.SegmentMediaContext
import com.nuvio.app.features.playback.SegmentSource

/**
 * The typed view of a [SkipInterval]. The raw `type` string is what providers and the player have always carried; every
 * decision about what it means goes through here so the aliases cannot drift apart between call sites.
 */
val SkipInterval.segmentType: PlaybackSegmentType get() = PlaybackSegmentType.fromRaw(type)

/** An end credits segment (an episode's outro/ED or a movie's credits). Never an opening. */
fun SkipInterval.isCredits(): Boolean = segmentType == PlaybackSegmentType.CREDITS

/** The raw type says the marker was made for a movie's credits (the provider's own movie/episode distinction). */
val SkipInterval.isMovieCredits: Boolean get() = type.trim().lowercase().replace('_', '-') == MOVIE_CREDITS_TYPE

/** A mid- or post-credits scene: shown, never skipped through. */
fun SkipInterval.isProtectedScene(): Boolean = segmentType.isProtectedScene

/** The skip-button category used to merge providers: one opening, one ending, one recap per title (null for anything else). */
fun skipSegmentCategory(type: String): String? = when (PlaybackSegmentType.fromRaw(type)) {
    PlaybackSegmentType.INTRO -> "opening"
    PlaybackSegmentType.CREDITS -> "ending"
    PlaybackSegmentType.RECAP -> "recap"
    else -> null
}

/**
 * Converts to the shared segment contract. Returns null for times that cannot be milliseconds (NaN, negative start). The
 * `Double.MAX_VALUE` end some providers use for "to the end" becomes an open end.
 */
fun SkipInterval.toPlaybackSegment(): PlaybackSegment? {
    val source = SegmentSource.fromProvider(provider)
    val context = when {
        isMovieCredits -> SegmentMediaContext.MOVIE
        source == SegmentSource.ANIME_SKIP || source == SegmentSource.ANISKIP -> SegmentMediaContext.ANIME_EPISODE
        else -> SegmentMediaContext.UNKNOWN
    }
    // IntroDB, Anime-Skip and AniSkip key their data by title/episode and never compare durations.
    val quality = matchQuality ?: when (source) {
        SegmentSource.INTRODB, SegmentSource.ANIME_SKIP, SegmentSource.ANISKIP -> SegmentMatchQuality.DURATION_AGNOSTIC
        SegmentSource.CHAPTERS, SegmentSource.USER_CORRECTION -> SegmentMatchQuality.EXACT_EDITION
        else -> SegmentMatchQuality.UNKNOWN
    }
    return PlaybackSegment.fromSeconds(
        type = segmentType,
        startSeconds = startTime,
        endSeconds = endTime,
        source = source,
        confidence = confidence,
        matchQuality = quality,
        mediaContext = context,
    )
}

/**
 * Where the end credits first begin, from skip data. Movie credits, episode outros and chapter endings all count; a credits
 * marker that cannot fit the runtime (when [durationMs] is known) does not.
 */
fun List<SkipInterval>.creditsStartMs(durationMs: Long = 0L): Long? =
    PlaybackSegments.creditsStartMs(mapNotNull { it.toPlaybackSegment() }, durationMs)

/**
 * Whether an automatic takeover (end-of-movie recommendation, next-episode transition) may start at [positionMs]: not while
 * a protected scene is playing or still to come. A scene that cannot fit the runtime is ignored, not trusted.
 */
fun List<SkipInterval>.automaticTakeoverAllowed(positionMs: Long, durationMs: Long): Boolean {
    val segments = PlaybackSegments.validFor(mapNotNull { it.toPlaybackSegment() }, durationMs)
    return ProtectedScenePolicy.automaticTakeoverAllowed(positionMs, segments, durationMs)
}

/**
 * Whether this marker may be used without the viewer asking (auto-skip): valid, trusted data that is not a loose match.
 * Low-confidence and approximate markers still show a Skip button.
 */
fun SkipInterval.isTrustedForAutomaticAction(): Boolean {
    val segment = toPlaybackSegment() ?: return false
    return segment.reliability() == SegmentReliability.VERIFIED &&
        segment.matchQuality != SegmentMatchQuality.DURATION_APPROXIMATE
}

/** The player's carrier for a segment. The `Double.MAX_VALUE` end keeps meaning "to the end". Previews are not surfaced as skips. */
fun PlaybackSegment.toSkipInterval(provider: String): SkipInterval? {
    val label = when (type) {
        PlaybackSegmentType.INTRO -> "intro"
        PlaybackSegmentType.RECAP -> "recap"
        PlaybackSegmentType.CREDITS -> if (mediaContext == SegmentMediaContext.MOVIE) MOVIE_CREDITS_TYPE else "outro"
        PlaybackSegmentType.MID_CREDITS_SCENE -> "mid-credits"
        PlaybackSegmentType.POST_CREDITS_SCENE -> "post-credits"
        PlaybackSegmentType.NEXT_EPISODE_PREVIEW, PlaybackSegmentType.UNKNOWN -> return null
    }
    return SkipInterval(
        startTime = startMs / 1000.0,
        endTime = endMs?.let { it / 1000.0 } ?: Double.MAX_VALUE,
        type = label,
        provider = provider,
        confidence = confidence,
        matchQuality = matchQuality,
    )
}

private const val MOVIE_CREDITS_TYPE = "movie-credits"
