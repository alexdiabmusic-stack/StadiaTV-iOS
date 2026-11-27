package com.nuvio.app.features.smartdownloads

data class CatalogEpisode(val id: EpisodeId, val aired: Boolean, val estimatedBytes: Long)

data class SeriesContext(
    val profileId: Int,
    val titleKey: String,
    val episodes: List<CatalogEpisode>,
    /** Episodes the viewer has finished, read from the shared completion events (never a percentage of its own). */
    val watched: Set<EpisodeId>,
    /** The profile may not be given this title automatically (maturity, kids profile, blocked). */
    val restricted: Boolean = false,
)

/**
 * Download Next Episode: after the viewer finishes an episode of a series they have downloaded, keep the next one to three
 * aired episodes on the device, and clear what they have watched. Pure: it reads the situation and returns what to do.
 */
object NextEpisodePlanner {
    fun plan(
        settings: SmartDownloadSettings,
        conditions: DeviceConditions,
        series: SeriesContext,
        deviceEntries: List<OfflineEntry>,
        history: SmartDownloadHistory = NoSmartDownloadHistory,
        nowMs: Long = 0L,
    ): SmartDownloadPlan {
        val mine = deviceEntries.filter { it.profileId == series.profileId && it.titleKey == series.titleKey }
        val unfinishedAutomatic = mine.filter { it.origin == DownloadOrigin.NEXT_EPISODE && !it.status.isCompleted }.map { it.ref }

        // Turning the feature off stops what it started and has not finished; what finished stays, and nothing is deleted.
        if (!settings.nextEpisodeEnabled) {
            return SmartDownloadPlan(cancel = unfinishedAutomatic, blocked = listOf(BlockedItem(series.titleKey, BlockReason.FeatureDisabled)))
        }
        if (series.restricted) {
            return SmartDownloadPlan(cancel = unfinishedAutomatic, blocked = listOf(BlockedItem(series.titleKey, BlockReason.RestrictedTitle)))
        }
        // Only a series the viewer has downloaded something of is managed, and only once they have finished an episode.
        if (mine.none { it.status != OfflineStatus.FAILED }) return SmartDownloadPlan()
        val anchor = series.watched.maxOrNull() ?: return SmartDownloadPlan()

        val aired = series.episodes.filter { it.aired }.sortedBy { it.id }
        val lastAired = aired.lastOrNull()?.id
        val wanted = aired.filter { it.id > anchor && it.id !in series.watched }.take(settings.upcoming)

        val present = mine.filter { it.episode != null && it.status != OfflineStatus.FAILED }.associateBy { it.episode!! }
        val failed = mine.filter { it.episode != null && it.status == OfflineStatus.FAILED }.associateBy { it.episode!! }
        val missing = wanted.filter { it.id !in present }
        val replacementsReady = wanted.all { present[it.id]?.status == OfflineStatus.COMPLETED }

        val deletable = mine
            .filter { it.episode != null && it.episode in series.watched && SmartDownloadGates.removable(it, settings, lastAired) }
            .sortedBy { it.episode }

        val enqueue = ArrayList<PlannedDownload>()
        val remove = ArrayList<OfflineRef>()
        val blocked = ArrayList<BlockedItem>()

        if (missing.isNotEmpty()) {
            val gate = SmartDownloadGates.gate(settings, conditions)
            if (gate != null) {
                missing.forEach { blocked += BlockedItem(label(series, it.id), gate) }
            } else {
                var freeBytes = conditions.freeStorageBytes
                var automaticBytes = deviceEntries.filter { it.origin.isAutomatic && it.status != OfflineStatus.FAILED }.sumOf { it.sizeBytes }
                var profileBytes = deviceEntries
                    .filter { it.profileId == series.profileId && it.origin.isAutomatic && it.status != OfflineStatus.FAILED }
                    .sumOf { it.sizeBytes }
                var pool = deletable
                for (episode in missing) {
                    val ref = OfflineRef(series.profileId, series.titleKey, episode.id)
                    SmartDownloadGates.attemptBlock(history.attempt(ref), nowMs)?.let { blocked += BlockedItem(label(series, episode.id), it); continue }

                    // The replacement is prepared first. A finished episode is only given up early when it cannot fit otherwise.
                    var free = freeBytes
                    var automatic = automaticBytes
                    var profile = profileBytes
                    var remaining = pool
                    val freedNow = ArrayList<OfflineEntry>()
                    var reason = SmartDownloadGates.fitBlock(episode.estimatedBytes, free, automatic, profile, settings)
                    while (reason != null && remaining.isNotEmpty()) {
                        val victim = remaining.first()
                        remaining = remaining.drop(1)
                        freedNow += victim
                        free += victim.sizeBytes
                        if (victim.origin.isAutomatic) {
                            automatic -= victim.sizeBytes
                            profile -= victim.sizeBytes
                        }
                        reason = SmartDownloadGates.fitBlock(episode.estimatedBytes, free, automatic, profile, settings)
                    }
                    if (reason != null) {
                        blocked += BlockedItem(label(series, episode.id), reason)
                        continue
                    }
                    enqueue += PlannedDownload(
                        series.profileId, series.titleKey, episode.id, DownloadOrigin.NEXT_EPISODE, episode.estimatedBytes,
                        replacesFailed = failed[episode.id]?.origin?.isAutomatic == true,
                    )
                    remove += freedNow.map { it.ref }
                    pool = remaining
                    freeBytes = free - episode.estimatedBytes
                    automaticBytes = automatic + episode.estimatedBytes
                    profileBytes = profile + episode.estimatedBytes
                }
            }
        } else if (replacementsReady) {
            // Everything that should be on the device is, so what the viewer has finished can go.
            remove += deletable.map { it.ref }
        }
        return SmartDownloadPlan(enqueue = enqueue, remove = remove, cancel = emptyList(), blocked = blocked)
    }

    private fun label(series: SeriesContext, id: EpisodeId) = "${series.titleKey} S${id.season}E${id.episode}"
}
