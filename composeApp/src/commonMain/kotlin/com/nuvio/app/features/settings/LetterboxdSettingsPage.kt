package com.nuvio.app.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Logout
import androidx.compose.material.icons.rounded.BarChart
import androidx.compose.material.icons.rounded.BookmarkBorder
import androidx.compose.material.icons.rounded.CheckCircleOutline
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Movie
import androidx.compose.material.icons.rounded.MenuBook
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.PlayCircleOutline
import androidx.compose.material.icons.rounded.RateReview
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
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
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.nuvio.app.core.format.localUtcOffsetMs
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.features.letterboxd.LetterboxdConnectResult
import com.nuvio.app.features.letterboxd.LetterboxdConnectionState
import com.nuvio.app.features.letterboxd.LetterboxdHistorySheet
import com.nuvio.app.features.letterboxd.LetterboxdJournalSheet
import com.nuvio.app.features.letterboxd.LetterboxdRuntime
import com.nuvio.app.features.letterboxd.LetterboxdScreenState
import com.nuvio.app.features.letterboxd.LetterboxdScreenText
import com.nuvio.app.features.letterboxd.LetterboxdSettings
import com.nuvio.app.features.letterboxd.LetterboxdSignInWebView
import com.nuvio.app.features.letterboxd.LetterboxdWatchedImport
import com.nuvio.app.features.letterboxd.LetterboxdWatchlistSheet
import com.nuvio.app.features.letterboxd.rememberLetterboxdProfileId
import com.nuvio.app.features.serializd.SerializdClock
import com.nuvio.app.features.serializd.SerializdTone
import kotlinx.coroutines.launch

// The Letterboxd settings: the same two pages as Serializd (a short main page and an Advanced page), built from the same components and
// drawn from a shared screen state whose wording matches Serializd's. Only what is Letterboxd's own differs: its web sign-in, the Watch
// Journal, and the film-specific choices.

/** The main page: account and sync, the three automatic-tracking switches, the member's data, and the way to the advanced page. */
internal fun LazyListScope.letterboxdSettingsContent(isTablet: Boolean, onAdvancedClick: () -> Unit) {
    item { LetterboxdAccountSection(isTablet, onAdvancedClick) }
    item { LetterboxdAutomaticTrackingSection(isTablet) }
    item { LetterboxdYourDataSection(isTablet, onAdvancedClick) }
}

/** The advanced page: tracking preferences, import and data, connection and diagnostics. */
internal fun LazyListScope.letterboxdAdvancedSettingsContent(isTablet: Boolean) {
    item { LetterboxdTrackingPreferencesSection(isTablet) }
    item { LetterboxdImportSection(isTablet) }
    item { LetterboxdConnectionSection(isTablet) }
}

@Composable
internal fun rememberLetterboxdScreen(profileId: Int): LetterboxdScreenState {
    val manager = remember { LetterboxdRuntime.manager }
    val clock = remember { SerializdClock { localUtcOffsetMs(it) } }
    val flow = remember(profileId) { manager.screenFlow(profileId, clock) }
    val initial = remember(profileId) { manager.screenNow(profileId, clock) }
    val state by flow.collectAsStateWithLifecycle(initialValue = initial)
    return state
}

/** The Letterboxd icon, as supplied, in a rounded tile. */
@Composable
internal fun LetterboxdMark(size: androidx.compose.ui.unit.Dp) {
    androidx.compose.foundation.Image(
        painter = integrationLogoPainter(IntegrationLogo.Letterboxd), contentDescription = "Letterboxd",
        modifier = Modifier.size(size).clip(RoundedCornerShape(size * 0.22f)),
        contentScale = androidx.compose.ui.layout.ContentScale.Crop,
    )
}

private class PendingSignIn(val cookies: Map<String, String>, val userAgent: String)

// ---------------------------------------------------------------------------------------------- main page

@Composable
private fun LetterboxdAccountSection(isTablet: Boolean, onAdvancedClick: () -> Unit) {
    val manager = remember { LetterboxdRuntime.manager }
    val profileId = rememberLetterboxdProfileId()
    val state = rememberLetterboxdScreen(profileId)
    val scope = rememberCoroutineScope()
    val tokens = MaterialTheme.nuvio
    val horizontal = if (isTablet) 20.dp else 16.dp

    var showSignIn by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var needsUsername by remember { mutableStateOf<PendingSignIn?>(null) }

    fun finishSignIn(pending: PendingSignIn, username: String?) {
        working = true; error = null
        scope.launch {
            when (val r = manager.connect(profileId, pending.cookies, pending.userAgent, username)) {
                is LetterboxdConnectResult.Connected -> { needsUsername = null }
                LetterboxdConnectResult.NeedsUsername -> needsUsername = pending
                is LetterboxdConnectResult.Failed -> { error = r.message; needsUsername = null }
            }
            working = false
        }
    }

    SettingsSection(title = "Letterboxd", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            if (!state.connected) {
                Column(modifier = Modifier.fillMaxWidth().padding(horizontal = horizontal, vertical = 14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LetterboxdMark(48.dp)
                        Spacer(Modifier.width(12.dp))
                        Column {
                            Text("Letterboxd", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                            Text("Log films to your diary, rate and review.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    Text(
                        "You sign in on Letterboxd's own page. BannerTV never sees your password. Only the session is kept, in this device's secure storage, for this profile, and Disconnect removes it.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
                    Button(
                        onClick = { error = null; showSignIn = true }, enabled = !working, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                        shape = RoundedCornerShape(16.dp), colors = ButtonDefaults.buttonColors(containerColor = tokens.colors.accent, contentColor = tokens.colors.onAccent),
                    ) {
                        if (working) { CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = tokens.colors.onAccent); Spacer(Modifier.width(8.dp)) }
                        Text(if (working) "Connecting…" else "Connect Letterboxd", fontWeight = FontWeight.SemiBold)
                    }
                }
            } else {
                Row(
                    modifier = Modifier.fillMaxWidth().clickable(onClick = onAdvancedClick).padding(horizontal = horizontal, vertical = 14.dp)
                        .semantics { role = Role.Button; contentDescription = "${state.username}, ${state.connectionLabel}. Opens advanced settings." },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    LetterboxdMark(56.dp)
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
                        else Icon(if (state.syncTone == SerializdTone.Good) Icons.Rounded.Sync else Icons.Rounded.ErrorOutline, contentDescription = null, tint = if (state.syncTone == SerializdTone.Good) tokens.colors.textPrimary else toneColor(state.syncTone, tokens.colors.textPrimary, MaterialTheme.colorScheme.error))
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(state.syncHeadline, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary)
                        state.syncDetail?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted) }
                    }
                }
                error?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(horizontal = horizontal)) }
                if (state.needsReconnect) {
                    Button(
                        onClick = { error = null; showSignIn = true }, enabled = !working, modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 12.dp).heightIn(min = 48.dp),
                        shape = RoundedCornerShape(16.dp), colors = ButtonDefaults.buttonColors(containerColor = tokens.colors.accent, contentColor = tokens.colors.onAccent),
                    ) { Text("Sign in again", fontWeight = FontWeight.SemiBold) }
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

    if (showSignIn) {
        Dialog(onDismissRequest = { showSignIn = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Column(modifier = Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                    Row(modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { showSignIn = false }) { Icon(Icons.Rounded.Close, contentDescription = "Close") }
                        Text("Sign in to Letterboxd", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    }
                    LetterboxdSignInWebView(
                        modifier = Modifier.weight(1f).fillMaxWidth(),
                        onSignedIn = { cookies, agent, username ->
                            showSignIn = false
                            finishSignIn(PendingSignIn(cookies, agent), username ?: state.username)
                        },
                    )
                }
            }
        }
    }

    needsUsername?.let { pending ->
        var typed by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { needsUsername = null },
            title = { Text("Your Letterboxd username") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("You are signed in, but the username could not be read from Letterboxd. Type it exactly as it appears in your profile address.", style = MaterialTheme.typography.bodyMedium)
                    OutlinedTextField(value = typed, onValueChange = { typed = it.trim() }, singleLine = true, label = { Text("Username") })
                }
            },
            confirmButton = { TextButton(enabled = typed.length >= 2, onClick = { finishSignIn(pending, typed) }) { Text("Continue") } },
            dismissButton = { TextButton(onClick = { needsUsername = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun LetterboxdAutomaticTrackingSection(isTablet: Boolean) {
    val manager = remember { LetterboxdRuntime.manager }
    val profileId = rememberLetterboxdProfileId()
    val state = rememberLetterboxdScreen(profileId)
    val scope = rememberCoroutineScope()
    val connected = state.connected
    var note by remember { mutableStateOf<String?>(null) }
    var watchlistBusy by remember { mutableStateOf(false) }

    SettingsSection(title = "Automatic tracking", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            SettingsSwitchRow(
                icon = Icons.Rounded.PlayCircleOutline, title = "Log watched films", description = "Automatically log films you finish watching.",
                checked = state.logFilms, enabled = connected, isTablet = isTablet,
                onCheckedChange = { v -> manager.updateSettings(profileId) { it.copy(autoLogMovies = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.StarBorder, title = "Sync ratings", description = "Send your BannerTV ratings to Letterboxd.",
                checked = state.syncRatings, enabled = connected, isTablet = isTablet,
                onCheckedChange = { v -> manager.updateSettings(profileId) { it.copy(syncRatings = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.BookmarkBorder, title = "Sync watchlist", description = "Add films from your Letterboxd watchlist to My List.",
                checked = state.syncWatchlist, enabled = connected && !watchlistBusy, isTablet = isTablet,
                onCheckedChange = { v ->
                    if (!watchlistBusy) { watchlistBusy = true; note = null; scope.launch { note = manager.setSyncWatchlist(profileId, v); watchlistBusy = false } }
                },
            )
        }
        val footer = if (!connected) "Connect your Letterboxd account to use these." else note
        if (footer != null) Text(footer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp))
    }
}

/** The choice that goes with importing a Letterboxd history, then the import itself and the watchlist read that follows it. */
@Composable
private fun rememberLetterboxdImport(profileId: Int, onDone: (String) -> Unit): Pair<Boolean, () -> Unit> {
    val manager = remember { LetterboxdRuntime.manager }
    val scope = rememberCoroutineScope()
    var asking by remember { mutableStateOf(false) }
    var running by remember { mutableStateOf(false) }
    if (asking) {
        AlertDialog(
            onDismissRequest = { asking = false },
            title = { Text("Import your Letterboxd films") },
            text = {
                Text("Your diary and every film you have marked watched on Letterboxd go into the Watch Journal. Do you also want those films marked as watched in BannerTV? That keeps their watched badges and hides them from recommendations. It is saved to your BannerTV account but not sent to Trakt or Simkl. A big library takes about ten minutes; keep this page open until it finishes (progress is saved, so running it again continues where it stopped).")
            },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    listOf("Import and mark as watched" to true, "Import to Watch Journal only" to false).forEach { (label, mark) ->
                        TextButton(onClick = {
                            asking = false
                            scope.launch {
                                running = true
                                val r = LetterboxdWatchedImport.importDiary(profileId, markWatched = mark)
                                if (!r.partial && manager.settingsFlow.value[profileId]?.watchlistToLibrary != false) runCatching { manager.importWatchlist(profileId) }
                                onDone(LetterboxdScreenText.importSentence(r.newFilms, r.couldNotIdentify, r.partial, r.message))
                                running = false
                            }
                        }) { Text(label) }
                    }
                    TextButton(onClick = { asking = false }) { Text("Cancel") }
                }
            },
        )
    }
    return running to { if (!running) asking = true }
}

@Composable
private fun LetterboxdYourDataSection(isTablet: Boolean, onAdvancedClick: () -> Unit) {
    val profileId = rememberLetterboxdProfileId()
    val state = rememberLetterboxdScreen(profileId)
    var message by remember { mutableStateOf<String?>(null) }
    var showJournal by remember { mutableStateOf(false) }
    var showWatchlist by remember { mutableStateOf(false) }
    val (importing, startImport) = rememberLetterboxdImport(profileId) { message = it }
    if (!state.connected) return
    val tokens = MaterialTheme.nuvio
    val chevron: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = { Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = tokens.colors.textMuted) }

    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        SettingsSection(title = "Your data", isTablet = isTablet) {
            SettingsGroup(isTablet = isTablet) {
                SettingsNavigationRow(title = "Watch history", description = state.watchHistoryLine, icon = Icons.Rounded.Movie, isTablet = isTablet, trailingContent = chevron, onClick = { showJournal = true })
                SettingsGroupDivider(isTablet = isTablet)
                SettingsNavigationRow(title = "Watchlist", description = state.watchlistLine, icon = Icons.Rounded.BookmarkBorder, isTablet = isTablet, trailingContent = chevron, onClick = { showWatchlist = true })
                SettingsGroupDivider(isTablet = isTablet)
                SettingsNavigationRow(
                    title = if (importing || state.busy) "Importing…" else "Import from Letterboxd",
                    description = (if (state.busy) state.syncHeadline else null) ?: message,
                    icon = Icons.Rounded.Download, enabled = !importing && !state.busy, isTablet = isTablet, onClick = startImport,
                )
            }
        }
        SettingsGroup(isTablet = isTablet) {
            SettingsNavigationRow(title = "Advanced settings", description = "Tracking, imports, sync rules and more.", icon = Icons.Rounded.Tune, isTablet = isTablet, trailingContent = chevron, onClick = onAdvancedClick)
        }
    }
    if (showJournal) LetterboxdJournalSheet(onDismiss = { showJournal = false })
    if (showWatchlist) LetterboxdWatchlistSheet(onDismiss = { showWatchlist = false })
}

// ---------------------------------------------------------------------------------------------- advanced page

@Composable
private fun LetterboxdTrackingPreferencesSection(isTablet: Boolean) {
    val manager = remember { LetterboxdRuntime.manager }
    val profileId = rememberLetterboxdProfileId()
    val state = rememberLetterboxdScreen(profileId)
    val settings: LetterboxdSettings = state.settings
    val connected = state.connected
    val tracking = connected && settings.autoLogMovies
    fun change(f: (LetterboxdSettings) -> LetterboxdSettings) = manager.updateSettings(profileId, f)

    SettingsSection(title = "Tracking preferences", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            SettingsSwitchRow(
                icon = Icons.Rounded.Repeat, title = "Track rewatches automatically", description = "Mark a film you watched before as a rewatch.",
                checked = settings.logRewatches, enabled = tracking, isTablet = isTablet, onCheckedChange = { v -> change { it.copy(logRewatches = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.FavoriteBorder, title = "Sync favorites as likes", description = "Also like films on Letterboxd when you log them from My List.",
                checked = settings.syncFavorites, enabled = connected, isTablet = isTablet, onCheckedChange = { v -> change { it.copy(syncFavorites = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            SettingsSwitchRow(
                icon = Icons.Rounded.RateReview, title = "Ask after each film", description = "Show a sheet to rate or review a film when you finish it.",
                checked = settings.showPostWatchPrompt, enabled = tracking, isTablet = isTablet, onCheckedChange = { v -> change { it.copy(showPostWatchPrompt = v) } },
            )
            SettingsGroupDivider(isTablet = isTablet)
            Row(modifier = Modifier.fillMaxWidth().padding(horizontal = if (isTablet) 20.dp else 16.dp, vertical = if (isTablet) 16.dp else 14.dp).alpha(if (tracking) 1f else 0.5f)) {
                Box(modifier = Modifier.size(if (isTablet) 42.dp else 36.dp), contentAlignment = Alignment.Center) { Icon(Icons.Rounded.BarChart, contentDescription = null, tint = MaterialTheme.nuvio.colors.textPrimary, modifier = Modifier.size(24.dp)) }
                Spacer(Modifier.width(if (isTablet) 16.dp else 14.dp))
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("Mark as watched after", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.nuvio.colors.textPrimary, fontWeight = FontWeight.Medium)
                        Text("Count a film as watched when this much has been played.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.nuvio.colors.textMuted)
                    }
                    SerializdSegmented(
                        labels = listOf("90%", "95%", "98%"),
                        selected = listOf(0.90, 0.95, 0.98).indexOfFirst { kotlin.math.abs(settings.completionThreshold - it) < 0.005 },
                        enabled = tracking, onSelect = { i -> change { it.copy(completionThreshold = listOf(0.90, 0.95, 0.98)[i]) } },
                    )
                }
            }
        }
        val footer = if (!connected) "Connect your Letterboxd account to change these."
        else if (!settings.autoLogMovies) "Rewatch, prompt and watched-threshold choices apply when Log watched films is on. They are kept as you set them."
        else null
        if (footer != null) Text(footer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp))
    }
}

@Composable
private fun LetterboxdImportSection(isTablet: Boolean) {
    val profileId = rememberLetterboxdProfileId()
    val manager = remember { LetterboxdRuntime.manager }
    val state = rememberLetterboxdScreen(profileId)
    val scope = rememberCoroutineScope()
    val connected = state.connected
    var message by remember { mutableStateOf<String?>(null) }
    var showJournal by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    val (importing, startImport) = rememberLetterboxdImport(profileId) { message = it }
    val viewings by manager.engine.viewings.collectAsStateWithLifecycle()
    val importedCount = remember(viewings, profileId) { viewings.filter { it.profileId == profileId && it.source == "import" }.map { it.tmdbId }.distinct().size }
    val tokens = MaterialTheme.nuvio
    val chevron: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = { Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = tokens.colors.textMuted) }

    SettingsSection(title = "Import & data transfer", isTablet = isTablet) {
        SettingsGroup(isTablet = isTablet) {
            SettingsNavigationRow(
                title = if (importing || state.busy) "Importing…" else "Import Letterboxd history",
                description = (if (state.busy) state.syncHeadline else null) ?: message ?: "Bring your diary and the films you've watched on Letterboxd into BannerTV.",
                icon = Icons.Rounded.Download, enabled = connected && !importing && !state.busy, isTablet = isTablet, trailingContent = chevron, onClick = startImport,
            )
            if (importedCount > 0) {
                SettingsGroupDivider(isTablet = isTablet)
                SettingsNavigationRow(
                    title = if (working) "Marking…" else "Mark imported films as watched",
                    description = "Marks the ${LetterboxdScreenText.films(importedCount)} imported from Letterboxd as watched in BannerTV. Films already marked are skipped.",
                    icon = Icons.Rounded.CheckCircleOutline, enabled = connected && !working, isTablet = isTablet, trailingContent = chevron,
                    onClick = {
                        if (!working) scope.launch {
                            working = true
                            val r = LetterboxdWatchedImport.markImportedWatched(profileId)
                            message = "${LetterboxdScreenText.films(r.markedWatched)} marked as watched, ${r.alreadyWatched} already ${if (r.alreadyWatched == 1) "was" else "were"}."
                            working = false
                        }
                    },
                )
            }
            SettingsGroupDivider(isTablet = isTablet)
            SettingsNavigationRow(
                title = "View Watch Journal", description = "The films you finished here, and how each stands on Letterboxd.",
                icon = Icons.Rounded.MenuBook, enabled = connected, isTablet = isTablet, trailingContent = chevron, onClick = { showJournal = true },
            )
        }
    }
    if (showJournal) LetterboxdJournalSheet(onDismiss = { showJournal = false })
}

@Composable
private fun LetterboxdConnectionSection(isTablet: Boolean) {
    val manager = remember { LetterboxdRuntime.manager }
    val profileId = rememberLetterboxdProfileId()
    val state = rememberLetterboxdScreen(profileId)
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
                title = if (verifying) "Verifying…" else "Verify connection", description = verifyMessage ?: "Check your Letterboxd account and sign-in.",
                icon = Icons.Rounded.Link, enabled = connected && !verifying, isTablet = isTablet, trailingContent = chevron,
                onClick = {
                    if (!verifying) scope.launch {
                        verifying = true
                        verifyMessage = when (manager.checkConnection(profileId)) {
                            LetterboxdConnectionState.Connected -> "Connected as ${state.username}."
                            LetterboxdConnectionState.TemporarilyUnavailable -> "Letterboxd is unavailable right now. Try again later."
                            LetterboxdConnectionState.Disconnected, LetterboxdConnectionState.Connecting -> "Not connected."
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
                Text("Disconnect Letterboxd", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = tokens.colors.textPrimary, modifier = Modifier.weight(1f))
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = tokens.colors.textMuted)
            }
        }
        if (!connected) Text("Connect your Letterboxd account on the previous page.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 8.dp))
    }
    if (showHistory) LetterboxdHistorySheet(onDismiss = { showHistory = false })
    if (confirmDisconnect) {
        AlertDialog(
            onDismissRequest = { confirmDisconnect = false },
            title = { Text("Disconnect Letterboxd?") },
            text = {
                Text("BannerTV stops sending to ${state.username ?: "Letterboxd"} and deletes the sign-in from this device. Anything already on Letterboxd stays there. Waiting items are dropped. Other profiles are not affected.")
            },
            confirmButton = {
                Column(horizontalAlignment = Alignment.End) {
                    TextButton(onClick = { confirmDisconnect = false; scope.launch { manager.disconnect(profileId, deleteLocalHistory = false) } }) { Text("Disconnect, keep Watch Journal", color = MaterialTheme.colorScheme.error) }
                    TextButton(onClick = { confirmDisconnect = false; scope.launch { manager.disconnect(profileId, deleteLocalHistory = true) } }) { Text("Disconnect and delete journal", color = MaterialTheme.colorScheme.error) }
                    TextButton(onClick = { confirmDisconnect = false }) { Text("Cancel") }
                }
            },
        )
    }
}
