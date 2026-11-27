package com.nuvio.app.features.playback

/**
 * How far a movie is into its ending, for the end-of-movie recommendation: [NONE] not yet, [FIRST] credits rolling (or the
 * last four minutes when no credits are known), [FINAL] the last thirty seconds, [ENDED] playback finished.
 *
 * A protected scene (mid- or post-credits) holds the recommendation back until it has played: the card never lands on a
 * scene the viewer may want, and when the player reports the end it always appears.
 */
object MovieEndingStage {
    const val NONE = 0
    const val FIRST = 1
    const val FINAL = 2
    const val ENDED = 3

    private const val CREDITS_DELAY_MS = 4_000L
    private const val FIRST_WINDOW_MS = 4L * 60_000L
    private const val FINAL_WINDOW_MS = 30_000L

    fun stage(
        positionMs: Long,
        durationMs: Long,
        isEnded: Boolean,
        creditsStartMs: Long? = null,
        protectedSceneAhead: Boolean = false,
    ): Int {
        if (isEnded) return ENDED
        if (durationMs <= 0L) return NONE
        if (protectedSceneAhead) return NONE
        val remainingMs = durationMs - positionMs
        return when {
            remainingMs <= FINAL_WINDOW_MS -> FINAL
            // When the credits are known the card floats in a few seconds after they roll, not on a "minutes left" guess.
            creditsStartMs != null -> if (positionMs >= creditsStartMs + CREDITS_DELAY_MS) FIRST else NONE
            remainingMs <= FIRST_WINDOW_MS -> FIRST
            else -> NONE
        }
    }
}
