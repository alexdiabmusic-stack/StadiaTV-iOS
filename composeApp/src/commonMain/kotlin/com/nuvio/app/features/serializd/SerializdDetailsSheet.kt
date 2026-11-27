package com.nuvio.app.features.serializd

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nuvio.app.core.format.formatLocalDateTime
import com.nuvio.app.core.ui.NuvioModalBottomSheet
import com.nuvio.app.core.ui.dismissNuvioBottomSheet
import kotlinx.coroutines.launch

/**
 * The numbers behind "Watch history" and the last import: what was added, what was already here, what could not be matched and which
 * shows were placed by season count. Everything shown is kept from the last real import; nothing here runs one.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SerializdWatchHistorySheet(state: SerializdScreenState, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }
    val stats = state.importStats

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState, fullHeight = false) {
        Column(modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Watch history", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(state.watchHistoryLine, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (stats == null) {
                Text(
                    if (state.trackedEpisodes > 0) "Details of earlier imports were not kept. Run Import from Serializd once and the numbers will show here."
                    else "Nothing has been imported yet. Use Import from Serializd to bring in what you have already watched there.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 12.dp, bottom = 16.dp),
                )
            } else {
                Text("Last import ${formatLocalDateTime(stats.atMs)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                DetailLine("Added", SerializdScreenText.grouped(stats.added))
                DetailLine("Already known", SerializdScreenText.grouped(stats.alreadyKnown))
                DetailLine("Not matched", SerializdScreenText.grouped(stats.unmatched))
                if (stats.placedByCount.isNotEmpty()) DetailLine("Placed by season count", SerializdScreenText.grouped(stats.placedByCount.size))
                DetailLine("Diary entries read", SerializdScreenText.grouped(stats.diaryEntries))
                DetailLine("Watched shows read", SerializdScreenText.grouped(stats.watchedShows))
                if (stats.partial) Text("This import stopped early. Run it again to continue.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp))
                if (stats.notMatched.isNotEmpty()) {
                    Section("Not matched", stats.notMatched, "Serializd no longer lists these seasons, so they could not be placed without guessing.")
                }
                if (stats.placedByCount.isNotEmpty()) {
                    Section("Placed by season count", stats.placedByCount, "Serializd re-created these seasons' ids. Every season was marked watched, so each was placed by counting.")
                }
            }
            Text("Imported history is never sent back to Serializd.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 12.dp, bottom = 20.dp))
        }
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.25f))
}

@Composable
private fun Section(title: String, items: List<String>, note: String) {
    Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 16.dp))
    Text(note, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 4.dp))
    items.forEach { Text(it, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 2.dp)) }
}
