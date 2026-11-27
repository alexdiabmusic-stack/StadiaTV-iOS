package com.nuvio.app.features.smartdownloads

/** Who asked for a download. Manual downloads are never replaced, trimmed or deleted by anything automatic. */
enum class DownloadOrigin {
    MANUAL,
    NEXT_EPISODE,
    FOR_YOU,
    ;

    val isAutomatic: Boolean get() = this != MANUAL
}

enum class OfflineStatus {
    QUEUED,
    DOWNLOADING,
    PAUSED,
    COMPLETED,
    FAILED,
    ;

    val isCompleted: Boolean get() = this == COMPLETED
    val isTransferring: Boolean get() = this == QUEUED || this == DOWNLOADING
}

data class EpisodeId(val season: Int, val episode: Int) : Comparable<EpisodeId> {
    override fun compareTo(other: EpisodeId): Int = compareValuesBy(this, other, { it.season }, { it.episode })
}

/** One thing on the device (or on its way), kept in the shape the planners need; the app maps its own items to this. */
data class OfflineEntry(
    val profileId: Int,
    val titleKey: String,
    /** Null for a film. */
    val episode: EpisodeId?,
    val origin: DownloadOrigin,
    val status: OfflineStatus,
    val sizeBytes: Long,
    /** The viewer pinned it ("Keep"). Nothing automatic deletes it. */
    val pinned: Boolean = false,
    /** Explicitly retained by some other action (for example a saved-for-later flag). */
    val retained: Boolean = false,
    /** It is the video playing right now. */
    val playingNow: Boolean = false,
    /** Whether the viewer has finished it, from the shared completion events. */
    val watched: Boolean = false,
    val createdAtMs: Long = 0L,
) {
    val ref: OfflineRef get() = OfflineRef(profileId, titleKey, episode)
}

data class OfflineRef(val profileId: Int, val titleKey: String, val episode: EpisodeId?)

enum class DownloadQuality(val maxHeight: Int?, val bitsPerSecond: Long) {
    DATA_SAVER(720, 1_500_000L),
    STANDARD(1080, 4_000_000L),
    HIGH(null, 8_000_000L),
}

/** What to do with an episode the viewer has finished. Manual downloads are only ever deleted by [ALL_WATCHED], the viewer's explicit choice. */
enum class AutoDeletePolicy {
    NEVER,
    AUTOMATIC_ONLY,
    ALL_WATCHED,
}

object SmartDownloadDefaults {
    const val FREE_STORAGE_RESERVE_BYTES = 1L * 1024 * 1024 * 1024
    const val DEFAULT_STORAGE_LIMIT_BYTES = 10L * 1024 * 1024 * 1024
    const val MAX_ATTEMPTS = 3
    const val DEFAULT_EPISODE_RUNTIME_MINUTES = 45
}

/** Both automatic features are opt-in. Everything beyond the first five is the Advanced section. */
data class SmartDownloadSettings(
    val nextEpisodeEnabled: Boolean = false,
    val forYouEnabled: Boolean = false,
    val wifiOnly: Boolean = true,
    /** Most the automatic downloads may use on the device in all. Null means no cap beyond the free-space reserve. */
    val storageLimitBytes: Long? = SmartDownloadDefaults.DEFAULT_STORAGE_LIMIT_BYTES,
    val quality: DownloadQuality = DownloadQuality.STANDARD,
    val upcomingEpisodes: Int = 1,
    val chargingOnly: Boolean = false,
    val autoDelete: AutoDeletePolicy = AutoDeletePolicy.AUTOMATIC_ONLY,
    /** The final aired episode of a series is kept unless the viewer chooses otherwise. */
    val deleteLastEpisode: Boolean = false,
    /** Most the automatic downloads may use for one profile. Null means only the device limit applies. */
    val profileBudgetBytes: Long? = null,
    val forYouMaxTitles: Int = 3,
) {
    val upcoming: Int get() = upcomingEpisodes.coerceIn(1, 3)
}

data class DeviceConditions(
    val online: Boolean,
    val onWifi: Boolean,
    val charging: Boolean = false,
    val freeStorageBytes: Long,
)

/** Why something that would otherwise be downloaded was not. Reported, never silently dropped. */
sealed interface BlockReason {
    data object FeatureDisabled : BlockReason
    data object Offline : BlockReason
    data object CellularRestricted : BlockReason
    data object ChargingRequired : BlockReason
    data object RestrictedTitle : BlockReason
    data object SuppressedByUser : BlockReason
    data object AttemptsExhausted : BlockReason
    data class RetryLater(val untilMs: Long) : BlockReason
    data class InsufficientStorage(val neededBytes: Long, val availableBytes: Long) : BlockReason
    data class StorageLimitReached(val limitBytes: Long) : BlockReason
    data class ProfileBudgetReached(val budgetBytes: Long) : BlockReason
}

data class BlockedItem(val subject: String, val reason: BlockReason)

data class PlannedDownload(
    val profileId: Int,
    val titleKey: String,
    val episode: EpisodeId?,
    val origin: DownloadOrigin,
    val estimatedBytes: Long,
    /** A failed automatic attempt for the same thing exists and is to be replaced with a fresh source. */
    val replacesFailed: Boolean = false,
)

/**
 * What to do, in this order: cancel, remove, then enqueue. Removals only appear after a replacement is verified on the device,
 * or when a replacement cannot fit unless the finished episode goes first.
 */
data class SmartDownloadPlan(
    val enqueue: List<PlannedDownload> = emptyList(),
    val remove: List<OfflineRef> = emptyList(),
    val cancel: List<OfflineRef> = emptyList(),
    val blocked: List<BlockedItem> = emptyList(),
) {
    val isEmpty: Boolean get() = enqueue.isEmpty() && remove.isEmpty() && cancel.isEmpty()
}

object EstimatedDownloadSize {
    fun forRuntime(runtimeMinutes: Int?, quality: DownloadQuality): Long {
        val minutes = (runtimeMinutes ?: SmartDownloadDefaults.DEFAULT_EPISODE_RUNTIME_MINUTES).coerceAtLeast(1)
        return minutes * 60L * quality.bitsPerSecond / 8L
    }
}

/** Counts of what has been tried, so a title that keeps failing is not retried forever and one the viewer removed does not come back. */
data class AttemptRecord(
    val attempts: Int = 0,
    val lastAttemptMs: Long = 0L,
    val userRemoved: Boolean = false,
)

data class ForYouHistoryRecord(val lastAutoDownloadMs: Long = 0L, val userRemoved: Boolean = false)

interface SmartDownloadHistory {
    fun attempt(ref: OfflineRef): AttemptRecord?
    fun forYou(profileId: Int, titleKey: String): ForYouHistoryRecord?
}

object NoSmartDownloadHistory : SmartDownloadHistory {
    override fun attempt(ref: OfflineRef): AttemptRecord? = null
    override fun forYou(profileId: Int, titleKey: String): ForYouHistoryRecord? = null
}

internal object SmartDownloadGates {
    /** The conditions that hold back every automatic start, whatever the title. */
    fun gate(settings: SmartDownloadSettings, conditions: DeviceConditions): BlockReason? = when {
        !conditions.online -> BlockReason.Offline
        settings.wifiOnly && !conditions.onWifi -> BlockReason.CellularRestricted
        settings.chargingOnly && !conditions.charging -> BlockReason.ChargingRequired
        else -> null
    }

    /** Retry spacing after a failed attempt: 15 minutes, 2 hours, 12 hours. */
    fun backoffMs(attempts: Int): Long = when {
        attempts <= 1 -> 15 * 60_000L
        attempts == 2 -> 2 * 60 * 60_000L
        else -> 12 * 60 * 60_000L
    }

    fun attemptBlock(record: AttemptRecord?, nowMs: Long): BlockReason? = when {
        record == null -> null
        record.userRemoved -> BlockReason.SuppressedByUser
        record.attempts >= SmartDownloadDefaults.MAX_ATTEMPTS -> BlockReason.AttemptsExhausted
        record.attempts > 0 && nowMs < record.lastAttemptMs + backoffMs(record.attempts) ->
            BlockReason.RetryLater(record.lastAttemptMs + backoffMs(record.attempts))
        else -> null
    }

    /** Null when [needed] more bytes fit under the free-space reserve, the device limit and the profile budget. */
    fun fitBlock(
        needed: Long,
        freeBytes: Long,
        automaticBytes: Long,
        profileAutomaticBytes: Long,
        settings: SmartDownloadSettings,
    ): BlockReason? {
        val available = freeBytes - SmartDownloadDefaults.FREE_STORAGE_RESERVE_BYTES
        if (needed > available) return BlockReason.InsufficientStorage(needed, available.coerceAtLeast(0L))
        settings.storageLimitBytes?.let { if (automaticBytes + needed > it) return BlockReason.StorageLimitReached(it) }
        settings.profileBudgetBytes?.let { if (profileAutomaticBytes + needed > it) return BlockReason.ProfileBudgetReached(it) }
        return null
    }

    fun removable(entry: OfflineEntry, settings: SmartDownloadSettings, lastAired: EpisodeId?): Boolean {
        if (!entry.status.isCompleted || entry.pinned || entry.retained || entry.playingNow) return false
        val allowedByPolicy = when (settings.autoDelete) {
            AutoDeletePolicy.NEVER -> false
            AutoDeletePolicy.AUTOMATIC_ONLY -> entry.origin.isAutomatic
            AutoDeletePolicy.ALL_WATCHED -> true
        }
        if (!allowedByPolicy) return false
        if (entry.episode != null && entry.episode == lastAired && !settings.deleteLastEpisode) return false
        return true
    }
}
