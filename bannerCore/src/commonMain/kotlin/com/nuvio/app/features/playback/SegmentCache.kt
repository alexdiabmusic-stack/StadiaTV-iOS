package com.nuvio.app.features.playback

/** What a cache read found. */
sealed interface SegmentCacheResult<out V> {
    /** A stored answer. [stale] answers are past their lifetime but inside the grace window: use now, refresh in the background. */
    data class Hit<V>(val value: V, val stale: Boolean) : SegmentCacheResult<V>

    /** A recent "the provider has nothing" answer: do not ask again yet. */
    data object NegativeHit : SegmentCacheResult<Nothing>

    data object Miss : SegmentCacheResult<Nothing>
}

/**
 * A bounded, expiring store for provider segment answers (kept in memory). Least recently used entries go first. Answers and
 * "nothing found" answers expire separately: a missing segment is worth re-asking sooner than a found one. Failed requests are
 * never stored. Pass the clock in so expiry is testable.
 */
class SegmentCache<V>(
    private val maxEntries: Int = 128,
    private val ttlMs: Long = 6 * HOUR_MS,
    private val negativeTtlMs: Long = 30 * MINUTE_MS,
    private val staleGraceMs: Long = 6 * HOUR_MS,
    private val clock: () -> Long,
) {
    private class Entry<V>(val value: V?, val storedAtMs: Long)

    private val entries = LinkedHashMap<String, Entry<V>>()

    val size: Int get() = entries.size

    fun get(key: String): SegmentCacheResult<V> {
        val entry = entries.remove(key) ?: return SegmentCacheResult.Miss
        val age = clock() - entry.storedAtMs
        val limit = if (entry.value == null) negativeTtlMs else ttlMs
        val grace = if (entry.value == null) 0L else staleGraceMs
        if (age > limit + grace) return SegmentCacheResult.Miss
        entries[key] = entry // most recently used goes last
        return if (entry.value == null) SegmentCacheResult.NegativeHit else SegmentCacheResult.Hit(entry.value, stale = age > limit)
    }

    fun put(key: String, value: V) = store(key, Entry(value, clock()))

    /** Remembers that the provider answered and has nothing. Not for failures. */
    fun putNegative(key: String) = store(key, Entry(null, clock()))

    fun remove(key: String) { entries.remove(key) }

    fun clear() = entries.clear()

    private fun store(key: String, entry: Entry<V>) {
        entries.remove(key)
        entries[key] = entry
        while (entries.size > maxEntries) entries.remove(entries.keys.first())
    }

    companion object {
        const val MINUTE_MS = 60_000L
        const val HOUR_MS = 60 * MINUTE_MS

        /**
         * A cache key from identity parts only. Everything is reduced to letters, digits and `: . _ -`, so a signed URL, a token
         * or a header can never end up inside a key (or a log line made from one). Edition and duration are part of the key
         * because the same IMDb id can be a different cut.
         */
        fun key(
            namespace: String,
            mediaId: String,
            season: Int? = null,
            episode: Int? = null,
            editionIdentity: String? = null,
            durationSeconds: Long? = null,
        ): String = buildString {
            append(safe(namespace)).append('|').append(safe(mediaId))
            if (season != null || episode != null) append('|').append(season ?: -1).append('x').append(episode ?: -1)
            if (!editionIdentity.isNullOrBlank()) append("|ed=").append(safe(editionIdentity))
            if (durationSeconds != null && durationSeconds > 0L) append("|d=").append(durationSeconds)
        }

        private fun safe(raw: String): String {
            val trimmed = raw.trim().lowercase()
            // A URL or anything with a query/credential shape is not an identity: keep only a short, harmless stub.
            val head = trimmed.substringBefore("://").substringBefore('?').substringBefore('&').substringBefore('@')
            return head.map { if (it.isLetterOrDigit() || it in ":._-") it else '_' }.joinToString("").take(80)
        }
    }
}
