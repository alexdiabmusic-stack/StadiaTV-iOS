package com.nuvio.app.features.settings

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.CalendarToday
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.CloudUpload
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.History
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.PlayCircleOutline
import androidx.compose.material.icons.rounded.PlaylistAddCheck
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.format.localUtcOffsetMs
import com.nuvio.app.core.ui.Chip
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.features.serializd.SerializdBackfill
import com.nuvio.app.features.serializd.SerializdClock
import com.nuvio.app.features.serializd.SerializdConnectResult
import com.nuvio.app.features.serializd.SerializdConnectionState
import com.nuvio.app.features.serializd.SerializdHistorySheet
import com.nuvio.app.features.serializd.SerializdRuntime
import com.nuvio.app.features.serializd.SerializdScreenState
import com.nuvio.app.features.serializd.SerializdSettings
import com.nuvio.app.features.serializd.SerializdTone
import com.nuvio.app.features.serializd.SerializdWatchHistorySheet
import com.nuvio.app.features.serializd.SerializdWatchlistSheet
import com.nuvio.app.features.serializd.rememberSerializdProfileId
import kotlinx.coroutines.launch

internal val Positive = Color(0xFF3DBE75)
internal val Attention = Color(0xFFE5A53A)

/** The main page: account and sync, the three automatic-tracking switches, the member's data, and the way to the advanced page. */
internal fun LazyListScope.serializdSettingsContent(isTablet: Boolean, onAdvancedClick: () -> Unit) {
    item { SerializdAccountSection(isTablet, onAdvancedClick) }
    item { SerializdAutomaticTrackingSection(isTablet) }
    item { SerializdYourDataSection(isTablet, onAdvancedClick) }
}

/** The advanced page: tracking preferences, import and data transfer, connection and diagnostics. */
internal fun LazyListScope.serializdAdvancedSettingsContent(isTablet: Boolean) {
    item { SerializdTrackingPreferencesSection(isTablet) }
    item { SerializdTransferSection(isTablet) }
    item { SerializdConnectionSection(isTablet) }
}

/** What the screens draw, kept current. Every wording and status decision is made in the shared core, not here. */
@Composable
internal fun rememberSerializdScreen(profileId: Int): SerializdScreenState {
    val manager = remember { SerializdRuntime.manager }
    val clock = remember { SerializdClock { localUtcOffsetMs(it) } }
    val flow = remember(profileId) { manager.screenFlow(profileId, clock) }
    val initial = remember(profileId) { manager.screenNow(profileId, clock) }
    val state by flow.collectAsStateWithLifecycle(initialValue = initial)
    return state
}

internal fun toneColor(tone: SerializdTone, muted: Color, error: Color) = when (tone) {
    SerializdTone.Good -> Positive
    SerializdTone.Neutral -> muted
    SerializdTone.Warning -> Attention
    SerializdTone.Problem -> error
}

// ---------------------------------------------------------------------------------------------- main page

@Composable
private fun SerializdAccountSection(isTablet: Boolean, onAdvancedClick: () -> Unit) {
    val manager = remember { SerializdRuntime.manager }
    val profileId = rememberSerializdProfileId()
    val state = rememberSerializdScreen(profileId)
    val scope = rememberCoroutineScope()
    val tokens = MaterialTheme.nuvio
    val horizontal = if (isTablet) 20.dp else 16.dp
    var showForm by remember { mutableStateOf(false) }
    var setupWorking by remember { mutableStateOf(false) }

    SettingsSection(title = "Serializd", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            if (!state.connected) {
                SerializdConnectForm(isTablet = isTablet, reconnect = false, accountName = null, onDone = {})
            } else {
                Row(
                    modifier = Modifier.fillMaxWidth().clickable(onClick = onAdvancedClick).padding(horizontal = horizontal, vertical = 14.dp)
                        .semantics { role = Role.Button; contentDescription = "${state.username}, ${state.connectionLabel}. Opens advanced settings." },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SerializdMark(56.dp)
                    Spacer(Modifier.width(14.dp))
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(state.username.orEmpty(), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            val tint = toneColor(state.connectionTone, tokens.colors.textMuted, MaterialTheme.colorScheme.error)
                            Icon(if (state.connectionTone == SerializdTone.Good) Icons.Rounded.CheckCircleOutline else Icons.Rounded.ErrorOutline, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(state.connectionLabel, style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                    Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = tokens.colors.textMuted)
                }
                HorizontalDivider(modifier = Modifier.padding(horizontal = horizontal), thickness = tokens.borders.hairline, color = tokens.colors.borderSubtle)
                Row(modifier = Modifier.fillMaxWidth().padding(horizontal = horizontal, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(modifier = Modifier.size(44.dp).clip(RoundedCornerShape(22.dp)).background(tokens.colors.accent.copy(alpha = tokens.opacity.pressed)), contentAlignment = Alignment.Center) {
                        if (state.busy) CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp, color = tokens.colors.accent)
                        else Icon(if (state.syncTone == SerializdTone.Good) Icons.Rounded.Sync else Icons.Rounded.ErrorOutline, contentDescription = null, tint = toneColor(state.syncTone, tokens.colors.textPrimary, MaterialTheme.colorScheme.error).let { if (state.syncTone == SerializdTone.Good) tokens.colors.textPrimary else it })
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(state.syncHeadline, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary)
                        state.syncDetail?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted) }
                    }
                }
                if (state.needsReconnect) {
                    Button(
                        onClick = { showForm = !showForm }, modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 12.dp).heightIn(min = 48.dp),
                        shape = RoundedCornerShape(16.dp), colors = ButtonDefaults.buttonColors(containerColor = tokens.colors.accent, contentColor = tokens.colors.onAccent),
                    ) { Text(if (showForm) "Cancel" else "Sign in again", fontWeight = FontWeight.SemiBold) }
                    if (showForm) SerializdConnectForm(isTablet = isTablet, reconnect = true, accountName = state.username, onDone = { showForm = false })
                } else {
                    Button(
                        onClick = { if (!state.busy) scope.launch { manager.syncNowAndWait(profileId) } },
                        enabled = !state.busy, modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 12.dp).heightIn(min = 48.dp),
                        shape = RoundedCornerShape(16.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = tokens.colors.accent, contentColor = tokens.colors.onAccent, disabledContainerColor = tokens.colors.accent.copy(alpha = 0.45f), disabledContentColor = tokens.colors.onAccent.copy(alpha = 0.8f)),
                    ) {
                        if (state.busy) CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = tokens.colors.onAccent) else Icon(Icons.Rounded.Sync, contentDescription = null, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(if (state.busy) "Syncing…" else "Sync now", fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
    if (state.setupPending) {
        SerializdSetupDialog(
            username = state.username.orEmpty(), working = setupWorking, status = state.syncHeadline.takeIf { setupWorking && state.busy },
            onRecommended = { if (!setupWorking) { setupWorking = true; scope.launch { manager.completeSetup(profileId, recommended = true); setupWorking = false } } },
            onCustomize = { if (!setupWorking) scope.launch { manager.completeSetup(profileId, recommended = false) } },
        )
    }
}

/** The Serializd icon, as supplied, in a rounded tile. */
@Composable
internal fun SerializdMark(size: androidx.compose.ui.unit.Dp) {
    androidx.compose.foundation.Image(
        painter = integrationLogoPainter(IntegrationLogo.Serializd), contentDescription = "Serializd",
        modifier = Modifier.size(size).clip(RoundedCornerShape(size * 0.22f)),
        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
    )
}

/** Email and password, checked with Serializd before anything is stored. Used for the first connection and to sign in again. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SerializdConnectForm(isTablet: Boolean, reconnect: Boolean, accountName: String?, onDone: () -> Unit) {
    val manager = remember { SerializdRuntime.manager }
    val profileId = rememberSerializdProfileId()
    val scope = rememberCoroutineScope()
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val horizontal = if (isTablet) 20.dp else 16.dp

    fun connect() {
        if (working) return
        working = true; error = null
        val mail = email; val pass = password
        scope.launch {
            when (val r = manager.connect(profileId, mail, pass, guidedSetup = !reconnect)) {
                is SerializdConnectResult.Connected -> { email = ""; password = ""; onDone() }
                is SerializdConnectResult.Failed -> error = r.message
                is SerializdConnectResult.TooManyAttempts -> error = "Too many attempts. Try again in ${(r.waitMs / 1000).coerceAtLeast(1)} seconds."
            }
            working = false
        }
    }

    Column(modifier = Modifier.fillMaxWidth().padding(horizontal = horizontal, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (!reconnect) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                SerializdMark(48.dp)
                Spacer(Modifier.width(12.dp))
                Column {
                    Text("Serializd", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                    Text("Track series, keep your diary, rate and review.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            Text("Sign in as ${accountName ?: "your Serializd account"} to keep syncing.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        OutlinedTextField(
            value = email, onValueChange = { email = it }, singleLine = true, enabled = !working, modifier = Modifier.fillMaxWidth(),
            label = { Text("Serializd email") }, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
        )
        OutlinedTextField(
            value = password, onValueChange = { password = it }, singleLine = true, enabled = !working, modifier = Modifier.fillMaxWidth(),
            label = { Text("Serializd password") }, visualTransformation = PasswordVisualTransformation(), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        )
        Text(
            "Your email and password are checked with Serializd, then kept in this device's secure storage for this profile only. They are never sent anywhere else or written to logs, and Disconnect deletes them.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
        val tokens = MaterialTheme.nuvio
        Button(
            onClick = ::connect, enabled = !working && email.isNotBlank() && password.isNotBlank(),
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), shape = RoundedCornerShape(16.dp),
            colors = ButtonDefaults.buttonColors(containerColor = tokens.colors.accent, contentColor = tokens.colors.onAccent),
        ) {
            if (working) { CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = tokens.colors.onAccent); Spacer(Modifier.width(8.dp)) }
            Text(if (working) "Checking with Serializd…" else if (reconnect) "Sign in" else "Connect Serializd", fontWeight = FontWeight.SemiBold)
        }
    }
}

/** The step after a first connection: the choice is made before anything is read. */
@Composable
private fun SerializdSetupDialog(username: String, working: Boolean, status: String?, onRecommended: () -> Unit, onCustomize: () -> Unit) {
    AlertDialog(
        onDismissRequest = {},
        title = { Text("Set up Serializd") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Connected as $username. Choose how BannerTV should work with your account.")
                Text("Recommended: track episodes you finish, sync your ratings, and add your Serializd watchlist to My List. What you have already watched on Serializd is read in. Nothing from BannerTV is sent to Serializd that you did not just watch.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (working) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text(status ?: "Setting up…", style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onRecommended, enabled = !working) { Text("Use Recommended Settings", fontWeight = FontWeight.SemiBold) } },
        dismissButton = { TextButton(onClick = onCustomize, enabled = !working) { Text("Customize Settings") } },
    )
}

@Composable
private fun SerializdAutomaticTrackingSection(isTablet: Boolean) {
    val manager = remember { SerializdRuntime.manager }
    val profileId = rememberSerializdProfileId()
    val state = rememberSerializdScreen(profileId)
    val scope = rememberCoroutineScope()
    val connected = state.connected
    var note by remember { mutableStateOf<String?>(null) }
    var watchlistBusy by remember { mutableStateOf(false) }

    SettingsSection(title = "Automatic tracking", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            SettingsSwitchRow(
                icon = Icons.Rounded.PlayCircleOutline, title = "Track watched episodes", description = "Automatically track episodes you finish watching.",
                checked = state.trackEpisodes, enabled = connected, isTablet = isTablet,
                onCheckedChange = { v -> manager.updateSettings(profileId) { it.copy(autoTrackEpisodes = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.StarBorder, title = "Sync ratings", description = "Send your BannerTV ratings to Serializd.",
                checked = state.syncRatings, enabled = connected, isTablet = isTablet,
                onCheckedChange = { v -> manager.updateSettings(profileId) { it.copy(syncRatings = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.BookmarkBorder, title = "Sync watchlist", description = "Add shows from your Serializd watchlist to My List.",
                checked = state.syncWatchlist, enabled = connected && !watchlistBusy, isTablet = isTablet,
                onCheckedChange = { v ->
                    if (!watchlistBusy) { watchlistBusy = true; note = null; scope.launch { note = manager.setSyncWatchlist(profileId, v); watchlistBusy = false } }
                },
            )
        }
        val footer = if (!connected) "Connect your Serializd account to use these." else note
        if (footer != null) Text(footer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp))
    }
}

@Composable
private fun SerializdYourDataSection(isTablet: Boolean, onAdvancedClick: () -> Unit) {
    val manager = remember { SerializdRuntime.manager }
    val profileId = rememberSerializdProfileId()
    val state = rememberSerializdScreen(profileId)
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var showDetails by remember { mutableStateOf(false) }
    var showWatchlist by remember { mutableStateOf(false) }
    if (!state.connected) return
    val tokens = MaterialTheme.nuvio
    val chevron: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = { Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = tokens.colors.textMuted) }

    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        SettingsSection(title = "Your data", isTablet = isTablet) {
            SettingsGroup(isTablet = isTablet) {
                SettingsNavigationRow(title = "Watch history", description = state.watchHistoryLine, icon = Icons.Rounded.Tv, isTablet = isTablet, trailingContent = chevron, onClick = { showDetails = true })
                SettingsGroupDivider(isTablet = isTablet)
                SettingsNavigationRow(title = "Watchlist", description = state.watchlistLine, icon = Icons.Rounded.BookmarkBorder, isTablet = isTablet, trailingContent = chevron, onClick = { showWatchlist = true })
                SettingsGroupDivider(isTablet = isTablet)
                SettingsNavigationRow(
                    title = if (working || state.busy) "Importing…" else "Import from Serializd",
                    description = (if (state.busy) state.syncHeadline else null) ?: message ?: state.importLine,
                    icon = Icons.Rounded.Download, enabled = !working && !state.busy, isTablet = isTablet,
                    onClick = { if (!working) { working = true; message = null; scope.launch { message = manager.importFromSerializd(profileId); working = false } } },
                )
            }
        }
        SettingsGroup(isTablet = isTablet) {
            SettingsNavigationRow(title = "Advanced settings", description = "Tracking, imports, sync rules and more.", icon = Icons.Rounded.Tune, isTablet = isTablet, trailingContent = chevron, onClick = onAdvancedClick)
        }
    }
    if (showDetails) SerializdWatchHistorySheet(state = state, onDismiss = { showDetails = false })
    if (showWatchlist) SerializdWatchlistSheet(onDismiss = { showWatchlist = false })
}

// ---------------------------------------------------------------------------------------------- advanced page

@Composable
private fun SerializdTrackingPreferencesSection(isTablet: Boolean) {
    val manager = remember { SerializdRuntime.manager }
    val profileId = rememberSerializdProfileId()
    val state = rememberSerializdScreen(profileId)
    val settings: SerializdSettings = state.settings
    val connected = state.connected
    val tracking = connected && settings.autoTrackEpisodes
    fun change(f: (SerializdSettings) -> SerializdSettings) = manager.updateSettings(profileId, f)

    SettingsSection(title = "Tracking preferences", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            SettingsSwitchRow(
                icon = Icons.Rounded.CalendarToday, title = "Create dated diary entries", description = "Add episodes to your Serializd diary with the date you finished them.",
                checked = settings.createDiaryEntries, enabled = tracking, isTablet = isTablet, onCheckedChange = { v -> change { it.copy(createDiaryEntries = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.Repeat, title = "Track rewatches automatically", description = "Automatically log when you watch an episode again.",
                checked = settings.logRewatches, enabled = tracking, isTablet = isTablet, onCheckedChange = { v -> change { it.copy(logRewatches = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.FavoriteBorder, title = "Sync favorites as likes", description = "Also like shows on Serializd when you add them to My List.",
                checked = settings.syncFavorites, enabled = connected, isTablet = isTablet, onCheckedChange = { v -> change { it.copy(syncFavorites = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            Row(modifier = Modifier.fillMaxWidth().padding(horizontal = if (isTablet) 20.dp else 16.dp, vertical = if (isTablet) 16.dp else 14.dp).alpha(if (tracking) 1f else 0.5f)) {
                Box(modifier = Modifier.size(if (isTablet) 42.dp else 36.dp), contentAlignment = Alignment.Center) { Icon(Icons.Rounded.BarChart, contentDescription = null, tint = MaterialTheme.nuvio.colors.textPrimary, modifier = Modifier.size(24.dp)) }
                Spacer(Modifier.width(if (isTablet) 16.dp else 14.dp))
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("Mark as watched after", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.nuvio.colors.textPrimary, fontWeight = FontWeight.Medium)
                        Text("Count an episode as watched when this much has been played.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.nuvio.colors.textMuted)
                    }
                    SerializdSegmented(
                        labels = listOf("80%", "90%", "95%"),
                        selected = listOf(0.80, 0.90, 0.95).indexOfFirst { kotlin.math.abs(settings.completionThreshold - it) < 0.005 },
                        enabled = tracking, onSelect = { i -> change { it.copy(completionThreshold = listOf(0.80, 0.90, 0.95)[i]) } },
                    )
                }
            }
        }
        val footer = if (!connected) "Connect your Serializd account to change these."
        else if (!settings.autoTrackEpisodes) "Diary, rewatch and watched-threshold choices apply when Track watched episodes is on. They are kept as you set them."
        else null
        if (footer != null) Text(footer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp))
    }
}

/** A three-way segmented control in the app's accent. */
@Composable
internal fun SerializdSegmented(labels: List<String>, selected: Int, enabled: Boolean, onSelect: (Int) -> Unit) {
    val tokens = MaterialTheme.nuvio
    Row(
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(tokens.colors.borderDefault.copy(alpha = 0.5f)).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        labels.forEachIndexed { i, label ->
            val on = i == selected
            Box(
                modifier = Modifier.weight(1f).heightIn(min = 40.dp).clip(RoundedCornerShape(11.dp))
                    .background(if (on) tokens.colors.accent else Color.Transparent)
                    .clickable(enabled = enabled) { onSelect(i) }
                    .semantics { role = Role.RadioButton; contentDescription = "$label${if (on) ", selected" else ""}" },
                contentAlignment = Alignment.Center,
            ) { Text(label, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = if (on) tokens.colors.onAccent else tokens.colors.textPrimary) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SerializdTransferSection(isTablet: Boolean) {
    val manager = remember { SerializdRuntime.manager }
    val profileId = rememberSerializdProfileId()
    val state = rememberSerializdScreen(profileId)
    val scope = rememberCoroutineScope()
    val connected = state.connected
    var working by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var showDetails by remember { mutableStateOf(false) }
    var askBackfill by remember { mutableStateOf(false) }
    var backfillWorking by remember { mutableStateOf(false) }
    var backfillMessage by remember { mutableStateOf<String?>(null) }
    var range by remember { mutableStateOf(SerializdBackfill.Range.Month) }
    var withDiary by remember { mutableStateOf(true) }
    val tokens = MaterialTheme.nuvio
    val chevron: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = { Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = tokens.colors.textMuted) }

    SettingsSection(title = "Import & data transfer", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            SettingsNavigationRow(
                title = if (working || state.busy) "Importing…" else "Import Serializd history",
                description = (if (state.busy) state.syncHeadline else null) ?: message ?: "Bring what you've already watched on Serializd into BannerTV.",
                icon = Icons.Rounded.Download, enabled = connected && !working && !state.busy, isTablet = isTablet, trailingContent = chevron,
                onClick = { if (!working) { working = true; message = null; scope.launch { message = manager.importFromSerializd(profileId); working = false } } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.PlaylistAddCheck, title = "Include watched seasons", description = "Also import seasons you marked watched on Serializd. They have no date.",
                checked = state.settings.importWatchedHistory, enabled = connected, isTablet = isTablet,
                onCheckedChange = { v -> manager.updateSettings(profileId) { it.copy(importWatchedHistory = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsNavigationRow(
                title = if (backfillWorking) "Queuing…" else "Send existing BannerTV history",
                description = backfillMessage ?: "Add episodes you've watched in BannerTV to Serializd. Only when you choose.",
                icon = Icons.Rounded.CloudUpload, enabled = connected && !backfillWorking, isTablet = isTablet, trailingContent = chevron, onClick = { askBackfill = true },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsNavigationRow(
                title = "View import details", description = state.importLine ?: "See what was imported and when.",
                icon = Icons.Rounded.History, enabled = connected, isTablet = isTablet, trailingContent = chevron, onClick = { showDetails = true },
            )
        }
    }
    if (showDetails) SerializdWatchHistorySheet(state = state, onDismiss = { showDetails = false })
    if (askBackfill) {
        AlertDialog(
            onDismissRequest = { askBackfill = false },
            title = { Text("Send your watched history?") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Episodes you watched in BannerTV are marked watched on your Serializd account. Episodes that came from Serializd, or were already sent, are skipped. Pick how far back to go:")
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SerializdBackfill.Range.entries.forEach { r -> Chip(label = r.label, selected = range == r, onClick = { range = r }) }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Also add dated diary entries", style = MaterialTheme.typography.bodyLarge)
                            Text("Only for episodes with a real watch date, up to 400 at a time. Episodes with no date get the watched mark only.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Switch(checked = withDiary, onCheckedChange = { withDiary = it })
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    askBackfill = false
                    scope.launch {
                        backfillWorking = true
                        val result = if (profileId == com.nuvio.app.features.profiles.ProfileRepository.activeProfileId) SerializdBackfill.run(profileId, range, withDiary) else null
                        backfillMessage = result?.let { (marks, entries, skipped) ->
                            if (marks + entries == 0) "Nothing new to send: $skipped already on Serializd or nothing in that range."
                            else "$marks watched requests and $entries diary entries are on their way; $skipped episodes were already on Serializd. Run it again to continue past 400 dated entries."
                        } ?: "Nothing was queued."
                        backfillWorking = false
                    }
                }) { Text("Send") }
            },
            dismissButton = { TextButton(onClick = { askBackfill = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SerializdConnectionSection(isTablet: Boolean) {
    val manager = remember { SerializdRuntime.manager }
    val profileId = rememberSerializdProfileId()
    val state = rememberSerializdScreen(profileId)
    val scope = rememberCoroutineScope()
    val connected = state.connected
    var verifying by remember { mutableStateOf(false) }
    var verifyMessage by remember { mutableStateOf<String?>(null) }
    var showHistory by remember { mutableStateOf(false) }
    var confirmDisconnect by remember { mutableStateOf(false) }
    val tokens = MaterialTheme.nuvio
    val chevron: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = { Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = tokens.colors.textMuted) }
    val horizontal = if (isTablet) 20.dp else 16.dp

    SettingsSection(title = "Connection & diagnostics", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            SettingsNavigationRow(
                title = if (verifying) "Verifying…" else "Verify connection", description = verifyMessage ?: "Check your Serializd account and sign-in.",
                icon = Icons.Rounded.Link, enabled = connected && !verifying, isTablet = isTablet, trailingContent = chevron,
                onClick = {
                    if (!verifying) scope.launch {
                        verifying = true
                        verifyMessage = when (manager.checkConnection(profileId)) {
                            SerializdConnectionState.Connected -> "Connected as ${state.username}."
                            SerializdConnectionState.TemporarilyUnavailable -> "Serializd is unavailable right now. Try again later."
                            SerializdConnectionState.Disconnected, SerializdConnectionState.Connecting -> "Not connected."
                            else -> "Sign in again to keep syncing."
                        }
                        verifying = false
                    }
                },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsNavigationRow(
                title = "Sync activity", description = "View recent syncs and any skipped items.",
                icon = Icons.Rounded.MonitorHeart, enabled = connected, isTablet = isTablet, trailingContent = chevron, onClick = { showHistory = true },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsNavigationRow(
                title = "Retry failed items",
                description = if (state.failedCount > 0) "${state.failedCount} ${if (state.failedCount == 1) "item" else "items"} didn't sync. Try sending them again." else "Nothing needs a retry.",
                icon = Icons.Rounded.Refresh, enabled = connected && state.failedCount > 0, isTablet = isTablet, trailingContent = chevron,
                onClick = { manager.retryAll(profileId) },
            )
            SettingsGroupDivider(isTablet = isTablet)
            Row(
                modifier = Modifier.fillMaxWidth().clickable(enabled = connected) { confirmDisconnect = true }.padding(horizontal = horizontal, vertical = if (isTablet) 16.dp else 14.dp)
                    .alpha(if (connected) 1f else 0.5f).semantics { role = Role.Button },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(modifier = Modifier.size(if (isTablet) 42.dp else 36.dp), contentAlignment = Alignment.Center) { Icon(Icons.AutoMirrored.Rounded.Logout, contentDescription = null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(24.dp)) }
                Spacer(Modifier.width(if (isTablet) 16.dp else 14.dp))
                Text("Disconnect Serializd", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = tokens.colors.textPrimary, modifier = Modifier.weight(1f))
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = tokens.colors.textMuted)
            }
        }
        if (!connected) Text("Connect your Serializd account on the previous page.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp))
    }
    if (showHistory) SerializdHistorySheet(onDismiss = { showHistory = false })
    if (confirmDisconnect) {
        AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text("Disconnect Serializd?") },
            text = { Text("BannerTV stops sending to ${state.username ?: "Serializd"} and deletes the saved email, password and token from this device. Anything already on Serializd stays there. Waiting items are dropped. Other profiles are not affected.") },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = { confirmDisconnect = false; scope.launch { manager.disconnect(profileId, deleteLocalHistory = false) } }) { Text("Disconnect, keep local history", color = MaterialTheme.colorScheme.error) }
                    TextButton(onClick = { confirmDisconnect = false; scope.launch { manager.disconnect(profileId, deleteLocalHistory = true) } }) { Text("Disconnect and delete local history", color = MaterialTheme.colorScheme.error) }
                    TextButton(onClick = { confirmDisconnect = false }) { Text("Cancel") }
                }
            },
        )
    }
}
