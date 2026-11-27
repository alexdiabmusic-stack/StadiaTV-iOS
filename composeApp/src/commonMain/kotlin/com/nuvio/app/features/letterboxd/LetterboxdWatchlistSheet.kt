package com.nuvio.app.features.letterboxd

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.format.formatLocalDateTime
import com.nuvio.app.core.ui.NuvioModalBottomSheet
import com.nuvio.app.core.ui.dismissNuvioBottomSheet
import kotlinx.coroutines.launch

/** The member's Letterboxd watchlist, as last read in full, with a way to read it again. Read only: nothing here writes to Letterboxd. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LetterboxdWatchlistSheet(onDismiss: () -> Unit) {
    val manager = LetterboxdRuntime.manager
    val profileId = rememberLetterboxdProfileId()
    val lists by manager.watchlistFlow.collectAsStateWithLifecycle()
    val accounts by manager.accountsFlow.collectAsStateWithLifecycle()
    val status by manager.importStatus.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf<String?>(null) }
    val snapshot = lists[profileId]
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState, fullHeight = true) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Letterboxd watchlist", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text(
                        snapshot?.let { "${LetterboxdScreenText.films(it.films.size)} · read ${formatLocalDateTime(it.completeAtMs)}" } ?: "Not read yet",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                OutlinedButton(
                    enabled = !refreshing && accounts[profileId] != null,
                    onClick = {
                        scope.launch {
                            refreshing = true; note = null
                            val r = manager.importWatchlist(profileId)
                            note = if (r.films == null) (r.message ?: "The watchlist could not be read completely, so the last full copy was kept.") else null
                            refreshing = false
                        }
                    },
                ) { Text(if (refreshing) (status ?: "Refreshing…") else "Refresh") }
            }
            note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 6.dp)) }
            Text("Read only: editing the watchlist is not supported from BannerTV.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp, bottom = 8.dp))
            if (snapshot == null || snapshot.films.isEmpty()) {
                Text(if (snapshot == null) "Tap Refresh to read your watchlist." else "Your watchlist is empty.", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 24.dp))
            } else {
                LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(0.dp)) {
                    items(snapshot.films, key = { it.slug }) { film ->
                        Column(modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                            Text(film.title, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            film.year?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        }
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f))
                    }
                }
            }
            TextButton(onClick = close, modifier = Modifier.padding(bottom = 16.dp)) { Text("Close") }
        }
    }
}
