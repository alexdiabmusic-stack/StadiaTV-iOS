package com.nuvio.app.features.settings

import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.ui.Chip
import com.nuvio.app.features.downloads.SmartDownloadsSettingsRepository
import com.nuvio.app.features.smartdownloads.AutoDeletePolicy
import com.nuvio.app.features.smartdownloads.DownloadQuality
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.smart_downloads_count
import nuvio.composeapp.generated.resources.smart_downloads_delete_all
import nuvio.composeapp.generated.resources.smart_downloads_delete_automatic
import nuvio.composeapp.generated.resources.smart_downloads_delete_description
import nuvio.composeapp.generated.resources.smart_downloads_delete_never
import nuvio.composeapp.generated.resources.smart_downloads_delete_title
import nuvio.composeapp.generated.resources.smart_downloads_limit_gb
import nuvio.composeapp.generated.resources.smart_downloads_limit_none
import nuvio.composeapp.generated.resources.smart_downloads_next_episode_description
import nuvio.composeapp.generated.resources.smart_downloads_next_episode_title
import nuvio.composeapp.generated.resources.smart_downloads_quality_data_saver
import nuvio.composeapp.generated.resources.smart_downloads_quality_description
import nuvio.composeapp.generated.resources.smart_downloads_quality_high
import nuvio.composeapp.generated.resources.smart_downloads_quality_standard
import nuvio.composeapp.generated.resources.smart_downloads_quality_title
import nuvio.composeapp.generated.resources.smart_downloads_storage_limit_description
import nuvio.composeapp.generated.resources.smart_downloads_storage_limit_title
import nuvio.composeapp.generated.resources.smart_downloads_title
import nuvio.composeapp.generated.resources.smart_downloads_upcoming_description
import nuvio.composeapp.generated.resources.smart_downloads_upcoming_title
import org.jetbrains.compose.resources.stringResource

private val StorageLimitChoicesGb = listOf(2, 5, 10, 25, 0)

/**
 * Smart Downloads. Download Next Episode is the one switch; the limit and quality sit beneath it, and what happens to finished
 * episodes and how many to keep ready are the two advanced choices. Downloads for You has no control here until it is wired.
 */
internal fun LazyListScope.smartDownloadsSettingsContent(isTablet: Boolean) {
    item {
        SmartDownloadsSettingsRepository.ensureLoaded()
        val settings by SmartDownloadsSettingsRepository.settings.collectAsStateWithLifecycle()
        val limitGb = settings.storageLimitBytes?.let { (it / (1024L * 1024L * 1024L)).toInt() } ?: 0

        SettingsSection(
            title = stringResource(Res.string.smart_downloads_title),
            isTablet = isTablet,
        ) {
            SettingsGroup(isTablet = isTablet) {
                SettingsSwitchRow(
                    title = stringResource(Res.string.smart_downloads_next_episode_title),
                    description = stringResource(Res.string.smart_downloads_next_episode_description),
                    checked = settings.nextEpisodeEnabled,
                    isTablet = isTablet,
                    onCheckedChange = SmartDownloadsSettingsRepository::setNextEpisodeEnabled,
                )
                SettingsGroupDivider(isTablet = isTablet)
                SettingsChipRow(
                    title = stringResource(Res.string.smart_downloads_storage_limit_title),
                    description = stringResource(Res.string.smart_downloads_storage_limit_description),
                    isTablet = isTablet,
                ) {
                    StorageLimitChoicesGb.forEach { gb ->
                        Chip(
                            label = if (gb == 0) stringResource(Res.string.smart_downloads_limit_none) else stringResource(Res.string.smart_downloads_limit_gb, gb),
                            selected = limitGb == gb,
                            onClick = { SmartDownloadsSettingsRepository.setStorageLimitGb(gb) },
                        )
                    }
                }
                SettingsGroupDivider(isTablet = isTablet)
                SettingsChipRow(
                    title = stringResource(Res.string.smart_downloads_quality_title),
                    description = stringResource(Res.string.smart_downloads_quality_description),
                    isTablet = isTablet,
                ) {
                    DownloadQuality.entries.forEach { quality ->
                        Chip(
                            label = stringResource(
                                when (quality) {
                                    DownloadQuality.DATA_SAVER -> Res.string.smart_downloads_quality_data_saver
                                    DownloadQuality.STANDARD -> Res.string.smart_downloads_quality_standard
                                    DownloadQuality.HIGH -> Res.string.smart_downloads_quality_high
                                },
                            ),
                            selected = settings.quality == quality,
                            onClick = { SmartDownloadsSettingsRepository.setQuality(quality) },
                        )
                    }
                }
                SettingsGroupDivider(isTablet = isTablet)
                SettingsChipRow(
                    title = stringResource(Res.string.smart_downloads_upcoming_title),
                    description = stringResource(Res.string.smart_downloads_upcoming_description),
                    isTablet = isTablet,
                ) {
                    (1..3).forEach { count ->
                        Chip(
                            label = stringResource(Res.string.smart_downloads_count, count),
                            selected = settings.upcoming == count,
                            onClick = { SmartDownloadsSettingsRepository.setUpcomingEpisodes(count) },
                        )
                    }
                }
                SettingsGroupDivider(isTablet = isTablet)
                SettingsChipRow(
                    title = stringResource(Res.string.smart_downloads_delete_title),
                    description = stringResource(Res.string.smart_downloads_delete_description),
                    isTablet = isTablet,
                ) {
                    AutoDeletePolicy.entries.forEach { policy ->
                        Chip(
                            label = stringResource(
                                when (policy) {
                                    AutoDeletePolicy.NEVER -> Res.string.smart_downloads_delete_never
                                    AutoDeletePolicy.AUTOMATIC_ONLY -> Res.string.smart_downloads_delete_automatic
                                    AutoDeletePolicy.ALL_WATCHED -> Res.string.smart_downloads_delete_all
                                },
                            ),
                            selected = settings.autoDelete == policy,
                            onClick = { SmartDownloadsSettingsRepository.setAutoDelete(policy) },
                        )
                    }
                }
            }
        }
    }
}
