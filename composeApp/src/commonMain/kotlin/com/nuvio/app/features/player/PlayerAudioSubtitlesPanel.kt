package com.nuvio.app.features.player

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.CloudDownload
import androidx.compose.material.icons.rounded.ExpandLess
import androidx.compose.material.icons.rounded.ExpandMore
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nuvio.app.core.ui.PlatformBackHandler
import com.nuvio.app.core.ui.withDuplicateSafeLazyKeys
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.addon_title
import nuvio.composeapp.generated.resources.compose_player_audio
import nuvio.composeapp.generated.resources.compose_player_built_in
import nuvio.composeapp.generated.resources.compose_player_no_audio_tracks_available
import nuvio.composeapp.generated.resources.compose_player_subtitles
import nuvio.composeapp.generated.resources.settings_playback_option_forced
import nuvio.composeapp.generated.resources.subtitle_language_unknown
import org.jetbrains.compose.resources.stringResource

private enum class AudioSubtitlesPage { Main, AudioAdjustments, SubtitleStyle }

private val Dimmed = Color.White.copy(alpha = 0.6f)

/**
 * Audio and subtitles together, the way Netflix lays them out: a dark full-screen panel with an Audio column and a
 * Subtitles column, the current choice in bold with a tick. A choice applies straight away. Audio delay and volume,
 * and subtitle style and timing, sit one tap further in so the lists stay clean.
 */
@Composable
internal fun PlayerAudioSubtitlesPanel(
    visible: Boolean,
    showSubtitles: Boolean,
    audioTracks: List<AudioTrack>,
    selectedAudioIndex: Int,
    onAudioTrackSelected: (Int) -> Unit,
    showAudioDelay: Boolean,
    audioDelayMs: Int,
    onAudioDelayChanged: (Int) -> Unit,
    showAudioAmplification: Boolean,
    audioAmplificationDb: Int,
    keepAudioAmplification: Boolean,
    onAudioAmplificationChanged: (Int) -> Unit,
    onKeepAudioAmplificationChanged: (Boolean) -> Unit,
    showCenterMix: Boolean,
    centerMixLevelDb: Int,
    onCenterMixLevelChanged: (Int) -> Unit,
    subtitleTracks: List<SubtitleTrack>,
    selectedSubtitleIndex: Int,
    addonSubtitles: List<AddonSubtitle>,
    selectedAddonSubtitleId: String?,
    isLoadingAddonSubtitles: Boolean,
    preferredSubtitleLanguage: String,
    secondaryPreferredSubtitleLanguage: String?,
    subtitleStyle: SubtitleStyleState,
    subtitleDelayMs: Int,
    selectedAddonSubtitle: AddonSubtitle?,
    subtitleAutoSyncState: SubtitleAutoSyncUiState,
    onBuiltInSubtitleSelected: (Int) -> Unit,
    onAddonSubtitleSelected: (AddonSubtitle) -> Unit,
    onFetchAddonSubtitles: () -> Unit,
    onSubtitleStyleChanged: (SubtitleStyleState) -> Unit,
    onSubtitleDelayChanged: (Int) -> Unit,
    onSubtitleDelayReset: () -> Unit,
    onSyncByEarClick: () -> Unit,
    onAutoSyncCapture: () -> Unit,
    onAutoSyncCueSelected: (SubtitleSyncCue) -> Unit,
    onAutoSyncReload: () -> Unit,
    onDismiss: () -> Unit,
) {
    var page by remember(visible) { mutableStateOf(AudioSubtitlesPage.Main) }
    PlatformBackHandler(enabled = visible) {
        if (page != AudioSubtitlesPage.Main) page = AudioSubtitlesPage.Main else onDismiss()
    }

    // Subtitles: what is playing now, and the choice just tapped until the player reports it back.
    val effectiveAddon = selectedAddonSubtitle ?: addonSubtitles.findSelectedAddon(selectedAddonSubtitleId)
    val playbackLanguageKey = selectedSubtitleLanguageKey(subtitleTracks, selectedSubtitleIndex, effectiveAddon)
    val playbackOptionId = selectedSubtitleOptionId(subtitleTracks, selectedSubtitleIndex, effectiveAddon)
    val subtitleKey = subtitleTracksStructureKey(subtitleTracks)
    val addonKey = addonSubtitlesStructureKey(addonSubtitles)
    var pendingLanguageKey by remember(visible) { mutableStateOf<String?>(null) }
    var pendingOptionId by remember(visible) { mutableStateOf<String?>(null) }
    var expandedLanguageKey by remember(visible) { mutableStateOf<String?>(null) }
    LaunchedEffect(playbackLanguageKey, playbackOptionId) {
        pendingLanguageKey = null
        pendingOptionId = null
    }
    val activeLanguageKey = pendingLanguageKey ?: playbackLanguageKey
    val activeOptionId = if (pendingLanguageKey != null) pendingOptionId else playbackOptionId
    val languages = remember(
        subtitleKey, addonKey, preferredSubtitleLanguage, secondaryPreferredSubtitleLanguage,
        subtitleStyle.showOnlyPreferredLanguages, playbackLanguageKey,
    ) {
        buildSubtitleLanguageItems(
            subtitleTracks = subtitleTracks,
            addonSubtitles = addonSubtitles,
            preferredLanguage = preferredSubtitleLanguage,
            secondaryPreferredLanguage = secondaryPreferredSubtitleLanguage,
            showOnlyPreferredLanguages = subtitleStyle.showOnlyPreferredLanguages,
            selectedLanguageKey = playbackLanguageKey,
        )
    }
    // With no preferred subtitle language set in Settings, English comes straight after Off.
    val defaultLanguageKey = remember { subtitleLanguageKey("en") }
    val orderedLanguages = remember(languages, preferredSubtitleLanguage, secondaryPreferredSubtitleLanguage, defaultLanguageKey) {
        val hasPreference = listOf(preferredSubtitleLanguage, secondaryPreferredSubtitleLanguage).any { code ->
            !code.isNullOrBlank() && !code.equals(SubtitleLanguageOption.NONE, true) && !code.equals(SubtitleLanguageOption.FORCED, true)
        }
        val english = languages.firstOrNull { it.key == defaultLanguageKey }
        if (hasPreference || english == null) languages
        else languages.filter { it.key == SubtitleOffLanguageKey } + english + languages.filter { it.key != SubtitleOffLanguageKey && it.key != defaultLanguageKey }
    }
    val optionsByLanguage = remember(subtitleKey, addonKey) {
        languages.associate { it.key to buildSubtitleSelectionOptions(it.key, subtitleTracks, addonSubtitles) }
    }
    fun select(option: SubtitleSelectionOption, languageKey: String) {
        pendingLanguageKey = languageKey
        pendingOptionId = option.id
        when (option) {
            is SubtitleSelectionOption.BuiltIn -> onBuiltInSubtitleSelected(option.track.index)
            is SubtitleSelectionOption.Addon -> onAddonSubtitleSelected(option.subtitle)
        }
    }
    val onLanguageClick: (String) -> Unit = { key ->
        when {
            key == SubtitleOffLanguageKey -> {
                pendingLanguageKey = SubtitleOffLanguageKey
                pendingOptionId = null
                expandedLanguageKey = null
                onBuiltInSubtitleSelected(-1)
            }
            // With "Choose subtitle files" on, tapping the language that is on opens (or closes) its files.
            key == activeLanguageKey -> if (subtitleStyle.chooseSubtitleFiles) {
                expandedLanguageKey = if (expandedLanguageKey == key) null else key
            }
            else -> {
                val options = optionsByLanguage[key].orEmpty()
                options.firstOrNull()?.let { select(it, key) }
                expandedLanguageKey = null
            }
        }
    }
    val hasAudioAdjustments = showAudioDelay || showAudioAmplification || showCenterMix

    AnimatedVisibility(visible = visible, enter = fadeIn(tween(220)), exit = fadeOut(tween(180))) {
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.95f))
                // Taps on the empty dark area don't fall through to the player underneath.
                .pointerInput(Unit) { detectTapGestures { } }
                .windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            AnimatedContent(
                targetState = page,
                transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(140)) },
                label = "audio-subtitles-page",
                modifier = Modifier.fillMaxSize(),
            ) { current ->
                when (current) {
                    AudioSubtitlesPage.Main -> BoxWithConstraints(Modifier.fillMaxSize().padding(top = 56.dp, start = 24.dp, end = 24.dp)) {
                        val sideBySide = maxWidth >= 520.dp && showSubtitles
                        val audio: LazyListScope.() -> Unit = {
                            audioColumn(audioTracks, selectedAudioIndex, onAudioTrackSelected, hasAudioAdjustments, withHeading = !sideBySide, showDetails = subtitleStyle.showAudioTrackDetails) {
                                page = AudioSubtitlesPage.AudioAdjustments
                            }
                        }
                        val subtitles: LazyListScope.() -> Unit = {
                            subtitlesColumn(
                                languages = orderedLanguages,
                                withHeading = !sideBySide,
                                optionsByLanguage = optionsByLanguage,
                                activeLanguageKey = activeLanguageKey,
                                activeOptionId = activeOptionId,
                                expandedLanguageKey = expandedLanguageKey,
                                chooseFiles = subtitleStyle.chooseSubtitleFiles,
                                hasAddonSubtitles = addonSubtitles.isNotEmpty(),
                                isLoadingAddonSubtitles = isLoadingAddonSubtitles,
                                onLanguageClick = onLanguageClick,
                                onOptionClick = { option, key -> select(option, key) },
                                onFetch = onFetchAddonSubtitles,
                                onStyle = { page = AudioSubtitlesPage.SubtitleStyle },
                            )
                        }
                        if (sideBySide) {
                            // Side by side, each heading stays put while its list scrolls under it.
                            Row(
                                Modifier.align(Alignment.TopCenter).widthIn(max = 860.dp).fillMaxSize(),
                                horizontalArrangement = Arrangement.spacedBy(48.dp),
                            ) {
                                Column(Modifier.weight(1f).fillMaxHeight()) {
                                    ColumnHeading(stringResource(Res.string.compose_player_audio))
                                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp), content = audio)
                                }
                                Column(Modifier.weight(1f).fillMaxHeight()) {
                                    ColumnHeading(stringResource(Res.string.compose_player_subtitles))
                                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp), content = subtitles)
                                }
                            }
                        } else {
                            LazyColumn(
                                Modifier.align(Alignment.TopCenter).widthIn(max = 520.dp).fillMaxSize(),
                                contentPadding = PaddingValues(bottom = 24.dp),
                            ) {
                                audio()
                                if (showSubtitles) {
                                    item { Spacer(Modifier.size(28.dp)) }
                                    subtitles()
                                }
                            }
                        }
                    }

                    AudioSubtitlesPage.AudioAdjustments -> SubPage("Audio delay & volume", onBack = { page = AudioSubtitlesPage.Main }) {
                        if (showAudioDelay) AudioDelaySection(audioDelayMs, onAudioDelayChanged, Modifier.padding(top = 12.dp))
                        if (showAudioAmplification) {
                            AudioAmplificationSection(
                                gainDb = audioAmplificationDb,
                                keep = keepAudioAmplification,
                                onGainChanged = onAudioAmplificationChanged,
                                onKeepChanged = onKeepAudioAmplificationChanged,
                                modifier = Modifier.padding(top = 20.dp),
                            )
                        }
                        if (showCenterMix) CenterMixSection(centerMixLevelDb, onCenterMixLevelChanged, Modifier.padding(top = 20.dp))
                    }

                    AudioSubtitlesPage.SubtitleStyle -> SubPage("Subtitle style & timing", onBack = { page = AudioSubtitlesPage.Main }) {
                        SubtitleStylePanel(
                            style = subtitleStyle,
                            subtitleDelayMs = subtitleDelayMs,
                            selectedAddonSubtitle = effectiveAddon,
                            subtitleAutoSyncState = subtitleAutoSyncState,
                            isCompact = true,
                            showHeader = false,
                            onStyleChanged = onSubtitleStyleChanged,
                            onSubtitleDelayChanged = onSubtitleDelayChanged,
                            onSubtitleDelayReset = onSubtitleDelayReset,
                            onSyncByEarClick = onSyncByEarClick,
                            onAutoSyncCapture = onAutoSyncCapture,
                            onAutoSyncCueSelected = onAutoSyncCueSelected,
                            onAutoSyncReload = onAutoSyncReload,
                        )
                    }
                }
            }
            Icon(
                Icons.Rounded.Close,
                contentDescription = "Close",
                tint = Color.White,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(top = 8.dp, end = 16.dp)
                    .size(44.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onDismiss)
                    .padding(10.dp),
            )
        }
    }
}

private fun LazyListScope.audioColumn(
    tracks: List<AudioTrack>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    hasAdjustments: Boolean,
    withHeading: Boolean,
    showDetails: Boolean,
    onAdjustments: () -> Unit,
) {
    if (withHeading) item(key = "audio-heading") { ColumnHeading(stringResource(Res.string.compose_player_audio)) }
    if (tracks.isEmpty()) {
        item(key = "audio-empty") {
            Text(
                stringResource(Res.string.compose_player_no_audio_tracks_available),
                style = MaterialTheme.typography.titleMedium,
                color = Dimmed,
                modifier = Modifier.padding(start = ChoiceTextStart, top = 6.dp),
            )
        }
    }
    item(key = "audio-tracks") {
        // Plain names ("English", "Spanish (Latin America)"); the technical label only with the setting on.
        val labels = tracks.mapNotNull { it.language?.takeIf(String::isNotBlank) }.distinct().associateWith { languageLabelForCode(it) }
        val names = remember(tracks, labels) { friendlyAudioNames(tracks) { code -> labels[code] ?: code } }
        Column {
            tracks.forEach { track ->
                val friendly = names[track.index]
                ChoiceRow(
                    label = friendly?.name ?: track.label,
                    detail = if (showDetails) listOfNotNull(friendly?.detail, track.label.takeIf { it.isNotBlank() && it != friendly?.name }).joinToString(" · ").ifBlank { null } else null,
                    selected = track.index == selectedIndex,
                    onClick = { onSelect(track.index) },
                )
            }
        }
    }
    if (hasAdjustments) item(key = "audio-more") { LinkRow("Audio delay & volume", onClick = onAdjustments) }
}

private fun LazyListScope.subtitlesColumn(
    languages: List<SubtitleLanguageItem>,
    withHeading: Boolean,
    optionsByLanguage: Map<String, List<SubtitleSelectionOption>>,
    activeLanguageKey: String,
    activeOptionId: String?,
    expandedLanguageKey: String?,
    chooseFiles: Boolean,
    hasAddonSubtitles: Boolean,
    isLoadingAddonSubtitles: Boolean,
    onLanguageClick: (String) -> Unit,
    onOptionClick: (SubtitleSelectionOption, String) -> Unit,
    onFetch: () -> Unit,
    onStyle: () -> Unit,
) {
    if (withHeading) item(key = "subs-heading") { ColumnHeading(stringResource(Res.string.compose_player_subtitles)) }
    languages.forEach { language ->
        val options = optionsByLanguage[language.key].orEmpty()
        val isActive = language.key == activeLanguageKey
        // By default it's just languages (a tap plays the first file); the files show only with the setting on.
        val expandable = chooseFiles && isActive && options.size > 1
        item(key = "subs-lang:${language.key}") {
            val label = when (language.key) {
                SubtitleOffLanguageKey -> "Off"
                SubtitleUnknownLanguageKey -> stringResource(Res.string.subtitle_language_unknown)
                else -> languageLabelForCode(language.key)
            }
            ChoiceRow(
                label = label,
                detail = if (chooseFiles && options.size > 1) "${options.size}" else null,
                selected = isActive,
                trailing = if (expandable) (if (expandedLanguageKey == language.key) Icons.Rounded.ExpandLess else Icons.Rounded.ExpandMore) else null,
                onClick = { onLanguageClick(language.key) },
            )
        }
        if (expandable && expandedLanguageKey == language.key) {
            // Two add-ons can list the very same file, so keys go through the duplicate-safe helper.
            items(options.withDuplicateSafeLazyKeys { it.id }, key = { "subs-opt:${language.key}:${it.lazyKey}" }) { entry ->
                val option = entry.value
                VersionRow(option, selected = option.id == activeOptionId, onClick = { onOptionClick(option, language.key) })
            }
        }
    }
    if (isLoadingAddonSubtitles) {
        item(key = "subs-loading") {
            Row(Modifier.padding(start = ChoiceTextStart, top = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(color = Dimmed, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                Text("Finding more subtitles…", style = MaterialTheme.typography.bodyLarge, color = Dimmed)
            }
        }
    } else if (!hasAddonSubtitles) {
        item(key = "subs-fetch") { LinkRow("Find more subtitles", icon = Icons.Rounded.CloudDownload, onClick = onFetch) }
    }
    if (activeLanguageKey != SubtitleOffLanguageKey) {
        item(key = "subs-style") { LinkRow("Subtitle style & timing", onClick = onStyle) }
    }
}

private val CheckSlot = 28.dp
private val ChoiceTextStart = CheckSlot + 4.dp

@Composable
private fun ColumnHeading(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleLarge,
        fontWeight = FontWeight.Bold,
        color = Color.White,
        modifier = Modifier.padding(start = ChoiceTextStart, bottom = 14.dp),
    )
}

/** One choice: a tick and bold white when it's the one playing, dimmed otherwise. */
@Composable
private fun ChoiceRow(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    detail: String? = null,
    trailing: androidx.compose.ui.graphics.vector.ImageVector? = null,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 46.dp)
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(CheckSlot), contentAlignment = Alignment.Center) {
            if (selected) Icon(Icons.Rounded.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.width(4.dp))
        Text(
            label,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
            color = if (selected) Color.White else Dimmed,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        detail?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodyMedium,
                color = Color.White.copy(alpha = 0.4f),
                maxLines = 1,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
        Spacer(Modifier.weight(0.001f))
        trailing?.let { Icon(it, contentDescription = null, tint = Dimmed, modifier = Modifier.padding(start = 6.dp).size(22.dp)) }
    }
}

/** A version of the chosen language (the stream's own track, or one from an add-on), shown indented under it. */
@Composable
private fun VersionRow(option: SubtitleSelectionOption, selected: Boolean, onClick: () -> Unit) {
    val source: String
    val name: String
    when (option) {
        is SubtitleSelectionOption.BuiltIn -> {
            source = stringResource(Res.string.compose_player_built_in)
            val forced = if (option.track.isForced) " · ${stringResource(Res.string.settings_playback_option_forced)}" else ""
            name = localizedTrackDisplayName(option.track.label, option.track.language, option.track.index) + forced
        }
        is SubtitleSelectionOption.Addon -> {
            source = option.subtitle.addonName ?: stringResource(Res.string.addon_title)
            name = (option.subtitle.label ?: option.subtitle.display).takeIf { it.isNotBlank() }
                ?: languageLabelForCode(option.subtitle.language)
        }
    }
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(start = ChoiceTextStart + 12.dp, top = 7.dp, bottom = 7.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                name,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                color = if (selected) Color.White else Dimmed,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(source, style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.4f), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (selected) Icon(Icons.Rounded.Check, contentDescription = null, tint = Color.White, modifier = Modifier.padding(start = 8.dp).size(18.dp))
    }
}

@Composable
private fun LinkRow(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .padding(top = 14.dp)
            .clip(RoundedCornerShape(50))
            .clickable(onClick = onClick)
            .padding(start = ChoiceTextStart, end = 12.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        icon?.let { Icon(it, contentDescription = null, tint = Dimmed, modifier = Modifier.size(18.dp)) }
        Text(text, style = MaterialTheme.typography.bodyLarge, color = Dimmed)
        if (icon == null) Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Dimmed, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun SubPage(title: String, onBack: () -> Unit, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().padding(top = 8.dp, start = 16.dp, end = 16.dp)) {
        Column(
            Modifier
                .align(Alignment.TopCenter)
                .widthIn(max = 520.dp)
                .fillMaxWidth()
                .fillMaxHeight(),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.AutoMirrored.Rounded.ArrowBack,
                    contentDescription = "Back",
                    tint = Color.White,
                    modifier = Modifier.size(44.dp).clip(CircleShape).clickable(onClick = onBack).padding(10.dp),
                )
                Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = Color.White)
            }
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = 12.dp, end = 12.dp, bottom = 24.dp)) {
                content()
            }
        }
    }
}
