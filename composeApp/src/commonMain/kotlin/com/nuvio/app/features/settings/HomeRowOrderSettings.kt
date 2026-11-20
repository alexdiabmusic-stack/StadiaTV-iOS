package com.nuvio.app.features.settings

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Menu
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.ui.NuvioActionLabel
import com.nuvio.app.features.home.HomeCatalogSettingsRepository
import com.nuvio.app.features.home.HomeRowInfo
import com.nuvio.app.features.home.HomeRowOrder
import com.nuvio.app.features.home.HomeRowRegistry
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.action_reorder
import org.jetbrains.compose.resources.stringResource
import sh.calvin.reorderable.ReorderableItem
import sh.calvin.reorderable.rememberReorderableLazyListState

/**
 * Lets the person put the Home rows in the order they like: hold a row's handle and drag it. The order belongs to the
 * profile and syncs to its other devices (iOS, Android and the TV app), so it is the same everywhere.
 */
@Composable
internal fun HomeRowOrderSection(isTablet: Boolean) {
    val registered by HomeRowRegistry.rows.collectAsStateWithLifecycle()
    val settings by remember { HomeCatalogSettingsRepository.uiState }.collectAsStateWithLifecycle()
    // Home publishes its rows in their default order; the saved order is applied here, so a move (or a reset) shows
    // at once, even before Home has been rebuilt.
    val rows = remember(registered, settings.rowOrder) { HomeRowOrder.apply(registered, settings.rowOrder) { it.id } }
    if (rows.size < 2) return

    SettingsSection(
        title = "Home Row Order",
        isTablet = isTablet,
        actions = {
            if (settings.rowOrder.isNotEmpty()) {
                NuvioActionLabel(text = "Reset", onClick = { HomeCatalogSettingsRepository.setRowOrder(emptyList()) })
            }
        },
    ) {
        val hapticFeedback = LocalHapticFeedback.current
        val lazyListState = rememberLazyListState()
        val reorderableState = rememberReorderableLazyListState(lazyListState = lazyListState) { from, to ->
            val moved = rows.map(HomeRowInfo::id).toMutableList()
            if (from.index !in moved.indices || to.index !in moved.indices) return@rememberReorderableLazyListState
            moved.add(to.index, moved.removeAt(from.index))
            HomeCatalogSettingsRepository.setRowOrder(HomeRowOrder.toSave(settings.rowOrder, moved))
            hapticFeedback.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        }
        SettingsGroup(isTablet = isTablet) {
            LazyColumn(
                modifier = Modifier.fillMaxWidth().heightIn(max = if (isTablet) 900.dp else 560.dp),
                state = lazyListState,
            ) {
                itemsIndexed(rows, key = { _, row -> row.id }) { index, row ->
                    ReorderableItem(reorderableState, key = row.id) { isDragging ->
                        val elevation by animateDpAsState(if (isDragging) 4.dp else 0.dp)
                        Surface(shadowElevation = elevation) {
                            Column {
                                if (index > 0) SettingsGroupDivider(isTablet = isTablet)
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = if (isTablet) 20.dp else 16.dp, vertical = if (isTablet) 10.dp else 6.dp),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        text = row.title,
                                        style = MaterialTheme.typography.bodyLarge,
                                        color = MaterialTheme.colorScheme.onSurface,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f).padding(end = 12.dp),
                                    )
                                    IconButton(
                                        modifier = with(this@ReorderableItem) {
                                            Modifier.draggableHandle(
                                                onDragStarted = { hapticFeedback.performHapticFeedback(HapticFeedbackType.LongPress) },
                                                onDragStopped = { hapticFeedback.performHapticFeedback(HapticFeedbackType.TextHandleMove) },
                                            )
                                        },
                                        onClick = {},
                                    ) {
                                        Icon(
                                            Icons.Rounded.Menu,
                                            contentDescription = stringResource(Res.string.action_reorder),
                                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
