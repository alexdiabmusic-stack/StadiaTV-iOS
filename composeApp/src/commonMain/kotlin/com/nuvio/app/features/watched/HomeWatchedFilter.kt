package com.nuvio.app.features.watched

import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.watching.application.WatchingState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Remembers the "hide watched titles in discovery rows" switch on this device. */
internal expect object HomeWatchedFilterStorage {
    fun load(): Boolean?
    fun save(hide: Boolean)
}

/**
 * Discovery rows (Home's trending, genre and personal rows, Recommended) leave out films the member has already watched, and
 * series they have finished. On by default; the switch is in Settings > Layout > Homescreen. Rows that are meant to show a
 * fixed set (Top 10, collections, My List, Library) keep every title and mark the watched ones instead.
 */
internal object HomeWatchedFilter {
    private val _hide = MutableStateFlow(HomeWatchedFilterStorage.load() ?: true)
    val hideWatched: StateFlow<Boolean> = _hide.asStateFlow()

    fun setHideWatched(hide: Boolean) {
        _hide.value = hide
        HomeWatchedFilterStorage.save(hide)
    }
}

/** [this] without the watched titles when [hide] is on; otherwise unchanged. */
internal fun List<MetaPreview>.withoutWatched(hide: Boolean, watchedKeys: Set<String>, fullyWatchedSeriesKeys: Set<String>): List<MetaPreview> =
    if (!hide || watchedKeys.isEmpty()) this
    else filterNot { WatchingState.isPosterWatched(watchedKeys, it, fullyWatchedSeriesKeys) }
