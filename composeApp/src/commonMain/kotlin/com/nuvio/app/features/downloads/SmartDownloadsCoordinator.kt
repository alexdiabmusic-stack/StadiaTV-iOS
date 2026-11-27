package com.nuvio.app.features.downloads

import com.nuvio.app.core.logging.InAppLogger
import com.nuvio.app.core.network.NetworkStatusRepository
import com.nuvio.app.features.debrid.DirectDebridPlayableResult
import com.nuvio.app.features.debrid.DirectDebridPlaybackResolver
import com.nuvio.app.features.details.MetaDetails
import com.nuvio.app.features.details.MetaDetailsRepository
import com.nuvio.app.features.player.PlayerStreamsRepository
import com.nuvio.app.features.playback.CompletionLedger
import com.nuvio.app.features.profiles.ProfileRepository
import com.nuvio.app.features.smartdownloads.CatalogEpisode
import com.nuvio.app.features.smartdownloads.DeviceConditions
import com.nuvio.app.features.smartdownloads.DownloadFailures
import com.nuvio.app.features.smartdownloads.DownloadOrigin
import com.nuvio.app.features.smartdownloads.DownloadRecovery
import com.nuvio.app.features.smartdownloads.DownloadSourceSelector
import com.nuvio.app.features.smartdownloads.DownloadableSource
import com.nuvio.app.features.smartdownloads.EpisodeId
import com.nuvio.app.features.smartdownloads.EstimatedDownloadSize
import com.nuvio.app.features.smartdownloads.NextEpisodePlanner
import com.nuvio.app.features.smartdownloads.OfflineEntry
import com.nuvio.app.features.smartdownloads.OfflineRef
import com.nuvio.app.features.smartdownloads.OfflineStatus
import com.nuvio.app.features.smartdownloads.PlannedDownload
import com.nuvio.app.features.smartdownloads.RecoveryAction
import com.nuvio.app.features.smartdownloads.ReleaseDates
import com.nuvio.app.features.smartdownloads.SeriesContext
import com.nuvio.app.features.smartdownloads.SmartDownloadHistoryStore
import com.nuvio.app.features.smartdownloads.SmartDownloadPlan
import com.nuvio.app.features.smartdownloads.SmartDownloadSettings
import com.nuvio.app.features.streams.StreamItem
import com.nuvio.app.features.watched.WatchedRepository
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Runs Download Next Episode. The decisions are made by [NextEpisodePlanner] in the shared core; this reads the app's state
 * into the planner's terms, then carries out the plan through the existing [DownloadsRepository].
 *
 * It works whenever the app does something that could change the answer (an episode is finished, a download completes or
 * fails, the player closes, a setting changes, the app starts). It does not schedule work for when the app is closed: the
 * operating system keeps transfers it already has running, and the next run picks up from there.
 */
internal object SmartDownloadsCoordinator {
    private const val TAG = "Downloads/Smart"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mutex = Mutex()
    private val history by lazy { SmartDownloadHistoryStore(CoreKeyValueStateStore) }
    private val ledger by lazy { CompletionLedger(CoreKeyValueStateStore) }

    /** Looks at every downloaded series, or just [titleId]. */
    fun requestRun(titleId: String? = null) {
        scope.launch {
            mutex.withLock {
                try {
                    runPass(titleId)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    InAppLogger.warn(TAG, "pass failed: ${error.message}")
                }
            }
        }
    }

    /** The viewer finished an episode. */
    fun onEpisodeCompleted(parentMetaId: String) = requestRun(parentMetaId)

    fun onDownloadCompleted(item: DownloadItem) {
        if (item.downloadOrigin.isAutomatic) history.recordSuccess(item.toRef(), DownloadsClock.nowEpochMs())
        // The replacement is on the device now, so what the viewer has finished can be cleared.
        if (item.isEpisode) requestRun(item.parentMetaId)
    }

    fun onDownloadFailed(item: DownloadItem, message: String) {
        if (!item.downloadOrigin.isAutomatic) return
        val kind = DownloadFailures.classify(httpStatus = null, message = message)
        val attemptsSoFar = history.attempt(item.toRef())?.attempts ?: 0
        val recovery = DownloadRecovery.next(kind, attemptsSoFar)
        InAppLogger.info(TAG, "download failed kind=$kind action=${recovery.action} title=${item.parentMetaId}")
        // A link that stopped working is replaced at once with a fresh one; anything else waits out the planner's back-off.
        history.recordAttempt(item.toRef(), DownloadsClock.nowEpochMs(), retryImmediately = recovery.action == RecoveryAction.REFRESH_SOURCE_AND_RETRY)
        if (recovery.action == RecoveryAction.REFRESH_SOURCE_AND_RETRY && item.isEpisode) requestRun(item.parentMetaId)
    }

    /** The viewer removed an automatic download: it is not brought back. */
    fun onUserRemoved(item: DownloadItem) {
        history.markUserRemoved(item.toRef())
    }

    private fun DownloadItem.toRef() = OfflineRef(
        profileId = ProfileRepository.activeProfileId,
        titleKey = parentMetaId,
        episode = if (seasonNumber != null && episodeNumber != null) EpisodeId(seasonNumber, episodeNumber) else null,
    )

    private fun DownloadItem.toEntry(profileId: Int) = OfflineEntry(
        profileId = profileId,
        titleKey = parentMetaId,
        episode = if (seasonNumber != null && episodeNumber != null) EpisodeId(seasonNumber, episodeNumber) else null,
        origin = downloadOrigin,
        status = when (status) {
            DownloadStatus.Downloading -> OfflineStatus.DOWNLOADING
            DownloadStatus.Paused -> OfflineStatus.PAUSED
            DownloadStatus.Completed -> OfflineStatus.COMPLETED
            DownloadStatus.Failed -> OfflineStatus.FAILED
        },
        sizeBytes = totalBytes ?: downloadedBytes,
        pinned = pinned,
        playingNow = DownloadsRepository.isNowPlaying(this),
        createdAtMs = createdAtEpochMs,
    )

    private suspend fun runPass(onlyTitleId: String?) {
        SmartDownloadsSettingsRepository.ensureLoaded()
        DownloadsRepository.ensureLoaded()
        val settings = SmartDownloadsSettingsRepository.effective()
        val items = DownloadsRepository.uiState.value.items
        // Nothing to start, and nothing of ours still running that a switched-off setting should stop.
        if (!settings.nextEpisodeEnabled && items.none { it.downloadOrigin.isAutomatic && it.status != DownloadStatus.Completed }) return

        val titleIds = items.filter { it.isEpisode && (onlyTitleId == null || it.parentMetaId == onlyTitleId) }.map { it.parentMetaId }.distinct()
        for (titleId in titleIds) planAndApply(titleId, settings)
    }

    private suspend fun planAndApply(titleId: String, settings: SmartDownloadSettings) {
        val profileId = ProfileRepository.activeProfileId
        val now = DownloadsClock.nowEpochMs()
        val items = DownloadsRepository.uiState.value.items
        val mine = items.filter { it.parentMetaId == titleId && it.isEpisode }
        val type = mine.firstOrNull()?.parentMetaType ?: return

        // The episode list is needed to know what comes next. Without it (offline, no metadata) nothing is decided.
        val meta = MetaDetailsRepository.fetch(type = type, id = titleId) ?: return
        val episodes = meta.videos.mapNotNull { video ->
            val season = video.season ?: return@mapNotNull null
            val episode = video.episode ?: return@mapNotNull null
            if (season <= 0) return@mapNotNull null
            CatalogEpisode(
                id = EpisodeId(season, episode),
                aired = ReleaseDates.hasAired(video.released, video.available, now),
                estimatedBytes = EstimatedDownloadSize.forRuntime(video.runtime, settings.quality),
            )
        }.distinctBy { it.id }

        // "Finished" comes from the shared completion events, with the app's existing watched state for what was seen before they existed.
        val mediaKey = "series:$titleId"
        val watched = episodes.filter { episode ->
            ledger.hasCompleted(profileId, mediaKey, "s${episode.id.season}e${episode.id.episode}") ||
                WatchedRepository.isWatched(id = titleId, type = type, season = episode.id.season, episode = episode.id.episode)
        }.map { it.id }.toSet()

        val conditions = DeviceConditions(
            online = !NetworkStatusRepository.uiState.value.isOfflineLike,
            onWifi = DownloadNetworkGuard.isOnWifi(),
            charging = false,
            freeStorageBytes = DeviceStorage.freeBytes() ?: Long.MAX_VALUE / 4,
        )
        val plan = NextEpisodePlanner.plan(
            settings = settings,
            conditions = conditions,
            series = SeriesContext(profileId, titleId, episodes, watched, restricted = false),
            deviceEntries = items.map { it.toEntry(profileId) },
            history = history,
            nowMs = now,
        )
        if (!plan.isEmpty || plan.blocked.isNotEmpty()) {
            InAppLogger.info(
                TAG,
                "plan title=$titleId enqueue=${plan.enqueue.size} remove=${plan.remove.size} cancel=${plan.cancel.size} blocked=${plan.blocked.map { it.reason }}",
            )
        }
        apply(plan, meta, type, settings)
    }

    private suspend fun apply(plan: SmartDownloadPlan, meta: MetaDetails, type: String, settings: SmartDownloadSettings) {
        if (plan.cancel.isNotEmpty() || plan.remove.isNotEmpty()) {
            withContext(Dispatchers.Main) {
                (plan.cancel + plan.remove).forEach { ref -> find(ref)?.let { DownloadsRepository.cancelDownload(it.id, byUser = false) } }
            }
        }
        for (planned in plan.enqueue) enqueue(planned, meta, type, settings)
    }

    private fun find(ref: OfflineRef): DownloadItem? = DownloadsRepository.uiState.value.items.firstOrNull {
        it.parentMetaId == ref.titleKey && it.seasonNumber == ref.episode?.season && it.episodeNumber == ref.episode?.episode
    }

    private suspend fun enqueue(planned: PlannedDownload, meta: MetaDetails, type: String, settings: SmartDownloadSettings) {
        val episode = planned.episode ?: return
        val video = meta.videos.firstOrNull { it.season == episode.season && it.episode == episode.episode } ?: return
        val ref = OfflineRef(planned.profileId, planned.titleKey, episode)
        val items = DownloadsRepository.uiState.value.items
        // Counted up front: a success clears it, and a try that never finishes still moves toward the limit.
        history.recordAttempt(ref, DownloadsClock.nowEpochMs())

        val streams = PlayerStreamsRepository.fetchOnce(type = type, videoId = video.id, season = episode.season, episode = episode.episode)
        val preferredAddon = items.firstOrNull { it.parentMetaId == planned.titleKey && !it.providerAddonId.isNullOrBlank() }?.providerAddonId
        val chosen = chooseStream(streams, settings, preferredAddon, episode.season, episode.episode)
        if (chosen == null) {
            InAppLogger.info(TAG, "no downloadable source for ${planned.titleKey} S${episode.season}E${episode.episode} (streams=${streams.size})")
            return
        }
        val result = withContext(Dispatchers.Main) {
            if (planned.replacesFailed) find(ref)?.let { DownloadsRepository.cancelDownload(it.id, byUser = false) }
            DownloadsRepository.enqueueFromStream(
                contentType = type,
                videoId = video.id,
                parentMetaId = meta.id,
                parentMetaType = meta.type,
                title = meta.name,
                logo = meta.logo,
                poster = meta.poster,
                background = meta.background,
                seasonNumber = episode.season,
                episodeNumber = episode.episode,
                episodeTitle = video.title,
                episodeThumbnail = video.thumbnail,
                stream = chosen,
                origin = DownloadOrigin.NEXT_EPISODE,
            )
        }
        InAppLogger.info(TAG, "enqueued ${planned.titleKey} S${episode.season}E${episode.episode}: $result")
    }

    /** A stream with a direct file link wins; failing that, a few debrid-resolvable ones are tried in the order the providers listed them. */
    private suspend fun chooseStream(
        streams: List<StreamItem>,
        settings: SmartDownloadSettings,
        preferredAddonId: String?,
        season: Int,
        episode: Int,
    ): StreamItem? {
        val direct = streams.mapIndexedNotNull { index, stream ->
            val url = stream.playableDirectUrl ?: return@mapIndexedNotNull null
            if (DirectDebridPlaybackResolver.shouldResolveToPlayableStream(stream)) return@mapIndexedNotNull null
            DownloadableSource(
                id = index.toString(),
                addonId = stream.addonId,
                url = url,
                resolutionHeight = DownloadSourceSelector.resolutionFromLabel(stream.name, stream.title, stream.description),
            )
        }
        DownloadSourceSelector.pick(direct, settings.quality, preferredAddonId)?.let { picked -> return streams[picked.id.toInt()] }

        val resolvable = streams.filter { DirectDebridPlaybackResolver.shouldResolveToPlayableStream(it) }.take(MAX_DEBRID_TRIES)
        for (stream in resolvable) {
            val resolved = DirectDebridPlaybackResolver.resolveToPlayableStream(stream = stream, season = season, episode = episode)
            if (resolved is DirectDebridPlayableResult.Success && resolved.stream.playableDirectUrl?.let(DownloadSourceSelector::isDownloadable) == true) {
                return resolved.stream
            }
        }
        return null
    }

    private const val MAX_DEBRID_TRIES = 3
}
