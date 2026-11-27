package com.nuvio.app.features.playback

/** What the end-of-playback layer is doing. Exactly one at a time, so overlays can never conflict. */
enum class PostPlayState {
    NormalPlayback,
    SkippableSegment,
    CreditsEligible,
    NextEpisodePreparing,
    NextEpisodeReady,
    NextEpisodeCountdown,
    WatchCredits,
    ProtectedScene,
    MovieRecommendation,
    SeriesCompletionRecommendation,
    StillWatching,
    Transitioning,
    PlaybackFinished,
}

enum class NextEpisodeAvailability {
    /** There is no following episode (the last one released). */
    NONE,

    /** A following episode exists but has not been released. */
    NOT_RELEASED,

    /** A released episode exists and a source is still being found. */
    PREPARING,

    /** A released episode exists and a playable source is ready. */
    READY,
}

/** Everything the decision reads. The player fills it in once a second or on a change; nothing here touches the engine. */
data class PostPlayInput(
    val isMovie: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    val isEnded: Boolean,
    /** Validated segments for the video that is playing. */
    val segments: List<PlaybackSegment> = emptyList(),

    /** Episodes: the existing "time for the next-episode card" rule (credits, threshold, post-credits aware), computed by the caller. */
    val atNextEpisodeThreshold: Boolean = false,

    /** Movies: the end-of-movie stage (see [MovieEndingStage]). */
    val movieStage: Int = MovieEndingStage.NONE,
    val nextEpisode: NextEpisodeAvailability = NextEpisodeAvailability.NONE,
    val autoplayNextEpisode: Boolean = false,
    val countdownMs: Long = 5_000L,

    /** When a source became ready for the next episode; null if it has not. The countdown runs from here. */
    val nextEpisodeReadySinceMs: Long? = null,
    val nowMs: Long = 0L,
    val hasMovieRecommendation: Boolean = false,

    /** The viewer pressed "Watch Credits" for this media session. Sticky: not cleared by EOF, rewinding or another overlay. */
    val watchCreditsChosen: Boolean = false,
    val movieRecommendationDismissed: Boolean = false,
    val stillWatchingPending: Boolean = false,
    val transitioning: Boolean = false,

    /** Playback error, a subtitle or settings sheet, scrubbing, picture in picture, casting, a watch party that owns the controls. */
    val interrupted: Boolean = false,

    /** Whether the last episode of the series (nothing more is coming) rather than just of the season. */
    val isSeriesFinale: Boolean = false,
    val hasSeriesRecommendation: Boolean = false,
)

data class PostPlayDecision(
    val state: PostPlayState,
    /** Milliseconds left of the next-episode countdown while it runs. */
    val countdownRemainingMs: Long? = null,
    /** 0 to 1: how much of the Next Episode button the countdown has filled. */
    val countdownProgress: Float? = null,
    /** True when this decision starts the next episode now (the countdown reached zero). */
    val startNextEpisode: Boolean = false,
    /** Whether the player may begin any automatic takeover at this moment. */
    val automaticTakeoverAllowed: Boolean = true,
)

object PostPlayStateMachine {
    fun decide(input: PostPlayInput): PostPlayDecision {
        val duration = input.durationMs
        val inScene = ProtectedScenePolicy.isInsideProtectedScene(input.positionMs, input.segments, duration)
        val takeoverAllowed = ProtectedScenePolicy.automaticTakeoverAllowed(input.positionMs, input.segments, duration)

        // Anything that already owns the screen wins: no end-of-playback overlay competes with it.
        if (input.transitioning) return PostPlayDecision(PostPlayState.Transitioning, automaticTakeoverAllowed = false)
        if (input.interrupted) return PostPlayDecision(PostPlayState.NormalPlayback, automaticTakeoverAllowed = false)
        if (input.stillWatchingPending) return PostPlayDecision(PostPlayState.StillWatching, automaticTakeoverAllowed = false)
        if (inScene) return PostPlayDecision(PostPlayState.ProtectedScene, automaticTakeoverAllowed = false)

        val decision = if (input.isMovie) decideMovie(input, takeoverAllowed) else decideEpisode(input, takeoverAllowed)
        // Whatever the branch, a protected scene that is playing or still to come holds every automatic takeover back.
        return decision.copy(automaticTakeoverAllowed = decision.automaticTakeoverAllowed && takeoverAllowed)
    }

    private fun decideMovie(input: PostPlayInput, takeoverAllowed: Boolean): PostPlayDecision {
        if (input.watchCreditsChosen) return PostPlayDecision(PostPlayState.WatchCredits, automaticTakeoverAllowed = false)
        val stage = if (takeoverAllowed) input.movieStage else MovieEndingStage.NONE
        return when {
            // The end always counts, even for a viewer who dismissed the card earlier.
            input.isEnded && input.hasMovieRecommendation -> PostPlayDecision(PostPlayState.MovieRecommendation)
            input.isEnded -> PostPlayDecision(PostPlayState.PlaybackFinished)
            stage > MovieEndingStage.NONE && input.hasMovieRecommendation && !input.movieRecommendationDismissed ->
                PostPlayDecision(PostPlayState.MovieRecommendation)
            stage > MovieEndingStage.NONE -> PostPlayDecision(PostPlayState.CreditsEligible, automaticTakeoverAllowed = takeoverAllowed)
            skippable(input) -> PostPlayDecision(PostPlayState.SkippableSegment)
            else -> PostPlayDecision(PostPlayState.NormalPlayback)
        }
    }

    private fun decideEpisode(input: PostPlayInput, takeoverAllowed: Boolean): PostPlayDecision {
        val eligible = takeoverAllowed && (input.atNextEpisodeThreshold || input.isEnded)
        if (!eligible) {
            return when {
                skippable(input) -> PostPlayDecision(PostPlayState.SkippableSegment)
                else -> PostPlayDecision(PostPlayState.NormalPlayback)
            }
        }
        // Past the credits start. With nothing to play next, the end of the series gets a recommendation instead of a dead card.
        if (input.nextEpisode == NextEpisodeAvailability.NONE || input.nextEpisode == NextEpisodeAvailability.NOT_RELEASED) {
            return when {
                input.isEnded && input.isSeriesFinale && input.hasSeriesRecommendation -> PostPlayDecision(PostPlayState.SeriesCompletionRecommendation)
                input.isEnded -> PostPlayDecision(PostPlayState.PlaybackFinished)
                else -> PostPlayDecision(PostPlayState.CreditsEligible, automaticTakeoverAllowed = takeoverAllowed)
            }
        }
        // Watch Credits is the viewer's explicit choice for this session: no countdown and no automatic start, even at the
        // end of the file; the Next Episode action stays available.
        if (input.watchCreditsChosen) return PostPlayDecision(PostPlayState.WatchCredits, automaticTakeoverAllowed = false)

        return when (input.nextEpisode) {
            NextEpisodeAvailability.PREPARING -> PostPlayDecision(PostPlayState.NextEpisodePreparing)
            NextEpisodeAvailability.READY -> readyDecision(input)
            else -> PostPlayDecision(PostPlayState.CreditsEligible)
        }
    }

    private fun readyDecision(input: PostPlayInput): PostPlayDecision {
        // With autoplay off there is no countdown at all: the manual Next Episode action just waits.
        if (!input.autoplayNextEpisode) return PostPlayDecision(PostPlayState.NextEpisodeReady)
        val since = input.nextEpisodeReadySinceMs ?: return PostPlayDecision(PostPlayState.NextEpisodeReady, countdownProgress = 0f)
        val elapsed = (input.nowMs - since).coerceAtLeast(0L)
        val total = input.countdownMs.coerceAtLeast(1L)
        val remaining = (total - elapsed).coerceAtLeast(0L)
        return if (remaining == 0L) {
            PostPlayDecision(PostPlayState.NextEpisodeCountdown, 0L, 1f, startNextEpisode = true)
        } else {
            PostPlayDecision(PostPlayState.NextEpisodeCountdown, remaining, (elapsed.toFloat() / total.toFloat()).coerceIn(0f, 1f))
        }
    }

    private fun skippable(input: PostPlayInput): Boolean {
        val duration = input.durationMs
        return input.segments.any {
            it.type.isSkippable && it.type != PlaybackSegmentType.CREDITS && it.contains(input.positionMs, duration)
        }
    }
}

/**
 * "Are you still watching?": after a number of episodes in a row that started on their own with no real interaction from the
 * viewer, ask before starting the next one. Netflix's documented reference is three episodes (plus, on TV, ninety minutes);
 * BannerTV's defaults are the same and configurable. Automatic intro skipping is not interaction.
 */
class UnattendedViewingTracker(
    private val episodeLimit: Int = 3,
    private val tvMinutesLimit: Long = 90L,
    private val isTelevision: Boolean = false,
) {
    private var autoAdvanced = 0
    private var lastInteractionMs: Long? = null
    private var firstUnattendedMs: Long? = null

    /** The viewer did something on purpose: pressed play or pause, sought, skipped, chose an episode, used the controls or the remote. */
    fun onInteraction(nowMs: Long) {
        autoAdvanced = 0
        lastInteractionMs = nowMs
        firstUnattendedMs = null
    }

    /** The next episode started by itself (autoplay), with no one asking. */
    fun onEpisodeAutoAdvanced(nowMs: Long) {
        if (autoAdvanced == 0) firstUnattendedMs = nowMs
        autoAdvanced++
    }

    /** Whether to ask now, at an episode boundary, before an automatic start. */
    fun shouldPrompt(nowMs: Long): Boolean {
        if (autoAdvanced < episodeLimit) return false
        if (!isTelevision) return true
        val start = firstUnattendedMs ?: return false
        return nowMs - start >= tvMinutesLimit * 60_000L
    }

    /** "Continue Watching": starts the count again. */
    fun onContinue(nowMs: Long) = onInteraction(nowMs)

    val unattendedEpisodes: Int get() = autoAdvanced
}
