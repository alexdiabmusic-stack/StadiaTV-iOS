package com.nuvio.app.features.playback

enum class SkipTargetKind {
    /** The credits skip lands on a mid-credits scene. */
    BONUS_SCENE,

    /** The credits skip lands on a post-credits scene. */
    POST_CREDITS_SCENE,

    /** No protected scene is ahead; the skip runs to where the credits end, before the title's very end. */
    END_OF_CREDITS,

    /** No protected scene is ahead and the credits run to the end of the video. */
    END_OF_MEDIA,
}

data class SkipTarget(val targetMs: Long, val kind: SkipTargetKind)

/** Reads of a title's segments that other policies share. Every function expects segments already validated for the video. */
object PlaybackSegments {
    /**
     * Where the end credits first begin, or null when no valid credits segment is known. A credits segment that does not fit
     * the runtime (opening credits mislabelled as end credits) never counts.
     */
    fun creditsStartMs(segments: List<PlaybackSegment>, durationMs: Long): Long? =
        validFor(segments, durationMs).filter { it.type == PlaybackSegmentType.CREDITS }.minOfOrNull { it.startMs }

    /** The segments that pass [PlaybackSegmentValidator] for this video (all basic checks when the duration is unknown). */
    fun validFor(segments: List<PlaybackSegment>, durationMs: Long, editionIdentity: String? = null): List<PlaybackSegment> =
        segments.filter { PlaybackSegmentValidator.validate(it, durationMs.takeIf { d -> d > 0L }, editionIdentity) == null }

    /**
     * Cuts every credits segment around the protected scenes inside it, so credits that resume after a scene become their own
     * segment and no credits segment ever covers a scene. The scenes themselves are kept as they are.
     */
    fun creditsAroundScenes(segments: List<PlaybackSegment>, durationMs: Long): List<PlaybackSegment> {
        val scenes = segments.filter { it.type.isProtectedScene }.sortedBy { it.startMs }
        if (scenes.isEmpty()) return segments
        val result = ArrayList<PlaybackSegment>()
        for (segment in segments) {
            if (segment.type != PlaybackSegmentType.CREDITS) { result += segment; continue }
            var cursor = segment.startMs
            val end = segment.resolvedEndMs(durationMs)
            var open = true
            for (scene in scenes) {
                val sceneEnd = scene.resolvedEndMs(durationMs)
                if (sceneEnd <= cursor || scene.startMs >= end) continue
                if (scene.startMs > cursor) result += segment.copy(startMs = cursor, endMs = scene.startMs)
                cursor = maxOf(cursor, sceneEnd)
                if (cursor >= end) { open = false; break }
            }
            if (open && cursor < end) result += segment.copy(startMs = cursor, endMs = if (segment.endMs == null) null else end)
        }
        return result.sortedBy { it.startMs }
    }

    /**
     * Where an unexplained stretch after the last known credits or scene begins: video is left but no segment covers it.
     * It is reported as uncertain; nothing here says it is a bonus scene.
     */
    fun uncertainTailStartMs(segments: List<PlaybackSegment>, durationMs: Long, minTailMs: Long = 5_000L): Long? {
        if (durationMs <= 0L) return null
        val lastEnd = segments.filter { it.type == PlaybackSegmentType.CREDITS || it.type.isProtectedScene }
            .maxOfOrNull { it.resolvedEndMs(durationMs) } ?: return null
        return lastEnd.takeIf { durationMs - it > minTailMs }
    }
}

/**
 * Keeps automatic actions (skipping, Post-Play takeover) from crossing a scene the viewer may want. A protected scene is
 * a verified mid- or post-credits scene; they are never skipped through and they hold back any automatic takeover.
 */
object ProtectedScenePolicy {
    private fun scenes(segments: List<PlaybackSegment>) = segments.filter { it.type.isProtectedScene }

    fun isInsideProtectedScene(positionMs: Long, segments: List<PlaybackSegment>, durationMs: Long): Boolean =
        scenes(segments).any { it.contains(positionMs, durationMs) }

    /**
     * What the credits Skip button does at [positionMs]: null when the position is not in credits (or is inside a protected
     * scene, which is never skipped), the next protected scene when one is still ahead, else the end of the credits.
     */
    fun creditsSkipTarget(positionMs: Long, segments: List<PlaybackSegment>, durationMs: Long): SkipTarget? {
        if (isInsideProtectedScene(positionMs, segments, durationMs)) return null
        val credits = segments.filter { it.type == PlaybackSegmentType.CREDITS }
            .firstOrNull { it.contains(positionMs, durationMs) } ?: return null
        val nextScene = scenes(segments).filter { it.startMs > positionMs }.minByOrNull { it.startMs }
        if (nextScene != null) {
            val kind = if (nextScene.type == PlaybackSegmentType.POST_CREDITS_SCENE) SkipTargetKind.POST_CREDITS_SCENE else SkipTargetKind.BONUS_SCENE
            return SkipTarget(nextScene.startMs, kind)
        }
        val end = credits.resolvedEndMs(durationMs).coerceAtMost(if (durationMs > 0L) durationMs else Long.MAX_VALUE)
        val toEnd = durationMs > 0L && end >= durationMs - END_OF_MEDIA_SLACK_MS
        return SkipTarget(end, if (toEnd) SkipTargetKind.END_OF_MEDIA else SkipTargetKind.END_OF_CREDITS)
    }

    /**
     * Whether an automatic Post-Play takeover (next episode, recommendations) may begin at [positionMs]. Not while a
     * protected scene is playing or still to come; once the last one has finished (or there are none) it may.
     */
    fun automaticTakeoverAllowed(positionMs: Long, segments: List<PlaybackSegment>, durationMs: Long): Boolean =
        scenes(segments).none { it.resolvedEndMs(durationMs) > positionMs }

    private const val END_OF_MEDIA_SLACK_MS = 1_500L
}
