package com.nuvio.app.features.playback

import com.nuvio.app.features.letterboxd.WatchedCoverage
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.serializer

/** A small persistent string store. The shared core's key-value store implements it; tests use a map. */
interface PlaybackStateStore {
    fun get(store: String, key: String): String?
    fun put(store: String, key: String, value: String)
}

/** Memory-only store for tests and for hosts that have not registered a backend. */
class InMemoryPlaybackStateStore : PlaybackStateStore {
    private val map = HashMap<String, String>()
    override fun get(store: String, key: String): String? = map["$store/$key"]
    override fun put(store: String, key: String, value: String) { map["$store/$key"] = value }
}

/** One title finished, once, durably. Everything downstream (local history, Continue Watching, scrobbling) is driven by this. */
@Serializable
data class PlaybackCompletionEvent(
    val profileId: Int,
    /** Canonical media identity, e.g. `movie:tt0111161` or `series:tt0903747`. Never a URL. */
    val mediaKey: String,
    /** `s1e4`-style key for an episode; null for a movie. */
    val episodeKey: String?,
    val sessionId: String,
    val reason: PlaybackCompletionReason,
    val completedAtMs: Long,
    val coverageFraction: Double,
    /** Where the narrative ended (the credits start) when known. */
    val narrativeEndMs: Long?,
    /** Which viewing of this title this is: 0 the first time, 1 a rewatch, and so on. */
    val viewingIndex: Int,
) {
    /** The same viewing always has the same id, whichever session or engine reports it. */
    val eventId: String get() = "$profileId|$mediaKey|${episodeKey ?: "-"}|$viewingIndex"
}

sealed interface CompletionRecord {
    data class Recorded(val event: PlaybackCompletionEvent) : CompletionRecord

    /** This viewing was already recorded; nothing changes and nothing is sent twice. */
    data class Duplicate(val eventId: String) : CompletionRecord
}

/**
 * The record of completed viewings per profile, and of which external services still have to hear about each one.
 * [record] is idempotent per viewing. Local completion is recorded first and never waits on a provider: a service that is
 * down just leaves its entry pending for a later retry, and one provider failing does not touch another's state.
 */
class CompletionLedger(
    private val store: PlaybackStateStore,
    private val storeName: String = "playback_completion",
) {
    @Serializable
    private data class State(
        val completed: Map<String, Int> = emptyMap(),
        val events: List<PlaybackCompletionEvent> = emptyList(),
        /** provider -> event ids still to send. */
        val pending: Map<String, List<String>> = emptyMap(),
    )

    private val json = Json { ignoreUnknownKeys = true }
    private fun load(): State = store.get(storeName, STATE_KEY)?.let { runCatching { json.decodeFromString(State.serializer(), it) }.getOrNull() } ?: State()
    private fun save(state: State) = store.put(storeName, STATE_KEY, json.encodeToString(State.serializer(), state))

    private fun titleKey(profileId: Int, mediaKey: String, episodeKey: String?) = "$profileId|$mediaKey|${episodeKey ?: "-"}"

    /** How many times this profile has finished this title: the index the next viewing will carry. */
    fun nextViewingIndex(profileId: Int, mediaKey: String, episodeKey: String?): Int =
        load().completed[titleKey(profileId, mediaKey, episodeKey)] ?: 0

    fun hasCompleted(profileId: Int, mediaKey: String, episodeKey: String?): Boolean = nextViewingIndex(profileId, mediaKey, episodeKey) > 0

    /** Records the viewing and queues it for [providers]. Returns [CompletionRecord.Duplicate] if it was already recorded. */
    fun record(event: PlaybackCompletionEvent, providers: Set<String> = emptySet()): CompletionRecord {
        val state = load()
        if (state.events.any { it.eventId == event.eventId }) return CompletionRecord.Duplicate(event.eventId)
        val key = titleKey(event.profileId, event.mediaKey, event.episodeKey)
        val pending = state.pending.toMutableMap()
        for (provider in providers) pending[provider] = (pending[provider].orEmpty() + event.eventId)
        save(
            state.copy(
                completed = state.completed + (key to maxOf(state.completed[key] ?: 0, event.viewingIndex + 1)),
                events = (state.events + event).takeLast(MAX_EVENTS),
                pending = pending,
            ),
        )
        return CompletionRecord.Recorded(event)
    }

    /** Events a provider has not been told about yet, oldest first. */
    fun pendingFor(provider: String): List<PlaybackCompletionEvent> {
        val state = load()
        val ids = state.pending[provider].orEmpty().toSet()
        return state.events.filter { it.eventId in ids }
    }

    fun markSynced(provider: String, eventId: String) {
        val state = load()
        save(state.copy(pending = state.pending + (provider to state.pending[provider].orEmpty().filterNot { it == eventId })))
    }

    private companion object {
        const val STATE_KEY = "state"
        const val MAX_EVENTS = 500
    }
}

/** What has really played, kept between sessions so a film watched over two evenings is one viewing. */
class CoverageStore(private val store: PlaybackStateStore, private val storeName: String = "playback_coverage") {
    private val json = Json { ignoreUnknownKeys = true }
    private fun key(profileId: Int, mediaKey: String, episodeKey: String?) = "$profileId|$mediaKey|${episodeKey ?: "-"}"

    fun load(profileId: Int, mediaKey: String, episodeKey: String?): WatchedCoverage =
        store.get(storeName, key(profileId, mediaKey, episodeKey))
            ?.let { runCatching { json.decodeFromString(serializer<WatchedCoverage>(), it) }.getOrNull() } ?: WatchedCoverage()

    fun save(profileId: Int, mediaKey: String, episodeKey: String?, coverage: WatchedCoverage) =
        store.put(storeName, key(profileId, mediaKey, episodeKey), json.encodeToString(serializer<WatchedCoverage>(), coverage))

    /** After a completion the next viewing starts from nothing. */
    fun clear(profileId: Int, mediaKey: String, episodeKey: String?) = save(profileId, mediaKey, episodeKey, WatchedCoverage())
}

/**
 * One playback session's view of completion: feeds player samples to the coverage accumulator, asks the shared policy, and
 * returns a [PlaybackCompletionEvent] the first time the viewing completes. Engine switches and stream changes are
 * [onInterrupted], not a new session, so a fallback never looks like a new viewing.
 */
class PlaybackSessionTracker(
    val sessionId: String,
    val profileId: Int,
    val mediaKey: String,
    val episodeKey: String?,
    private val viewingIndex: Int,
    initialCoverage: WatchedCoverage = WatchedCoverage(),
    private val config: PlaybackCompletionConfig = PlaybackCompletionConfig(),
) {
    private val accumulator = PlaybackCoverageAccumulator(initialCoverage)
    private var segments: List<PlaybackSegment> = emptyList()
    private var emitted = false
    private var lastPositionMs = -1L

    val coverage: WatchedCoverage get() = accumulator.coverage

    /** The validated segments for the video that is playing (see [PlaybackSegments.validFor]). */
    fun updateSegments(validated: List<PlaybackSegment>) { segments = validated }

    fun creditSkipped(startMs: Long, endMs: Long) = accumulator.creditSkipped(startMs, endMs)

    fun onInterrupted() = accumulator.onInterrupted()

    /**
     * A forward jump out of a validated intro or recap is the viewer skipping it (the button, a double-tap or a drag): the rest
     * of that segment counts as seen, so skipping a real opening never stops a title from completing. Skipping from before the
     * segment, or into credits, is not credited: only a viewer already inside the segment chose to skip it.
     */
    private fun creditSkippedOpening(fromMs: Long, toMs: Long, durationMs: Long) {
        if (fromMs < 0L || toMs - fromMs < SKIP_JUMP_MIN_MS) return
        for (segment in segments) {
            if (segment.type != PlaybackSegmentType.INTRO && segment.type != PlaybackSegmentType.RECAP) continue
            val end = segment.resolvedEndMs(durationMs)
            if (fromMs >= segment.startMs && fromMs < end && toMs >= end - SKIP_LANDING_TOLERANCE_MS) {
                accumulator.creditSkipped(fromMs, end)
            }
        }
    }

    /** Where this session stands right now, without emitting anything (for diagnostics and the UI). */
    fun assess(positionMs: Long, durationMs: Long, isEnded: Boolean): PlaybackCompletionAssessment =
        PlaybackCompletionPolicy.assess(positionMs, durationMs, isEnded, coverage, segments, config)

    fun onSample(positionMs: Long, durationMs: Long, isPlaying: Boolean, isEnded: Boolean, wallMs: Long): PlaybackCompletionEvent? {
        creditSkippedOpening(lastPositionMs, positionMs, durationMs)
        accumulator.onSample(positionMs, isPlaying, wallMs)
        lastPositionMs = positionMs
        if (emitted) return null
        val assessment = assess(positionMs, durationMs, isEnded)
        val reason = assessment.reason ?: return null
        emitted = true
        return PlaybackCompletionEvent(
            profileId = profileId,
            mediaKey = mediaKey,
            episodeKey = episodeKey,
            sessionId = sessionId,
            reason = reason,
            completedAtMs = wallMs,
            coverageFraction = coverage.fraction(durationMs),
            narrativeEndMs = assessment.narrativeEndMs,
            viewingIndex = viewingIndex,
        )
    }
}

private const val SKIP_JUMP_MIN_MS = 4_000L
private const val SKIP_LANDING_TOLERANCE_MS = 2_000L

/** Switches for the unified playback behaviour. Off by default until it has been validated on real playback. */
object PlaybackFeatureFlags {
    /**
     * When true, the shared completion policy decides when a title counts as watched. When false (the default) the old rules
     * stay in charge and the policy only runs alongside them, so its verdict can be compared in diagnostics.
     */
    var unifiedCompletion: Boolean = false
}
