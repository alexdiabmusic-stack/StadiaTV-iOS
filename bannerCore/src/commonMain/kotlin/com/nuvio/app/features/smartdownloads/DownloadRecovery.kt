package com.nuvio.app.features.smartdownloads

enum class FailureKind {
    /** The link or its credentials stopped working: a fresh source has to be resolved. */
    EXPIRED_SOURCE,

    /** The file is no longer at that link. */
    SOURCE_GONE,
    TRANSIENT_NETWORK,
    STORAGE_FULL,
    FILE_ERROR,
    UNKNOWN,
}

enum class RecoveryAction {
    RETRY_SAME_SOURCE,
    REFRESH_SOURCE_AND_RETRY,
    WAIT_FOR_STORAGE,
    MARK_UNAVAILABLE,
    FAIL,
}

data class Recovery(val action: RecoveryAction, val retryAfterMs: Long? = null)

object DownloadFailures {
    /** Reads a failure from the HTTP status the transfer saw and whatever message the platform gave. */
    private val statusInMessage = Regex("""(?i)(?:http|status(?: code)?)\D{0,3}([1-5]\d\d)""")

    fun classify(httpStatus: Int?, message: String?): FailureKind {
        val text = message.orEmpty().lowercase()
        @Suppress("NAME_SHADOWING")
        val httpStatus = httpStatus ?: statusInMessage.find(message.orEmpty())?.groupValues?.get(1)?.toIntOrNull()
        return when {
            httpStatus == 401 || httpStatus == 403 || httpStatus == 410 -> FailureKind.EXPIRED_SOURCE
            httpStatus == 404 -> FailureKind.SOURCE_GONE
            httpStatus == 408 || httpStatus == 425 || httpStatus == 429 || (httpStatus != null && httpStatus >= 500) -> FailureKind.TRANSIENT_NETWORK
            "expired" in text || "signature" in text || "token" in text && "invalid" in text -> FailureKind.EXPIRED_SOURCE
            "no space" in text || "not enough space" in text || "disk full" in text || "storage" in text && "full" in text -> FailureKind.STORAGE_FULL
            "timed out" in text || "timeout" in text || "network" in text || "connection" in text || "offline" in text || "interrupted" in text -> FailureKind.TRANSIENT_NETWORK
            "file" in text && ("write" in text || "move" in text || "finalize" in text) -> FailureKind.FILE_ERROR
            else -> FailureKind.UNKNOWN
        }
    }
}

object DownloadRecovery {
    private const val MAX_SOURCE_REFRESHES = 2
    private const val MAX_RETRIES = 3

    /**
     * [attempts] is how many times this download has already failed. A link that stopped working is replaced by a freshly
     * resolved one (a couple of times) rather than retried; a dropped connection is retried with a growing wait.
     */
    fun next(kind: FailureKind, attempts: Int): Recovery = when (kind) {
        FailureKind.EXPIRED_SOURCE -> if (attempts < MAX_SOURCE_REFRESHES) Recovery(RecoveryAction.REFRESH_SOURCE_AND_RETRY) else Recovery(RecoveryAction.MARK_UNAVAILABLE)
        FailureKind.SOURCE_GONE -> if (attempts < 1) Recovery(RecoveryAction.REFRESH_SOURCE_AND_RETRY) else Recovery(RecoveryAction.MARK_UNAVAILABLE)
        FailureKind.TRANSIENT_NETWORK -> if (attempts < MAX_RETRIES) Recovery(RecoveryAction.RETRY_SAME_SOURCE, 30_000L * (1L shl attempts)) else Recovery(RecoveryAction.FAIL)
        FailureKind.STORAGE_FULL -> Recovery(RecoveryAction.WAIT_FOR_STORAGE)
        FailureKind.FILE_ERROR, FailureKind.UNKNOWN -> if (attempts < 1) Recovery(RecoveryAction.RETRY_SAME_SOURCE, 30_000L) else Recovery(RecoveryAction.FAIL)
    }
}

// Source selection ------------------------------------------------------------------------------------------------

data class DownloadableSource(
    val id: String,
    val addonId: String?,
    val url: String,
    val resolutionHeight: Int?,
    val sizeBytes: Long? = null,
)

object DownloadSourceSelector {
    /** A direct file over HTTP(S). Playlists, torrents and magnet links cannot be saved to the device. */
    fun isDownloadable(url: String): Boolean {
        val u = url.trim().lowercase()
        if (u.startsWith("magnet:")) return false
        if (u.endsWith(".m3u8") || u.contains(".m3u8?")) return false
        if (u.endsWith(".mpd") || u.contains(".mpd?")) return false
        if (u.endsWith(".torrent") || u.contains(".torrent?")) return false
        return u.startsWith("http://") || u.startsWith("https://")
    }

    private val heightPattern = Regex("""(?i)(?<![0-9])(2160|1440|1080|720|576|480|360)\s*p""")

    /** The video height a stream's label advertises ("1080p", "4K", "UHD"), or null when it does not say. */
    fun resolutionFromLabel(vararg labels: String?): Int? {
        val text = labels.filterNotNull().joinToString(" ")
        heightPattern.find(text)?.groupValues?.get(1)?.toIntOrNull()?.let { return it }
        if (Regex("""(?i)\b(4k|uhd)\b""").containsMatchIn(text)) return 2160
        return null
    }

    /**
     * The source to fetch, or null when none can be downloaded. The best one that fits the quality cap wins; a source from the
     * provider the viewer already downloads from breaks ties. When everything is above the cap, the smallest is used.
     */
    fun pick(sources: List<DownloadableSource>, quality: DownloadQuality, preferredAddonId: String? = null): DownloadableSource? {
        val usable = sources.filter { isDownloadable(it.url) }
        if (usable.isEmpty()) return null
        val cap = quality.maxHeight
        val withinCap = if (cap == null) usable else usable.filter { (it.resolutionHeight ?: Int.MIN_VALUE) <= cap }
        if (withinCap.isEmpty()) {
            return usable.minWith(compareBy<DownloadableSource> { it.resolutionHeight ?: Int.MAX_VALUE }.thenBy { it.sizeBytes ?: Long.MAX_VALUE }.thenBy { it.id })
        }
        return withinCap.maxWith(
            compareBy<DownloadableSource> { it.resolutionHeight ?: 0 }
                .thenBy { if (preferredAddonId != null && it.addonId == preferredAddonId) 1 else 0 }
                .thenByDescending { it.id },
        )
    }
}

// Reconciliation after a relaunch -----------------------------------------------------------------------------------

data class PersistedTransfer(
    val id: String,
    val status: OfflineStatus,
    val downloadedBytes: Long = 0L,
    val totalBytes: Long? = null,
    /** For a finished download: the file is where it was left. */
    val completedFileExists: Boolean = false,
    /** A partial file or resume data is available to continue from. */
    val resumable: Boolean = false,
    val attempts: Int = 0,
)

sealed interface NativeTransfer {
    /** The operating system still has the task, running or waiting for conditions. */
    data object Running : NativeTransfer

    /** The system finished the file while the app was away. */
    data class Finished(val fileSizeBytes: Long?) : NativeTransfer
    data class Failed(val kind: FailureKind) : NativeTransfer
}

sealed interface ReconcileAction {
    data object Keep : ReconcileAction
    data object MarkCompleted : ReconcileAction
    data object ResumeFromPartial : ReconcileAction
    data object RestartFromBeginning : ReconcileAction
    data class RefreshSourceAndRestart(val reason: FailureKind) : ReconcileAction
    data class MarkFailed(val reason: FailureKind) : ReconcileAction
    data object CancelOrphan : ReconcileAction
}

/**
 * Brings what the app saved into line with what the operating system actually has after a relaunch. The app can be ended at any
 * time and a download may have run, finished or been lost while it was gone, so nothing is assumed from the saved status alone.
 */
object DownloadReconciler {
    fun reconcile(persisted: List<PersistedTransfer>, native: Map<String, NativeTransfer>): Map<String, ReconcileAction> {
        val result = LinkedHashMap<String, ReconcileAction>()
        for (item in persisted) {
            val system = native[item.id]
            result[item.id] = when (item.status) {
                OfflineStatus.COMPLETED -> if (item.completedFileExists) ReconcileAction.Keep else ReconcileAction.MarkFailed(FailureKind.FILE_ERROR)
                OfflineStatus.PAUSED, OfflineStatus.FAILED -> ReconcileAction.Keep
                OfflineStatus.QUEUED, OfflineStatus.DOWNLOADING -> when (system) {
                    NativeTransfer.Running -> ReconcileAction.Keep
                    is NativeTransfer.Finished -> {
                        val expected = item.totalBytes
                        if (expected != null && system.fileSizeBytes != null && system.fileSizeBytes != expected) ReconcileAction.RestartFromBeginning
                        else ReconcileAction.MarkCompleted
                    }
                    is NativeTransfer.Failed -> when (DownloadRecovery.next(system.kind, item.attempts).action) {
                        RecoveryAction.REFRESH_SOURCE_AND_RETRY -> ReconcileAction.RefreshSourceAndRestart(system.kind)
                        RecoveryAction.RETRY_SAME_SOURCE -> if (item.resumable) ReconcileAction.ResumeFromPartial else ReconcileAction.RestartFromBeginning
                        RecoveryAction.WAIT_FOR_STORAGE -> ReconcileAction.Keep
                        RecoveryAction.MARK_UNAVAILABLE, RecoveryAction.FAIL -> ReconcileAction.MarkFailed(system.kind)
                    }
                    // The system has no task: the app was ended and the transfer was lost.
                    null -> when {
                        item.attempts >= SmartDownloadDefaults.MAX_ATTEMPTS -> ReconcileAction.MarkFailed(FailureKind.UNKNOWN)
                        item.resumable -> ReconcileAction.ResumeFromPartial
                        else -> ReconcileAction.RestartFromBeginning
                    }
                }
            }
        }
        val known = persisted.map { it.id }.toSet()
        native.keys.filter { it !in known }.forEach { result[it] = ReconcileAction.CancelOrphan }
        return result
    }
}
