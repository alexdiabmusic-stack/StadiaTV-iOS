package com.nuvio.app.features.downloads

import com.nuvio.app.features.playback.PlaybackStateStore
import com.nuvio.app.features.smartdownloads.AutoDeletePolicy
import com.nuvio.app.features.smartdownloads.DownloadQuality
import com.nuvio.app.features.smartdownloads.SmartDownloadSettings
import com.nuvio.app.features.tmdb.CoreKeyValue
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** [PlaybackStateStore] over the shared key-value store, for the Smart Downloads history and completion ledger. */
internal object CoreKeyValueStateStore : PlaybackStateStore {
    override fun get(store: String, key: String): String? = CoreKeyValue.getString(store, key)
    override fun put(store: String, key: String, value: String) = CoreKeyValue.putString(store, key, value)
}

/**
 * Smart Downloads preferences. Device-level like the other download settings. Both automatic features are opt-in, and
 * whether mobile data may be used is the existing "Allow mobile data" setting rather than a second switch.
 */
object SmartDownloadsSettingsRepository {
    @Serializable
    private data class Stored(
        val nextEpisodeEnabled: Boolean = false,
        /** 0 means no limit. */
        val storageLimitGb: Int = 10,
        val quality: String = DownloadQuality.STANDARD.name,
        val upcomingEpisodes: Int = 1,
        val autoDelete: String = AutoDeletePolicy.AUTOMATIC_ONLY.name,
    )

    private const val STORE = "smart_downloads"
    private const val KEY = "settings"
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    private val _settings = MutableStateFlow(SmartDownloadSettings())
    val settings: StateFlow<SmartDownloadSettings> = _settings.asStateFlow()
    private var hasLoaded = false

    fun ensureLoaded() {
        if (hasLoaded) return
        hasLoaded = true
        val stored = CoreKeyValue.getString(STORE, KEY)?.let { runCatching { json.decodeFromString(Stored.serializer(), it) }.getOrNull() } ?: return
        _settings.value = SmartDownloadSettings(
            nextEpisodeEnabled = stored.nextEpisodeEnabled,
            storageLimitBytes = if (stored.storageLimitGb <= 0) null else stored.storageLimitGb * GIB,
            quality = DownloadQuality.entries.firstOrNull { it.name == stored.quality } ?: DownloadQuality.STANDARD,
            upcomingEpisodes = stored.upcomingEpisodes,
            autoDelete = AutoDeletePolicy.entries.firstOrNull { it.name == stored.autoDelete } ?: AutoDeletePolicy.AUTOMATIC_ONLY,
        )
    }

    /**
     * What the planners are given: the saved choices plus the existing mobile-data setting. Downloads for You has no switch
     * yet, so it is held off here whatever is saved.
     */
    fun effective(): SmartDownloadSettings {
        ensureLoaded()
        DownloadsSettingsRepository.ensureLoaded()
        return _settings.value.copy(
            wifiOnly = !DownloadsSettingsRepository.allowMobileDataDownloads.value,
            forYouEnabled = false,
        )
    }

    fun setNextEpisodeEnabled(enabled: Boolean) = update { it.copy(nextEpisodeEnabled = enabled) }
    fun setStorageLimitGb(gb: Int) = update { it.copy(storageLimitBytes = if (gb <= 0) null else gb * GIB) }
    fun setQuality(quality: DownloadQuality) = update { it.copy(quality = quality) }
    fun setUpcomingEpisodes(count: Int) = update { it.copy(upcomingEpisodes = count.coerceIn(1, 3)) }
    fun setAutoDelete(policy: AutoDeletePolicy) = update { it.copy(autoDelete = policy) }

    private fun update(change: (SmartDownloadSettings) -> SmartDownloadSettings) {
        ensureLoaded()
        val next = change(_settings.value)
        if (next == _settings.value) return
        _settings.value = next
        CoreKeyValue.putString(
            STORE, KEY,
            json.encodeToString(
                Stored.serializer(),
                Stored(
                    nextEpisodeEnabled = next.nextEpisodeEnabled,
                    storageLimitGb = next.storageLimitBytes?.let { (it / GIB).toInt() } ?: 0,
                    quality = next.quality.name,
                    upcomingEpisodes = next.upcoming,
                    autoDelete = next.autoDelete.name,
                ),
            ),
        )
        // A change can start work (turned on) or stop it (turned off, a smaller limit), so look again now.
        SmartDownloadsCoordinator.requestRun()
    }

    private const val GIB = 1024L * 1024L * 1024L
}
