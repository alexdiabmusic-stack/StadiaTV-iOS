package com.nuvio.app.features.smartdownloads

/** A title the recommendation engine suggests, with what is known about fetching it. */
data class ForYouCandidate(
    val titleKey: String,
    val episode: EpisodeId?,
    /** 0 to 1 from the recommendation engine. */
    val relevance: Double,
    val estimatedBytes: Long,
    val watched: Boolean,
    /** A source this app can actually download (a direct file link) is known to exist. */
    val downloadAvailable: Boolean,
    /** The profile may not be given this title (maturity, kids profile, blocked). */
    val restricted: Boolean = false,
)

enum class ForYouExclusion {
    RESTRICTED,
    ALREADY_WATCHED,
    ALREADY_OFFLINE,
    RECENTLY_DOWNLOADED,
    REMOVED_BY_USER,
    NO_COMPATIBLE_SOURCE,
    LOW_RELEVANCE,
}

data class ForYouExcluded(val titleKey: String, val reason: ForYouExclusion)

data class ForYouPlan(
    val enqueue: List<PlannedDownload> = emptyList(),
    /** Automatic downloads the viewer has finished, to clear. Never a manual download. */
    val remove: List<OfflineRef> = emptyList(),
    val cancel: List<OfflineRef> = emptyList(),
    val excluded: List<ForYouExcluded> = emptyList(),
    val blocked: List<BlockedItem> = emptyList(),
)

/**
 * Downloads for You: a few personalised picks kept on the device within a budget. It only ever adds automatic downloads or
 * clears finished automatic ones; manual downloads are neither counted against the budget nor replaced.
 */
object ForYouPlanner {
    const val MIN_RELEVANCE = 0.5
    const val REPEAT_WINDOW_MS = 60L * 24 * 60 * 60_000L

    fun plan(
        settings: SmartDownloadSettings,
        conditions: DeviceConditions,
        profileId: Int,
        candidates: List<ForYouCandidate>,
        deviceEntries: List<OfflineEntry>,
        history: SmartDownloadHistory = NoSmartDownloadHistory,
        nowMs: Long = 0L,
    ): ForYouPlan {
        val mine = deviceEntries.filter { it.profileId == profileId && it.origin == DownloadOrigin.FOR_YOU }
        if (!settings.forYouEnabled) {
            return ForYouPlan(
                cancel = mine.filter { !it.status.isCompleted }.map { it.ref },
                blocked = listOf(BlockedItem("for-you", BlockReason.FeatureDisabled)),
            )
        }

        // What the viewer has finished, and was fetched for them, is cleared and its room given back.
        val clearable = mine.filter { it.watched && it.status.isCompleted && SmartDownloadGates.removable(it, settings, lastAired = null) }
        val remove = clearable.map { it.ref }

        val gate = SmartDownloadGates.gate(settings, conditions)
        if (gate != null) return ForYouPlan(remove = remove, blocked = listOf(BlockedItem("for-you", gate)))

        val offlineTitles = deviceEntries.filter { it.profileId == profileId && it.status != OfflineStatus.FAILED }.map { it.titleKey }.toSet()
        val excluded = ArrayList<ForYouExcluded>()
        val eligible = ArrayList<ForYouCandidate>()
        for (c in candidates) {
            val past = history.forYou(profileId, c.titleKey)
            val reason = when {
                c.restricted -> ForYouExclusion.RESTRICTED
                c.watched -> ForYouExclusion.ALREADY_WATCHED
                c.titleKey in offlineTitles -> ForYouExclusion.ALREADY_OFFLINE
                past?.userRemoved == true -> ForYouExclusion.REMOVED_BY_USER
                past != null && past.lastAutoDownloadMs > 0L && nowMs - past.lastAutoDownloadMs < REPEAT_WINDOW_MS -> ForYouExclusion.RECENTLY_DOWNLOADED
                !c.downloadAvailable -> ForYouExclusion.NO_COMPATIBLE_SOURCE
                c.relevance < MIN_RELEVANCE -> ForYouExclusion.LOW_RELEVANCE
                else -> null
            }
            if (reason != null) excluded += ForYouExcluded(c.titleKey, reason) else eligible += c
        }

        // Room is counted without what is about to be cleared having been cleared yet: it frees up for the next run.
        val keptTitles = mine.filter { it.ref !in remove && it.status != OfflineStatus.FAILED && !it.watched }.map { it.titleKey }.toSet()
        var slots = settings.forYouMaxTitles - keptTitles.size
        var freeBytes = conditions.freeStorageBytes
        var automaticBytes = deviceEntries.filter { it.origin.isAutomatic && it.status != OfflineStatus.FAILED }.sumOf { it.sizeBytes }
        var profileBytes = deviceEntries
            .filter { it.profileId == profileId && it.origin.isAutomatic && it.status != OfflineStatus.FAILED }
            .sumOf { it.sizeBytes }
        val enqueue = ArrayList<PlannedDownload>()
        val blocked = ArrayList<BlockedItem>()
        for (c in eligible.sortedWith(compareByDescending<ForYouCandidate> { it.relevance }.thenBy { it.titleKey })) {
            if (slots <= 0) break
            val reason = SmartDownloadGates.fitBlock(c.estimatedBytes, freeBytes, automaticBytes, profileBytes, settings)
            if (reason != null) {
                blocked += BlockedItem(c.titleKey, reason)
                continue
            }
            enqueue += PlannedDownload(profileId, c.titleKey, c.episode, DownloadOrigin.FOR_YOU, c.estimatedBytes)
            freeBytes -= c.estimatedBytes
            automaticBytes += c.estimatedBytes
            profileBytes += c.estimatedBytes
            slots--
        }
        return ForYouPlan(enqueue = enqueue, remove = remove, excluded = excluded, blocked = blocked)
    }
}
