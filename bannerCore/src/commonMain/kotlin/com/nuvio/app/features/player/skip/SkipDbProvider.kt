package com.nuvio.app.features.player.skip

import com.nuvio.app.features.addons.httpRequestRaw
import com.nuvio.app.features.playback.PlaybackSegment
import com.nuvio.app.features.playback.PlaybackSegmentType
import com.nuvio.app.features.playback.SegmentLookupOutcome
import com.nuvio.app.features.playback.SegmentMatchQuality
import com.nuvio.app.features.playback.SegmentMediaContext
import com.nuvio.app.features.playback.SegmentSource
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * SkipDB (https://skipdb.tv/docs): `GET /api/segments?imdb_id=…[&season=…&episode=…][&duration=<seconds>][&adjust=…]`.
 * Reads are open (120 requests a minute, no key). One best segment per type; `null` means "no approved data", which is not the
 * same as "confirmed absent". Times are milliseconds. `match` says how the stream's duration fit: `exact` (within 2 s),
 * `shifted` (within 15 s, adjusted), `agnostic` (no duration sent), `out-of-range` (too different to trust).
 */
@Serializable
data class SkipDbResponse(
    @SerialName("imdb_id") val imdbId: String? = null,
    @SerialName("season") val season: Int? = null,
    @SerialName("episode") val episode: Int? = null,
    @SerialName("segments") val segments: SkipDbSegments? = null,
    /** The season's typical intro length when most episodes agree. Not a timestamp; never used as one. */
    @SerialName("intro_length_estimate_ms") val introLengthEstimateMs: Double? = null,
)

@Serializable
data class SkipDbSegments(
    @SerialName("intro") val intro: SkipDbSegment? = null,
    @SerialName("recap") val recap: SkipDbSegment? = null,
    @SerialName("outro") val outro: SkipDbSegment? = null,
    @SerialName("preview") val preview: SkipDbSegment? = null,
)

@Serializable
data class SkipDbSegment(
    @SerialName("start_ms") val startMs: Double? = null,
    @SerialName("end_ms") val endMs: Double? = null,
    @SerialName("match") val match: String? = null,
    @SerialName("adjusted") val adjusted: Boolean = false,
    @SerialName("offset_ms") val offsetMs: Double? = null,
    @SerialName("confidence") val confidence: Double? = null,
)

object SkipDbProvider {
    const val BASE_URL = "https://api.skipdb.tv"
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val imdbPattern = Regex("^tt[0-9]{1,12}$")

    /** Reads SkipDB's answer into segments. Segments with impossible times are dropped; none left is [SegmentLookupOutcome.NoData]. */
    fun parse(body: String, context: SegmentMediaContext): SegmentLookupOutcome {
        val response = try {
            json.decodeFromString<SkipDbResponse>(body)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            return SegmentLookupOutcome.Invalid("SkipDB response was not understood")
        }
        val s = response.segments ?: return SegmentLookupOutcome.NoData
        val present = listOfNotNull(
            s.intro?.let { PlaybackSegmentType.INTRO to it },
            s.recap?.let { PlaybackSegmentType.RECAP to it },
            s.outro?.let { PlaybackSegmentType.CREDITS to it },
            s.preview?.let { PlaybackSegmentType.NEXT_EPISODE_PREVIEW to it },
        )
        if (present.isEmpty()) return SegmentLookupOutcome.NoData
        val usable = present.mapNotNull { (type, seg) -> seg.toPlaybackSegment(type, context) }
        return if (usable.isEmpty()) SegmentLookupOutcome.Invalid("SkipDB returned only unusable timestamps") else SegmentLookupOutcome.Segments(usable)
    }

    private fun SkipDbSegment.toPlaybackSegment(type: PlaybackSegmentType, context: SegmentMediaContext): PlaybackSegment? {
        val start = startMs ?: return null
        val end = endMs ?: return null
        if (!start.isFinite() || !end.isFinite() || start < 0.0 || end <= start) return null
        val quality = when (match?.trim()?.lowercase()) {
            "exact" -> SegmentMatchQuality.DURATION_MATCHED
            "shifted" -> SegmentMatchQuality.DURATION_ADJUSTED
            "agnostic" -> SegmentMatchQuality.DURATION_AGNOSTIC
            // The docs: treat as an uncertain match. Manual use only.
            "out-of-range" -> SegmentMatchQuality.DURATION_APPROXIMATE
            else -> SegmentMatchQuality.UNKNOWN
        }
        return PlaybackSegment(
            type = type,
            startMs = start.toLong(),
            endMs = end.toLong(),
            source = SegmentSource.SKIPDB,
            confidence = confidence?.takeIf { it.isFinite() },
            matchQuality = quality,
            mediaContext = context,
        )
    }

    fun requestUrl(imdbId: String, season: Int?, episode: Int?, durationMs: Long?, baseUrl: String = BASE_URL): String? {
        if (!imdbPattern.matches(imdbId)) return null
        return buildString {
            append(baseUrl.trimEnd('/')).append("/api/segments?imdb_id=").append(imdbId)
            if (season != null && episode != null) append("&season=").append(season).append("&episode=").append(episode)
            if (durationMs != null && durationMs > 0L) append("&duration=").append((durationMs + 500L) / 1000L)
            append("&adjust=conservative")
        }
    }

    /**
     * One lookup. Every failure is reported as its own outcome and none is mistaken for "no segments": 404 is no data,
     * 429 and server errors are retryable provider errors, 400/422 and unreadable bodies are invalid.
     */
    suspend fun fetch(
        imdbId: String,
        season: Int?,
        episode: Int?,
        durationMs: Long?,
        baseUrl: String = BASE_URL,
    ): SegmentLookupOutcome {
        val url = requestUrl(imdbId, season, episode, durationMs, baseUrl) ?: return SegmentLookupOutcome.Invalid("not an IMDb id")
        val context = if (season == null || episode == null) SegmentMediaContext.MOVIE else SegmentMediaContext.EPISODE
        return try {
            val response = httpRequestRaw("GET", url, mapOf("Accept" to "application/json"), "")
            when (response.status) {
                in 200..299 -> parse(response.body, context)
                404 -> SegmentLookupOutcome.NoData
                400, 422 -> SegmentLookupOutcome.Invalid("SkipDB rejected the request (${response.status})")
                429 -> SegmentLookupOutcome.ProviderError("SkipDB rate limit reached", retryable = true)
                in 500..599 -> SegmentLookupOutcome.ProviderError("SkipDB server error (${response.status})", retryable = true)
                else -> SegmentLookupOutcome.ProviderError("SkipDB answered ${response.status}", retryable = false)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            SegmentLookupOutcome.ProviderError(error.message ?: "SkipDB request failed", retryable = true)
        }
    }
}

/** The player's skip intervals for a lookup that found segments (empty for every other outcome). */
fun SegmentLookupOutcome.toSkipIntervals(provider: String): List<SkipInterval> =
    (this as? SegmentLookupOutcome.Segments)?.segments?.mapNotNull { it.toSkipInterval(provider) }.orEmpty()
