package com.nuvio.app.features.letterboxd

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.StarHalf
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.nuvio.app.core.format.formatLocalDateTime
import com.nuvio.app.core.network.NetworkCondition
import com.nuvio.app.core.network.NetworkStatusRepository
import com.nuvio.app.core.ui.NuvioModalBottomSheet
import com.nuvio.app.core.ui.dismissNuvioBottomSheet
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.coroutines.launch

private val Positive = Color(0xFF3DBE75)
private val Attention = Color(0xFFE5A53A)

/** The active profile's id, following profile switches. */
@Composable
internal fun rememberLetterboxdProfileId(): Int {
    val state by ProfileRepository.state.collectAsStateWithLifecycle()
    return state.activeProfile?.profileIndex ?: ProfileRepository.activeProfileId
}

/** Half-star rating control: the left half of a star is a half, the right half a whole. */
@Composable
internal fun LetterboxdStars(
    stars: Double?,
    onChange: (Double) -> Unit,
    modifier: Modifier = Modifier,
    starSize: Dp = 36.dp,
    enabled: Boolean = true,
) {
    val value = stars ?: 0.0
    Row(modifier = modifier, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (i in 0 until 5) {
            val icon = when {
                value >= i + 1 -> Icons.Rounded.Star
                value >= i + 0.5 -> Icons.Rounded.StarHalf
                else -> Icons.Rounded.StarBorder
            }
            Box(
                modifier = Modifier
                    .size(starSize)
                    .pointerInput(i, enabled) {
                        if (!enabled) return@pointerInput
                        detectTapGestures { offset -> onChange(i + if (offset.x < size.width / 2f) 0.5 else 1.0) }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = if (value >= i + 0.5) Positive else MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(starSize),
                )
            }
        }
    }
}

/** What a viewing's sync looks like to the member, in plain words, and whether it needs them to act. */
internal data class LetterboxdViewingStatus(val label: String, val color: Color, val canLog: Boolean = false)

internal fun letterboxdViewingStatus(viewing: LetterboxdViewing, ops: List<LetterboxdOperation>, hasAccount: Boolean): LetterboxdViewingStatus {
    val mine = ops.filter { it.viewingId == viewing.id }
    val latest = mine.maxByOrNull { it.createdAtMs }
    return when {
        viewing.source == "import" -> LetterboxdViewingStatus("Imported from Letterboxd", Positive)
        viewing.onDiary -> LetterboxdViewingStatus(if (viewing.reviewPublished) "On Letterboxd with review" else "On Letterboxd", Positive)
        viewing.localOnly && latest == null -> LetterboxdViewingStatus("Kept here: already logged that day", MaterialTheme_onVariant)
        latest == null -> LetterboxdViewingStatus(if (hasAccount) "Not sent to Letterboxd" else "Letterboxd not connected", MaterialTheme_onVariant, canLog = hasAccount)
        latest.status == LetterboxdOperationStatus.Pending || latest.status == LetterboxdOperationStatus.InProgress || latest.status == LetterboxdOperationStatus.RetryScheduled ->
            LetterboxdViewingStatus("Waiting to send", Attention)
        latest.status == LetterboxdOperationStatus.NeedsReconnect -> LetterboxdViewingStatus("Reconnect Letterboxd to send", Attention)
        latest.status == LetterboxdOperationStatus.NeedsReconciliation -> LetterboxdViewingStatus("Confirming on your diary", Attention)
        latest.status == LetterboxdOperationStatus.ActionRequired -> LetterboxdViewingStatus("Needs your attention", Attention)
        latest.status == LetterboxdOperationStatus.Failed -> LetterboxdViewingStatus("Could not send", Color(0xFFD9534F))
        latest.status == LetterboxdOperationStatus.Skipped -> LetterboxdViewingStatus("Already on Letterboxd", Positive)
        else -> LetterboxdViewingStatus("On Letterboxd", Positive)
    }
}

private val MaterialTheme_onVariant = Color(0xFF8A8F98)

// ---------------------------------------------------------------------------------------------------- post-watch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LetterboxdPostWatchSheet(viewingId: String, onDismiss: () -> Unit) {
    val manager = LetterboxdRuntime.manager
    val viewings by manager.engine.viewings.collectAsStateWithLifecycle()
    val ops by manager.engine.operations.collectAsStateWithLifecycle()
    val accounts by manager.accountsFlow.collectAsStateWithLifecycle()
    val viewing = viewings.firstOrNull { it.id == viewingId }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var reviewing by remember { mutableStateOf(false) }
    if (viewing == null) { LaunchedEffect(Unit) { onDismiss() }; return }
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }
    val status = letterboxdViewingStatus(viewing, ops, accounts[viewing.profileId] != null)

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("You finished ${viewing.title}", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(status.label, style = MaterialTheme.typography.bodyMedium, color = status.color)
            Text("Rate it", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LetterboxdStars(viewing.stars, onChange = { manager.setRating(viewing.profileId, viewing.tmdbId, viewing.title, it, viewing.id) }, starSize = 44.dp)
            if (viewing.stars != null) {
                Text("${LetterboxdRating.label(viewing.stars)} stars", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(onClick = { reviewing = true }, modifier = Modifier.weight(1f)) { Text("Write a review") }
                if (status.canLog) {
                    Button(onClick = { manager.logViewing(viewing.profileId, viewing.tmdbId, viewing.title, viewing.posterUrl, viewing.stars) }, modifier = Modifier.weight(1f)) { Text("Log to Letterboxd") }
                } else {
                    Button(onClick = close, modifier = Modifier.weight(1f)) { Text("Done") }
                }
            }
            if (status.canLog) TextButton(onClick = close) { Text("Not now") }
        }
    }
    if (reviewing) LetterboxdReviewSheet(viewingId = viewing.id, onDismiss = { reviewing = false })
}

// ---------------------------------------------------------------------------------------------------- review

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LetterboxdReviewSheet(viewingId: String, onDismiss: () -> Unit) {
    val manager = LetterboxdRuntime.manager
    val viewings by manager.engine.viewings.collectAsStateWithLifecycle()
    val viewing = viewings.firstOrNull { it.id == viewingId }
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    var text by remember(viewingId) { mutableStateOf(viewing?.reviewDraft.orEmpty()) }
    var spoilers by remember(viewingId) { mutableStateOf(viewing?.reviewSpoilers ?: false) }
    var message by remember { mutableStateOf<String?>(null) }
    var openUrl by remember { mutableStateOf<String?>(null) }
    if (viewing == null) { LaunchedEffect(Unit) { onDismiss() }; return }
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState, fullHeight = true) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Review ${viewing.title}", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(if (viewing.localDate == LetterboxdViewing.UNDATED) "Watched (date unknown)" else "Watched ${viewing.localDate}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LetterboxdStars(viewing.stars, onChange = { manager.setRating(viewing.profileId, viewing.tmdbId, viewing.title, it, viewing.id) })
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth().height(200.dp),
                label = { Text("Your review") },
                keyboardOptions = KeyboardOptions.Default,
            )
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Contains spoilers", style = MaterialTheme.typography.bodyLarge)
                    Text("Hidden behind a warning on Letterboxd", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(checked = spoilers, onCheckedChange = { spoilers = it })
            }
            message?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface) }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(
                    onClick = { scope.launch { manager.engine.saveReviewDraft(viewing.id, text, spoilers); message = "Draft saved on this device." } },
                    modifier = Modifier.weight(1f),
                ) { Text("Save draft") }
                Button(
                    enabled = text.isNotBlank(),
                    onClick = {
                        scope.launch {
                            when (val outcome = manager.publishReview(viewing.id, text.trim(), spoilers, viewing.stars)) {
                                LetterboxdReviewOutcome.Queued -> { message = "Your review will be posted with this viewing's diary entry."; openUrl = null }
                                is LetterboxdReviewOutcome.DraftKeptOpenLetterboxd -> {
                                    message = "This viewing is already on your Letterboxd diary, and Letterboxd doesn't let BannerTV edit an entry. Your review is saved here. Open the entry on Letterboxd to add it."
                                    openUrl = outcome.url
                                }
                                null -> message = "Could not find this viewing."
                            }
                        }
                    },
                    modifier = Modifier.weight(1f),
                ) { Text("Publish") }
            }
            openUrl?.let { url -> OutlinedButton(onClick = { runCatching { uriHandler.openUri(url) } }, modifier = Modifier.fillMaxWidth()) { Text("Open on Letterboxd") } }
            TextButton(onClick = close) { Text("Close") }
        }
    }
}

// ---------------------------------------------------------------------------------------------------- journal and history

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LetterboxdJournalSheet(onDismiss: () -> Unit) {
    val manager = LetterboxdRuntime.manager
    val profileId = rememberLetterboxdProfileId()
    val viewings by manager.engine.viewings.collectAsStateWithLifecycle()
    val ops by manager.engine.operations.collectAsStateWithLifecycle()
    val accounts by manager.accountsFlow.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var openViewing by remember { mutableStateOf<String?>(null) }
    val mine = remember(viewings, profileId) { viewings.filter { it.profileId == profileId }.sortedByDescending { it.completedAtMs } }
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState, fullHeight = true) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Text("Watch Journal", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                "Films you finished in BannerTV, with how they stand on Letterboxd.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 2.dp, bottom = 12.dp),
            )
            if (mine.isEmpty()) {
                Text("Nothing here yet. Films you finish playing will appear here.", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 24.dp))
            } else {
                LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f, fill = false), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    items(mine, key = { it.id }) { v ->
                        val status = letterboxdViewingStatus(v, ops, accounts[v.profileId] != null)
                        Row(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { openViewing = v.id }.padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(modifier = Modifier.width(44.dp).height(64.dp).clip(RoundedCornerShape(6.dp))) {
                                if (v.posterUrl != null) AsyncImage(model = v.posterUrl, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                                else Surface(color = MaterialTheme.colorScheme.surfaceVariant, modifier = Modifier.fillMaxSize()) {}
                            }
                            Spacer(Modifier.width(12.dp))
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(v.title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(
                                    buildString { append(if (v.localDate == LetterboxdViewing.UNDATED) "Date unknown" else v.localDate); if (v.rewatch) append(" · Rewatch"); v.stars?.let { append(" · ${LetterboxdRating.label(it)}★") }; if (!v.reviewDraft.isNullOrBlank() && !v.reviewPublished) append(" · Draft review") },
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Text(status.label, style = MaterialTheme.typography.bodySmall, color = status.color)
                            }
                        }
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                    }
                }
            }
            TextButton(onClick = close, modifier = Modifier.padding(bottom = 16.dp)) { Text("Close") }
        }
    }
    openViewing?.let { LetterboxdPostWatchSheet(viewingId = it, onDismiss = { openViewing = null }) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LetterboxdHistorySheet(onDismiss: () -> Unit) {
    val manager = LetterboxdRuntime.manager
    val profileId = rememberLetterboxdProfileId()
    val events by manager.engine.events.collectAsStateWithLifecycle()
    val ops by manager.engine.operations.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val mine = remember(events, profileId) { events.filter { it.profileId == profileId }.sortedByDescending { it.atMs }.take(80) }
    val stuck = remember(ops, profileId) { ops.filter { it.profileId == profileId && it.status in RETRYABLE_STATES } }
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState, fullHeight = true) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Text("Sync history", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text("Review text and sign-in details are never shown here.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 2.dp, bottom = 12.dp))
            if (stuck.isNotEmpty()) {
                Text("Waiting or stopped", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                stuck.forEach { op ->
                    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(op.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("${opTypeLabel(op.type)} · ${opStatusLabel(op.status)}" + (op.note?.let { " · $it" } ?: ""), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        TextButton(onClick = { manager.retry(op.id) }) { Text("Retry") }
                    }
                }
                HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
            }
            if (mine.isEmpty()) {
                Text("No activity yet.", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 24.dp))
            } else {
                LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f, fill = false)) {
                    items(mine, key = { it.id }) { e ->
                        Column(modifier = Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(e.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(
                                "${opTypeLabel(e.type)} · ${opStatusLabel(e.status)}" + (e.viewingDate?.let { " · $it" } ?: "") + " · " + formatLocalDateTime(e.atMs),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            e.note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            if (e.error != LetterboxdErrorCategory.None) Text(errorLabel(e.error), style = MaterialTheme.typography.bodySmall, color = Attention)
                        }
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f))
                    }
                }
            }
            TextButton(onClick = close, modifier = Modifier.padding(bottom = 16.dp)) { Text("Close") }
        }
    }
}

private val RETRYABLE_STATES = setOf(
    LetterboxdOperationStatus.Failed, LetterboxdOperationStatus.NeedsReconnect, LetterboxdOperationStatus.RetryScheduled,
    LetterboxdOperationStatus.ActionRequired, LetterboxdOperationStatus.NeedsReconciliation,
)

internal fun opTypeLabel(type: LetterboxdOperationType): String = LetterboxdLabels.type(type)

internal fun opStatusLabel(status: LetterboxdOperationStatus): String = LetterboxdLabels.status(status)

internal fun errorLabel(error: LetterboxdErrorCategory): String = LetterboxdLabels.error(error)

// ---------------------------------------------------------------------------------------------------- app-level host

/** Mounted once in the main content: runs the queue at the right moments and shows the post-watch sheet after a film. */
@Composable
internal fun LetterboxdOverlayHost() {
    val manager = remember { LetterboxdRuntime.manager }
    val profileId = rememberLetterboxdProfileId()
    var queue by remember { mutableStateOf<List<String>>(emptyList()) }
    val playerActive by LetterboxdRuntime.playerActive.collectAsStateWithLifecycle()
    val network by remember { NetworkStatusRepository.uiState }.collectAsStateWithLifecycle()

    LaunchedEffect(manager) {
        manager.finishedViewings.collect { v ->
            if (v.profileId == ProfileRepository.activeProfileId && manager.settingsOf(v.profileId).showPostWatchPrompt) queue = queue + v.id
        }
    }
    LaunchedEffect(manager, profileId) { manager.syncNow(); manager.refreshWatchlistIfStale(profileId) }
    LifecycleResumeEffect(manager, profileId) { manager.syncNow(); manager.refreshWatchlistIfStale(profileId); onPauseOrDispose { } }
    LaunchedEffect(network.condition) { if (network.condition == NetworkCondition.Online) manager.syncNow() }

    val current = queue.firstOrNull()
    // Never over the player: the sheet waits until the member is out of the film.
    if (current != null && !playerActive) {
        LetterboxdPostWatchSheet(viewingId = current, onDismiss = { queue = queue.drop(1) })
    }
}

// ---------------------------------------------------------------------------------------------------- movie details

/** The Letterboxd block on a movie's details page: where it stands, a rating, and logging or reviewing a viewing. */
@Composable
internal fun LetterboxdMovieSection(
    metaId: String,
    imdbId: String?,
    title: String,
    posterUrl: String?,
    modifier: Modifier = Modifier,
    horizontalPadding: Dp = 0.dp,
) {
    val manager = LetterboxdRuntime.manager
    val profileId = rememberLetterboxdProfileId()
    val accounts by manager.accountsFlow.collectAsStateWithLifecycle()
    if (accounts[profileId] == null) return
    val viewings by manager.engine.viewings.collectAsStateWithLifecycle()
    val ops by manager.engine.operations.collectAsStateWithLifecycle()
    var tmdbId by remember(metaId) { mutableStateOf<Int?>(null) }
    var reviewing by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(metaId, imdbId) {
        tmdbId = runCatching { com.nuvio.app.features.tmdb.TmdbService.ensureTmdbId(metaId, "movie", imdbId) }.getOrNull()?.toIntOrNull()?.takeIf { it > 0 }
        tmdbId?.let { LetterboxdRuntime.rememberMetaId(it, metaId) }
    }
    val tmdb = tmdbId ?: return
    val mine = viewings.filter { it.profileId == profileId && it.tmdbId == tmdb }.sortedByDescending { it.completedAtMs }
    val latest = mine.firstOrNull()
    val status = latest?.let { letterboxdViewingStatus(it, ops, true) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.07f))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("Letterboxd", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        if (latest != null && status != null) {
            Text("${if (latest.localDate == LetterboxdViewing.UNDATED) "Marked watched on Letterboxd" else "Last watched ${latest.localDate}"}${if (mine.size > 1) " · ${mine.size} viewings" else ""}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
            Text(status.label, style = MaterialTheme.typography.bodySmall, color = status.color)
        } else {
            Text("Not in your diary from BannerTV yet.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        LetterboxdStars(latest?.stars, onChange = { manager.setRating(profileId, tmdb, title, it, latest?.id) })
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = { manager.logViewing(profileId, tmdb, title, posterUrl, latest?.stars) }) { Text("Log viewing") }
            OutlinedButton(enabled = latest != null, onClick = { reviewing = latest?.id }) { Text("Review") }
        }
    }
    reviewing?.let { LetterboxdReviewSheet(viewingId = it, onDismiss = { reviewing = null }) }
}
