package com.nuvio.app.features.smartdownloads

import com.nuvio.app.features.playback.PlaybackStateStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/** Remembers what the automatic features have tried, per profile, so nothing is fetched over and over or comes back after being removed. */
class SmartDownloadHistoryStore(
    private val store: PlaybackStateStore,
    private val storeName: String = "smart_download_history",
) : SmartDownloadHistory {
    @Serializable
    private data class Row(
        val key: String,
        val attempts: Int = 0,
        val lastAttemptMs: Long = 0L,
        val userRemoved: Boolean = false,
        val lastAutoDownloadMs: Long = 0L,
    )

    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(Row.serializer())

    private fun load(profileId: Int): List<Row> =
        store.get(storeName, "p$profileId")?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() }.orEmpty()

    private fun save(profileId: Int, rows: List<Row>) = store.put(storeName, "p$profileId", json.encodeToString(serializer, rows.takeLast(MAX_ROWS)))

    private fun episodeKey(ref: OfflineRef) = "${ref.titleKey}|${ref.episode?.let { "${it.season}x${it.episode}" } ?: "-"}"

    private fun update(ref: OfflineRef, change: (Row) -> Row) {
        val key = episodeKey(ref)
        val rows = load(ref.profileId)
        val current = rows.firstOrNull { it.key == key } ?: Row(key)
        save(ref.profileId, rows.filterNot { it.key == key } + change(current))
    }

    override fun attempt(ref: OfflineRef): AttemptRecord? =
        load(ref.profileId).firstOrNull { it.key == episodeKey(ref) }?.let { AttemptRecord(it.attempts, it.lastAttemptMs, it.userRemoved) }

    override fun forYou(profileId: Int, titleKey: String): ForYouHistoryRecord? {
        val rows = load(profileId).filter { it.key.substringBefore('|') == titleKey }
        if (rows.isEmpty()) return null
        return ForYouHistoryRecord(rows.maxOf { it.lastAutoDownloadMs }, rows.any { it.userRemoved })
    }

    /**
     * A try started or failed. With [retryImmediately] the try still counts toward the limit but starts no waiting period
     * (an expired link is replaced straight away rather than after a delay).
     */
    fun recordAttempt(ref: OfflineRef, nowMs: Long, retryImmediately: Boolean = false) =
        update(ref) { it.copy(attempts = it.attempts + 1, lastAttemptMs = if (retryImmediately) 0L else nowMs) }

    /** The download finished: attempts reset and the time is kept so the same title is not fetched again soon. */
    fun recordSuccess(ref: OfflineRef, nowMs: Long) = update(ref) { it.copy(attempts = 0, lastAttemptMs = nowMs, lastAutoDownloadMs = nowMs) }

    /** The viewer removed an automatic download: it is not brought back. */
    fun markUserRemoved(ref: OfflineRef) = update(ref) { it.copy(userRemoved = true) }

    /** The viewer asked for it again by hand, so the block is lifted. */
    fun clear(ref: OfflineRef) {
        val key = episodeKey(ref)
        save(ref.profileId, load(ref.profileId).filterNot { it.key == key })
    }

    private companion object {
        const val MAX_ROWS = 400
    }
}
