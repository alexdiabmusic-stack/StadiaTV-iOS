package com.nuvio.app.features.explore

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Everything a collection page remembers about how the member was browsing it: the filters, the sort, how far they had scrolled
 * and the titles it had found. It lives outside the screen so opening a title and coming back (Back or the swipe) lands on the
 * same row, with the same filters, instead of the top of a reloaded page. One state per collection, so one collection's
 * position is never applied to another.
 */
internal class CollectionBrowseState(val collectionId: String) {
    var filters by mutableStateOf(BrowseFilters())
    var sort by mutableStateOf(BrowseSort.Curated)

    /** The chapter (shelf) the member last jumped to, for the chapter chips. */
    var chapter by mutableStateOf<String?>(null)

    /** The page's scroll position. Held here, not in the composition, so it outlasts the screen being left. */
    val listState = LazyListState()

    /** The titles last found, shown at once on return while the page checks for fresh ones. */
    var resolved by mutableStateOf<ResolvedCollection?>(null)

    /** Runtimes looked up for this collection's titles, by title id (only filled when a runtime filter or sort is used). */
    var runtimes by mutableStateOf<Map<String, Int>>(emptyMap())
}

/** The browse states of the collections visited this session, the most recent few. */
internal object CollectionBrowseStore {
    private const val MAX = 16
    private val states = LinkedHashMap<String, CollectionBrowseState>()

    fun of(collectionId: String): CollectionBrowseState {
        val existing = states.remove(collectionId)
        val state = existing ?: CollectionBrowseState(collectionId)
        states[collectionId] = state // most recently used last
        while (states.size > MAX) states.remove(states.keys.first())
        return state
    }
}

/**
 * The top of a collection page, from the screen's top inset. On iOS with native navigation the inset already includes the native
 * navigation bar (which draws Back itself), so the page adds no bar of its own and only a title beside the native button; elsewhere
 * (Android, and the Search tab, which has no native bar) the page draws its own 48 dp bar under the status bar.
 */
internal class PageTop(val inset: androidx.compose.ui.unit.Dp, val native: Boolean) {
    /** Where content below the bar starts. */
    val barHeight: androidx.compose.ui.unit.Dp get() = if (native) inset else inset + 48.dp
    /** The top of the strip the title and (when drawn here) Back sit in, and its height. */
    val stripTop: androidx.compose.ui.unit.Dp get() = if (native) (inset - NATIVE_BAR).coerceAtLeast(0.dp) else inset
    val stripHeight: androidx.compose.ui.unit.Dp get() = if (native) NATIVE_BAR.coerceAtMost(inset) else 48.dp
    /** Space above a hero's text block so it clears the bar. */
    val heroTextTop: androidx.compose.ui.unit.Dp get() = if (native) inset + 8.dp else inset + 56.dp
    /** Where the title starts: after the native Back button when that draws it. */
    val titleStart: androidx.compose.ui.unit.Dp get() = if (native) 64.dp else 12.dp

    private companion object { val NATIVE_BAR = 54.dp }
}

@androidx.compose.runtime.Composable
internal fun rememberPageTop(alwaysShowBack: Boolean): PageTop {
    val inset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val native = com.nuvio.app.navigation.LocalUseNativeNavigation.current && !com.nuvio.app.navigation.LocalNativeNavigationBarHidden.current && !alwaysShowBack
    return androidx.compose.runtime.remember(inset, native) { PageTop(inset, native) }
}

/** Keeps content clear of the screen's side safe area (the Dynamic Island or the rounded corners in landscape). */
@androidx.compose.runtime.Composable
internal fun Modifier.sideSafe(): Modifier = windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal))
