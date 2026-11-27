package com.nuvio.app

import com.nuvio.app.core.ui.NuvioToastController
import com.nuvio.app.features.livetv.LiveTvRepository
import com.nuvio.app.features.notifications.EpisodeReleaseNotificationPlatform
import com.nuvio.app.features.sports.SportsHost
import com.nuvio.app.features.sports.compat.SportsLiveTvHost
import com.nuvio.app.features.sports.compat.SportsLiveTvSnapshot
import com.nuvio.app.features.sports.compat.SportsLiveTvSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn

/** Connects the Sports hub (in the shared core) to this app's toast, notification permission and Live TV. */
internal fun installSportsHost() {
    SportsHost.toast = { text, millis -> NuvioToastController.show(text, durationMillis = millis) }
    SportsHost.requestNotifications = { EpisodeReleaseNotificationPlatform.requestAuthorization() }
    SportsLiveTvHost.source = object : SportsLiveTvSource {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        override val snapshot: StateFlow<SportsLiveTvSnapshot> = LiveTvRepository.uiState
            .map { SportsLiveTvSnapshot(it.channels, it.isLoading, it.isEpgLoading, it.epgPrograms) }
            .stateIn(scope, SharingStarted.Eagerly, SportsLiveTvSnapshot())

        override fun ensureLoaded() {
            LiveTvRepository.ensureLoaded()
            LiveTvRepository.ensureChannelsLoaded()
        }
    }
}
