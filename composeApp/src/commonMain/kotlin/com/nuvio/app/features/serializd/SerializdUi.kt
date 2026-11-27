package com.nuvio.app.features.serializd

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import com.nuvio.app.core.ui.Chip
import com.nuvio.app.core.ui.NuvioModalBottomSheet
import com.nuvio.app.core.ui.dismissNuvioBottomSheet
import com.nuvio.app.features.profiles.ProfileRepository
import kotlinx.coroutines.launch

private val Positive = Color(0xFF3DBE75)
private val Attention = Color(0xFFE5A53A)
private val Muted = Color(0xFF8A8F98)
private val Problem = Color(0xFFD9534F)

private const val DAY_MS = 86_400_000L

private fun nowMs(): Long = kotlin.time.Clock.System.now().toEpochMilliseconds()

/** The active profile's id, following profile switches. */
@Composable
internal fun rememberSerializdProfileId(): Int {
    val state by ProfileRepository.state.collectAsStateWithLifecycle()
    return state.activeProfile?.profileIndex ?: ProfileRepository.activeProfileId
}

/** Half-star rating control: the left half of a star is a half, the right half a whole. */
@Composable
internal fun SerializdStars(
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

/** What a request to the rating and review sheet is about: a series, one of its seasons, or one episode. */
internal data class SerializdSheetRequest(
    val metaId: String,
    val imdbId: String?,
    val showName: String,
    val posterUrl: String?,
    val season: Int? = null,
    val episode: Int? = null,
    val episodeTitle: String? = null,
)

/** What a viewing's sync looks like to the member, in plain words. */
internal data class SerializdWatchStatus(val label: String, val color: Color)

internal fun serializdWatchStatus(watch: SerializdWatch, ops: List<SerializdOperation>): SerializdWatchStatus {
    val mine = ops.filter { it.watchId == watch.id }
    val latest = mine.maxByOrNull { it.createdAtMs }
    return when {
        watch.source == SerializdWatch.SOURCE_IMPORT -> SerializdWatchStatus("Imported from Serializd", Positive)
        watch.onDiary -> SerializdWatchStatus(if (watch.reviewPublished) "On Serializd with a review" else "On Serializd", Positive)
        latest == null -> SerializdWatchStatus("Not sent to Serializd", Muted)
        latest.status in setOf(SerializdOperationStatus.Pending, SerializdOperationStatus.InProgress, SerializdOperationStatus.RetryScheduled) -> SerializdWatchStatus("Waiting to send", Attention)
        latest.status == SerializdOperationStatus.NeedsReconnect -> SerializdWatchStatus("Reconnect Serializd to send", Attention)
        latest.status == SerializdOperationStatus.ReconciliationRequired -> SerializdWatchStatus("Confirming on your diary", Attention)
        latest.status == SerializdOperationStatus.ActionRequired -> SerializdWatchStatus("Needs your attention", Attention)
        latest.status == SerializdOperationStatus.FailedPermanent -> SerializdWatchStatus("Could not send", Problem)
        latest.status == SerializdOperationStatus.Skipped -> SerializdWatchStatus("Marked watched on Serializd", Positive)
        else -> SerializdWatchStatus("Marked watched on Serializd", Positive)
    }
}

// ---------------------------------------------------------------------------------------------------- rate, review, log

/**
 * Rate, review and log one thing on Serializd: an episode (with a viewing), a season or a whole series. The text the member types
 * stays in the box and on the viewing whatever happens to the request. An entry already on Serializd is edited, not added again.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
internal fun SerializdTargetSheet(request: SerializdSheetRequest, onDismiss: () -> Unit) {
    val manager = SerializdRuntime.manager
    val profileId = rememberSerializdProfileId()
    val accounts by manager.accountsFlow.collectAsStateWithLifecycle()
    val watches by manager.engine.watches.collectAsStateWithLifecycle()
    val ops by manager.engine.operations.collectAsStateWithLifecycle()
    val remoteAll by manager.remoteEntriesFlow.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    val account = accounts[profileId]?.username
    var tmdb by remember(request.metaId) { mutableStateOf<Int?>(null) }
    var looked by remember(request.metaId) { mutableStateOf(false) }
    LaunchedEffect(request.metaId, request.imdbId) {
        tmdb = SerializdRuntime.showTmdbId(request.metaId, request.imdbId)
        looked = true
    }
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }
    val target = tmdb?.let { SerializdTarget(it, request.season, request.episode) }
    val isEpisode = request.season != null && request.episode != null
    val watch = if (target != null && isEpisode && account != null) watches.filter { it.profileId == profileId && it.target == target }.maxByOrNull { it.completedAtMs } else null
    val remoteEntry = if (target != null && account != null) {
        remoteAll[account.lowercase()].orEmpty().filter { it.showTmdbId == target.showTmdbId && it.seasonNumber == target.seasonNumber && it.episodeNumber == target.episodeNumber }.maxByOrNull { it.atMs }
    } else null
    val known = remember(target, account, ops, watches) { if (target != null && account != null) manager.engine.knownRating(account, target) else null }
    var stars by remember(target?.key, watch?.id) { mutableStateOf(watch?.stars ?: remoteEntry?.stars ?: known) }
    var text by remember(target?.key, watch?.id) { mutableStateOf(watch?.reviewDraft ?: remoteEntry?.reviewText.orEmpty()) }
    var spoilers by remember(target?.key, watch?.id) { mutableStateOf(watch?.reviewSpoilers ?: remoteEntry?.containsSpoiler ?: false) }
    var message by remember { mutableStateOf<String?>(null) }
    var dateChoice by remember { mutableIntStateOf(0) }
    var customDate by remember { mutableStateOf("") }
    var rewatch by remember(watch?.id) { mutableStateOf(watch != null) }
    val heading = request.showName
    val subtitle = when {
        isEpisode -> "Season ${request.season} · Episode ${request.episode}" + (request.episodeTitle?.takeIf { it.isNotBlank() }?.let { " · $it" } ?: "")
        request.season != null -> if (request.season == 0) "Specials" else "Season ${request.season}"
        else -> "Whole series"
    }
    val mine = remember(ops, target, profileId) { if (target == null) emptyList() else ops.filter { it.profileId == profileId && it.target == target } }
    val stuck = mine.filter { it.status in STOPPED }

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState, fullHeight = true) {
        Column(
            modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(heading, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            when {
                account == null -> Text("Connect Serializd in Settings, under Integrations, to rate, review and log.", style = MaterialTheme.typography.bodyMedium)
                !looked -> Text("Finding this show on Serializd…", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                target == null -> Text("This title could not be matched to a Serializd show, so it cannot be rated or logged there.", style = MaterialTheme.typography.bodyMedium, color = Attention)
                else -> {
                    if (isEpisode) {
                        val status = watch?.let { serializdWatchStatus(it, ops) }
                        if (watch != null && status != null) {
                            Text(
                                (if (watch.undated) "Watched, date unknown" else "Last watched ${formatLocalDateTime(watch.completedAtMs)}") + (if (watch.rewatch) " · rewatch" else ""),
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            Text(status.label, style = MaterialTheme.typography.bodySmall, color = status.color)
                        } else {
                            Text(if (manager.engine.isMarkerKnown(account, target)) "Marked watched on Serializd." else "Not logged on Serializd from BannerTV yet.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Text("Your rating", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    SerializdStars(stars, onChange = { stars = it; manager.setRating(profileId, target, request.showName, it, watch?.id) }, starSize = 44.dp)
                    Text(
                        stars?.let { "${SerializdRating.label(it)} stars" } ?: "Not rated",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedTextField(
                        value = text, onValueChange = { text = it }, modifier = Modifier.fillMaxWidth().height(180.dp),
                        label = { Text("Your review") }, keyboardOptions = KeyboardOptions.Default,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Contains spoilers", style = MaterialTheme.typography.bodyLarge)
                            Text("Hidden behind a warning on Serializd", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Switch(checked = spoilers, onCheckedChange = { spoilers = it })
                    }
                    message?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                        OutlinedButton(
                            enabled = watch != null,
                            onClick = { scope.launch { watch?.let { manager.engine.saveReviewDraft(it.id, text, spoilers) }; message = "Draft saved on this device." } },
                            modifier = Modifier.weight(1f),
                        ) { Text("Save draft") }
                        Button(
                            enabled = text.isNotBlank(),
                            onClick = {
                                scope.launch {
                                    message = when (val outcome = manager.publishReview(profileId, target, request.showName, text.trim(), spoilers, stars, watch?.id)) {
                                        SerializdReviewOutcome.Queued -> "Your review is on its way. If it cannot be sent, it stays here and you can retry."
                                        is SerializdReviewOutcome.DraftKeptOpenSerializd -> "This entry is still being confirmed on Serializd. Your text is saved here; try again in a few minutes."
                                        SerializdReviewOutcome.NotConnected -> "Serializd is not connected."
                                    }
                                }
                            },
                            modifier = Modifier.weight(1f),
                        ) { Text("Publish") }
                    }
                    if (isEpisode) {
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                        Text("Log a viewing", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                        Text("Adds a dated entry to your Serializd diary and marks the episode watched. Watching in BannerTV does this by itself.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Chip(label = "Today", selected = dateChoice == 0, onClick = { dateChoice = 0 })
                            Chip(label = "Yesterday", selected = dateChoice == 1, onClick = { dateChoice = 1 })
                            Chip(label = "Another day", selected = dateChoice == 2, onClick = { dateChoice = 2 })
                        }
                        if (dateChoice == 2) {
                            OutlinedTextField(value = customDate, onValueChange = { customDate = it.trim() }, singleLine = true, label = { Text("Date watched (2026-11-23)") }, modifier = Modifier.fillMaxWidth())
                        }
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                            Text("This is a rewatch", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            Switch(checked = rewatch, onCheckedChange = { rewatch = it })
                        }
                        Button(
                            modifier = Modifier.fillMaxWidth(),
                            onClick = {
                                val now = nowMs()
                                val at = when (dateChoice) {
                                    0 -> now
                                    1 -> now - DAY_MS
                                    else -> SerializdDates.parse(customDate)?.takeIf { it.dateOnly }?.ms?.plus(12 * 3_600_000L)
                                }
                                when {
                                    at == null -> message = "Type the date as year-month-day, for example 2026-11-23."
                                    at > now + 5 * 60_000L -> message = "That date is in the future."
                                    else -> {
                                        manager.logViewing(profileId, target, request.showName, request.posterUrl, at, stars, rewatch)
                                        message = "Queued. It goes to Serializd with the date you chose."
                                    }
                                }
                            },
                        ) { Text("Log viewing") }
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                            OutlinedButton(
                                modifier = Modifier.weight(1f),
                                onClick = { manager.markEpisodeWatched(profileId, target, request.showName); message = "Queued. The episode is marked watched on Serializd; no diary entry is made." },
                            ) { Text("Mark watched") }
                            if (manager.engine.isMarkerKnown(account, target)) {
                                OutlinedButton(
                                    modifier = Modifier.weight(1f),
                                    onClick = { manager.unmarkEpisode(profileId, target, request.showName); message = "Queued. The watched mark is removed; any diary entry stays." },
                                ) { Text("Remove mark") }
                            }
                        }
                    }
                    if (stuck.isNotEmpty()) {
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f))
                        Text("Needs attention", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        stuck.forEach { op ->
                            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("${serializdOpTypeLabel(op.type)} · ${serializdOpStatusLabel(op.status)}", style = MaterialTheme.typography.bodyMedium)
                                    (op.note ?: serializdErrorLabel(op.error).takeIf { it.isNotBlank() })?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Attention) }
                                }
                                TextButton(onClick = { manager.retry(op.id) }) { Text("Retry") }
                            }
                        }
                    }
                    OutlinedButton(onClick = { runCatching { uriHandler.openUri(SerializdApiConstants.showUrl(target.showTmdbId)) } }, modifier = Modifier.fillMaxWidth()) { Text("Open on Serializd") }
                }
            }
            TextButton(onClick = close) { Text("Close") }
        }
    }
}

private val STOPPED = setOf(SerializdOperationStatus.FailedPermanent, SerializdOperationStatus.NeedsReconnect, SerializdOperationStatus.ActionRequired)

// ---------------------------------------------------------------------------------------------------- series details

/** The Serializd block on a series' details page: its rating, and a way into the review sheet. Nothing is shown without an account. */
@Composable
internal fun SerializdSeriesSection(
    metaId: String,
    imdbId: String?,
    title: String,
    posterUrl: String?,
    modifier: Modifier = Modifier,
) {
    val manager = SerializdRuntime.manager
    val profileId = rememberSerializdProfileId()
    val accounts by manager.accountsFlow.collectAsStateWithLifecycle()
    val account = accounts[profileId]?.username ?: return
    val ops by manager.engine.operations.collectAsStateWithLifecycle()
    val lists by manager.watchlistFlow.collectAsStateWithLifecycle()
    var tmdb by remember(metaId) { mutableStateOf<Int?>(null) }
    var sheet by remember { mutableStateOf(false) }
    LaunchedEffect(metaId, imdbId) { tmdb = SerializdRuntime.showTmdbId(metaId, imdbId) }
    val show = tmdb ?: return
    val target = SerializdTarget(show)
    val rating = remember(ops, show, account) { manager.engine.knownRating(account, target) }
    var stars by remember(show, rating) { mutableStateOf(rating) }
    val onWatchlist = lists[profileId]?.entries?.any { it.showTmdbId == show } == true
    val watchedEpisodes = remember(ops, show, account) { manager.engine.watchedEpisodeCount(account, show) }

    Column(
        modifier = modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.07f)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("Serializd", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
        Text(
            buildString {
                append(if (watchedEpisodes > 0) "$watchedEpisodes ${if (watchedEpisodes == 1) "episode" else "episodes"} marked watched" else "No episodes marked watched yet")
                if (onWatchlist) append(" · on your watchlist")
            },
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        SerializdStars(stars, onChange = { stars = it; manager.setRating(profileId, target, title, it) })
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = { sheet = true }) { Text("Rate or review") }
        }
    }
    if (sheet) SerializdTargetSheet(SerializdSheetRequest(metaId, imdbId, title, posterUrl), onDismiss = { sheet = false })
}

// ---------------------------------------------------------------------------------------------------- history and watchlist

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SerializdHistorySheet(onDismiss: () -> Unit) {
    val manager = SerializdRuntime.manager
    val profileId = rememberSerializdProfileId()
    val events by manager.engine.events.collectAsStateWithLifecycle()
    val ops by manager.engine.operations.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val mine = remember(events, profileId) { events.filter { it.profileId == profileId }.sortedByDescending { it.atMs }.take(80) }
    val stuck = remember(ops, profileId) { ops.filter { it.profileId == profileId && it.status in RETRYABLE } }
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState, fullHeight = true) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Text("Sync activity", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text("Review text, passwords and sign-in details are never shown here.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 2.dp, bottom = 12.dp))
            if (stuck.isNotEmpty()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Waiting or stopped", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
                    TextButton(onClick = { manager.retryAll(profileId) }) { Text("Retry all") }
                }
                stuck.forEach { op ->
                    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(op.title + (op.seasonNumber?.let { " · S$it" + (op.episodeNumber?.let { e -> "E$e" } ?: "") } ?: ""), style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text("${serializdOpTypeLabel(op.type)} · ${serializdOpStatusLabel(op.status)}" + (op.note?.let { " · $it" } ?: ""), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (op.error != SerializdErrorCategory.None) Text(serializdErrorLabel(op.error), style = MaterialTheme.typography.bodySmall, color = Attention)
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
                            Text(
                                e.title + (e.seasonNumber?.let { " · S$it" + (e.episodeNumber?.let { n -> "E$n" } ?: "") } ?: "") + if (e.rewatch) " · rewatch" else "",
                                style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            )
                            Text("${serializdOpTypeLabel(e.type)} · ${serializdOpStatusLabel(e.status)} · ${formatLocalDateTime(e.atMs)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            e.note?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            if (e.error != SerializdErrorCategory.None) Text(serializdErrorLabel(e.error), style = MaterialTheme.typography.bodySmall, color = Attention)
                        }
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f))
                    }
                }
            }
            TextButton(onClick = close, modifier = Modifier.padding(bottom = 16.dp)) { Text("Close") }
        }
    }
}

private val RETRYABLE = setOf(
    SerializdOperationStatus.FailedPermanent, SerializdOperationStatus.NeedsReconnect, SerializdOperationStatus.RetryScheduled,
    SerializdOperationStatus.ActionRequired, SerializdOperationStatus.ReconciliationRequired,
)

internal fun serializdOpTypeLabel(type: SerializdOperationType): String = SerializdLabels.type(type)

internal fun serializdOpStatusLabel(status: SerializdOperationStatus): String = SerializdLabels.status(status)

internal fun serializdErrorLabel(error: SerializdErrorCategory): String = SerializdLabels.error(error)

/** The member's Serializd watchlist, as last read in full. Each show says which of its seasons are on it and whether anything is marked watched. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SerializdWatchlistSheet(onDismiss: () -> Unit) {
    val manager = SerializdRuntime.manager
    val profileId = rememberSerializdProfileId()
    val lists by manager.watchlistFlow.collectAsStateWithLifecycle()
    val accounts by manager.accountsFlow.collectAsStateWithLifecycle()
    val status by manager.importStatus.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val uriHandler = LocalUriHandler.current
    var refreshing by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val snapshot = lists[profileId]
    val account = accounts[profileId]?.username
    val close: () -> Unit = { scope.launch { dismissNuvioBottomSheet(sheetState = sheetState, onDismiss = onDismiss) } }

    NuvioModalBottomSheet(onDismissRequest = close, sheetState = sheetState, fullHeight = true) {
        Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Serializd watchlist", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text(
                        snapshot?.let { "${it.entries.size} ${if (it.entries.size == 1) "show" else "shows"} · read ${formatLocalDateTime(it.completeAtMs)}" } ?: "Not read yet",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                OutlinedButton(enabled = !refreshing && account != null, onClick = { scope.launch { refreshing = true; failed = manager.refreshWatchlist(profileId) == null; refreshing = false } }) {
                    Text(if (refreshing) (status ?: "Refreshing…") else "Refresh")
                }
            }
            if (failed) Text("The watchlist could not be read completely, so the last full copy was kept.", style = MaterialTheme.typography.bodySmall, color = Attention, modifier = Modifier.padding(top = 6.dp))
            Text("Read only: editing the watchlist is not supported from BannerTV yet.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp, bottom = 8.dp))
            if (snapshot == null || snapshot.entries.isEmpty()) {
                Text(if (snapshot == null) "Tap Refresh to read your watchlist." else "Your watchlist is empty.", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(vertical = 24.dp))
            } else {
                LazyColumn(modifier = Modifier.fillMaxWidth().weight(1f, fill = false)) {
                    items(snapshot.entries, key = { it.showTmdbId }) { entry ->
                        val watched = if (account != null) manager.engine.watchedEpisodeCount(account, entry.showTmdbId) else 0
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable { runCatching { uriHandler.openUri(SerializdApiConstants.showUrl(entry.showTmdbId)) } }.padding(vertical = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
                        ) {
                            AsyncImage(
                                model = entry.posterPath?.let { "https://image.tmdb.org/t/p/w185$it" }, contentDescription = null, contentScale = ContentScale.Crop,
                                modifier = Modifier.width(48.dp).height(72.dp).clip(RoundedCornerShape(6.dp)).background(Color.White.copy(alpha = 0.08f)),
                            )
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(entry.name ?: "Show ${entry.showTmdbId}", style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                Text(
                                    when {
                                        entry.seasonNumbers.isNotEmpty() -> "Season " + entry.seasonNumbers.joinToString(", ")
                                        entry.seasonIds.isNotEmpty() -> "Seasons not matched yet"
                                        else -> "Whole show"
                                    },
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Text(
                                    if (watched > 0) "$watched ${if (watched == 1) "episode" else "episodes"} watched" else "Not started",
                                    style = MaterialTheme.typography.bodySmall, color = if (watched > 0) Positive else Muted,
                                )
                            }
                        }
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f))
                    }
                }
            }
            TextButton(onClick = close, modifier = Modifier.padding(bottom = 16.dp)) { Text("Close") }
        }
    }
}

// ---------------------------------------------------------------------------------------------------- app-level host

/** Mounted once in the main content: runs the queue when the app opens or comes back, and when the network returns. */
@Composable
internal fun SerializdOverlayHost() {
    val manager = remember { SerializdRuntime.manager }
    val profileId = rememberSerializdProfileId()
    val network by remember { NetworkStatusRepository.uiState }.collectAsStateWithLifecycle()
    LaunchedEffect(manager, profileId) { manager.syncNow(); manager.refreshIfStale(profileId) }
    LifecycleResumeEffect(manager, profileId) { manager.syncNow(); manager.refreshIfStale(profileId); onPauseOrDispose { } }
    LaunchedEffect(network.condition) { if (network.condition == NetworkCondition.Online) manager.syncNow() }
}
