package com.nuvio.app.features.sportsfocus

import com.nuvio.app.core.ui.tvFocusIndication
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.material.icons.rounded.Star
import com.nuvio.app.core.ui.NuvioToastController
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Insights
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.Chip
import com.nuvio.app.core.ui.PillChip
import com.nuvio.app.core.ui.collapsingTitle
import androidx.compose.ui.input.nestedscroll.nestedScroll
import com.nuvio.app.core.ui.NuvioScreenHeader
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.features.experience.ExperienceMode
import com.nuvio.app.features.experience.ExperienceRepository
import com.nuvio.app.features.livetv.LiveTvChannel
import com.nuvio.app.features.livetv.LiveTvEpgProgram
import com.nuvio.app.features.livetv.LiveTvRepository
import com.nuvio.app.features.livetv.LiveTvScreen
import com.nuvio.app.features.livetv.LiveTvVodPlayback
import com.nuvio.app.features.livetv.rememberLiveTvEpgNowMillis
import com.nuvio.app.features.sports.ChannelMatch
import com.nuvio.app.features.sports.GameState
import com.nuvio.app.features.sports.Sport
import com.nuvio.app.features.sports.SportsCatalog
import com.nuvio.app.features.sports.SportsEvent
import com.nuvio.app.features.sports.SportsReminders
import com.nuvio.app.features.sports.SportsRepository
import com.nuvio.app.features.sports.clockText
import com.nuvio.app.features.sports.compat.LiveTvClock
import com.nuvio.app.features.sports.ui.LeagueMark
import com.nuvio.app.features.sports.ui.SportsActions
import com.nuvio.app.features.sports.ui.StateBadge
import com.nuvio.app.features.sports.ui.TeamLogo
import com.nuvio.app.features.sports.ui.cornerStatus
import com.nuvio.app.features.sports.ui.isMine
import com.nuvio.app.features.sports.ui.use24h
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.live_tv_title
import org.jetbrains.compose.resources.stringResource

internal enum class LiveSegment(val label: String) { Channels("Channels"), Guide("Guide"), Sports("Sports") }

/** Balanced has its own Sports tab, so Live stays channels and guide there; Sports focus keeps the games segment. */
internal fun ExperienceMode.liveSegments(): List<LiveSegment> =
    if (this == ExperienceMode.Balanced) LiveSegment.entries.filter { it != LiveSegment.Sports } else LiveSegment.entries

/** A switch under the Live title: a white thumb that slides between the segments. */
@Composable
internal fun LiveSegmentedControl(selected: LiveSegment, onSelect: (LiveSegment) -> Unit, modifier: Modifier = Modifier) {
    val tokens = MaterialTheme.nuvio
    val mode by ExperienceRepository.mode.collectAsStateWithLifecycle()
    val segments = mode.liveSegments()
    val index = segments.indexOf(selected).coerceAtLeast(0)
    androidx.compose.foundation.layout.BoxWithConstraints(
        modifier.fillMaxWidth().height(40.dp).clip(RoundedCornerShape(50)).background(tokens.colors.textPrimary.copy(alpha = 0.10f)).padding(3.dp),
    ) {
        val segmentWidth = maxWidth / segments.size.coerceAtLeast(1)
        val thumbX by androidx.compose.animation.core.animateDpAsState(
            segmentWidth * index,
            androidx.compose.animation.core.spring(dampingRatio = 0.82f, stiffness = 520f),
        )
        Box(Modifier.offset(x = thumbX).width(segmentWidth).fillMaxHeight().clip(RoundedCornerShape(50)).background(tokens.colors.textPrimary))
        Row(Modifier.fillMaxSize()) {
            segments.forEach { segment ->
                val on = segment == selected
                val color by androidx.compose.animation.animateColorAsState(if (on) tokens.colors.background else tokens.colors.textPrimary.copy(alpha = 0.75f))
                Box(
                    Modifier.weight(1f).fillMaxHeight().clip(RoundedCornerShape(50))
                        .clickable(
                            interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                            indication = tvFocusIndication(),
                        ) { onSelect(segment) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(segment.label, style = MaterialTheme.typography.labelLarge, color = color, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

/** Live: your channels, the TV guide, and the games on now, one switch apart. */
@Composable
fun LiveHub(
    onChannelClick: (LiveTvChannel) -> Unit,
    sportsActions: SportsActions?,
    modifier: Modifier = Modifier,
    scrollToTopRequests: Flow<Unit> = emptyFlow(),
    onVodClick: (LiveTvVodPlayback) -> Unit = {},
) {
    var name by rememberSaveable { mutableStateOf(LiveSegment.Channels.name) }
    val mode by ExperienceRepository.mode.collectAsStateWithLifecycle()
    // A Sports segment left selected from the other mode falls back to Channels.
    val segment = mode.liveSegments().firstOrNull { it.name == name } ?: LiveSegment.Channels
    val select: (LiveSegment) -> Unit = { name = it.name }
    when (segment) {
        LiveSegment.Channels -> LiveTvScreen(
            modifier = modifier,
            scrollToTopRequests = scrollToTopRequests,
            onChannelClick = onChannelClick,
            onVodClick = onVodClick,
            segments = { LiveSegmentedControl(segment, select, Modifier.padding(top = 6.dp, bottom = NuvioTokens.Space.s8)) },
        )
        LiveSegment.Guide -> LiveGuideScreen(segment, select, onChannelClick, modifier)
        LiveSegment.Sports -> if (sportsActions != null) LiveSportsScreen(segment, select, sportsActions, modifier)
    }
}

// ------------------------------------------------------------------------------------------ Guide

private val GUIDE_CHANNEL_WIDTH = 104.dp
private val GUIDE_ROW_HEIGHT = 76.dp
private const val GUIDE_DP_PER_MINUTE = 4f
private const val GUIDE_WINDOW_HOURS = 6
private const val HALF_HOUR_MS = 30 * 60_000L

private data class GuideRow(val channel: LiveTvChannel, val programs: List<LiveTvEpgProgram>)

@Composable
private fun LiveGuideScreen(segment: LiveSegment, onSelect: (LiveSegment) -> Unit, onChannelClick: (LiveTvChannel) -> Unit, modifier: Modifier = Modifier) {
    val tokens = MaterialTheme.nuvio
    LaunchedEffect(Unit) { LiveTvRepository.ensureChannelsLoaded() }
    val ui by LiveTvRepository.uiState.collectAsStateWithLifecycle()
    val now = rememberLiveTvEpgNowMillis()
    val use24h = use24h()
    var mineOnly by rememberSaveable { mutableStateOf(true) }
    var query by rememberSaveable { mutableStateOf("") }
    var showPicker by rememberSaveable { mutableStateOf(false) }
    val myGuide by GuideChannelStore.selected.collectAsStateWithLifecycle()
    // My Guide is the profile's chosen categories of the curated line-up plus the channels they added by hand,
    // minus any playlist category they have hidden.
    var showCategories by rememberSaveable { mutableStateOf(false) }
    val guideCategoryIds by com.nuvio.app.features.livetv.LiveTvChannelPrefs.guideCategories.collectAsStateWithLifecycle()
    val hiddenGroups by com.nuvio.app.features.livetv.LiveTvChannelPrefs.hiddenGroups.collectAsStateWithLifecycle()
    val shownChannels = remember(ui.channels, hiddenGroups) {
        if (hiddenGroups.isEmpty()) ui.channels
        else ui.channels.filterNot { com.nuvio.app.features.livetv.LiveTvChannelPrefs.groupKey(it.group) in hiddenGroups }
    }
    val guideMatches by androidx.compose.runtime.produceState(
        initialValue = emptyMap<String, List<LiveTvChannel>>(),
        shownChannels,
        ui.epgPrograms,
    ) {
        val channels = shownChannels
        val programs = ui.epgPrograms
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            com.nuvio.app.features.livetv.matchLiveTvGuideCatalog(channels) { !programs[it.id].isNullOrEmpty() }
        }
    }
    // The channels you added by hand show before the categories have been matched; when the categories arrive above
    // them the list would otherwise stay anchored on those and open scrolled down.
    val guideListState = androidx.compose.foundation.lazy.rememberLazyListState()
    androidx.compose.runtime.LaunchedEffect(guideMatches.isNotEmpty(), mineOnly) {
        if (guideMatches.isNotEmpty()) guideListState.scrollToItem(0)
    }
    val myGuideChannels = remember(guideMatches, guideCategoryIds, shownChannels, myGuide) {
        com.nuvio.app.features.livetv.liveTvGuideChannels(
            guideMatches,
            guideCategoryIds,
            if (myGuide.isEmpty()) emptyList() else shownChannels.filter { it.id in myGuide },
        )
    }
    val windowStart = remember(now / HALF_HOUR_MS) { (now / HALF_HOUR_MS) * HALF_HOUR_MS }
    val windowEnd = windowStart + GUIDE_WINDOW_HOURS * 60 * 60_000L
    val timelineWidth = (GUIDE_WINDOW_HOURS * 60 * GUIDE_DP_PER_MINUTE).dp
    val shared = rememberScrollState()
    // My Guide with nothing chosen yet offers to build it, rather than guessing at favourites.
    val needsSetup = mineOnly && myGuide.isEmpty() && guideCategoryIds.isEmpty()

    val rows = remember(shownChannels, ui.epgPrograms, myGuideChannels, mineOnly, query, windowStart) {
        val candidates = if (mineOnly) myGuideChannels else shownChannels
        val built = candidates.mapNotNull { channel ->
            val programs = ui.epgPrograms[channel.id].orEmpty()
                .filter { it.endMillis > windowStart && it.startMillis < windowEnd }
                .sortedBy { it.startMillis }
            // A channel you chose stays in your guide even when its listings haven't arrived.
            if (programs.isEmpty() && !mineOnly) null else GuideRow(channel, programs)
        }
        val q = query.trim().lowercase()
        (if (q.isEmpty()) built else built.filter { row -> row.channel.name.lowercase().contains(q) || row.programs.any { it.title.lowercase().contains(q) } }).take(200)
    }

    val titleCollapse = com.nuvio.app.core.ui.rememberNuvioCollapsingTitleState()
    Column(
        modifier.fillMaxSize().background(tokens.colors.background).statusBarsPadding().padding(top = com.nuvio.app.core.ui.nuvioPlatformExtraTopPadding)
            .nestedScroll(titleCollapse.connection),
    ) {
        NuvioScreenHeader(
            title = stringResource(Res.string.live_tv_title),
            includeStatusBarPadding = false,
            modifier = Modifier.collapsingTitle(titleCollapse).padding(horizontal = NuvioTokens.Space.s16),
            actions = {
                com.nuvio.app.core.ui.NuvioIconActionButton(
                    icon = androidx.compose.material.icons.Icons.Rounded.Refresh,
                    contentDescription = "Refresh guide",
                    onClick = { LiveTvRepository.reloadEpg() },
                )
            },
        )
        val profileRoom = if (com.nuvio.app.navigation.LocalReserveProfileButton.current) 52.dp * titleCollapse.fraction else 0.dp
        LiveSegmentedControl(segment, onSelect, Modifier.padding(start = NuvioTokens.Space.s16, end = NuvioTokens.Space.s16 + profileRoom).padding(top = 6.dp, bottom = NuvioTokens.Space.s8))
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = NuvioTokens.Space.s16, vertical = NuvioTokens.Space.s8),
            horizontalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s8),
        ) {
            PillChip("My Guide", selected = mineOnly, onClick = { mineOnly = true })
            PillChip("All Channels", selected = !mineOnly, onClick = { mineOnly = false })
            if (!needsSetup) PillChip("Categories", selected = false, onClick = { showCategories = true })
            if (!needsSetup) PillChip(if (myGuide.isEmpty()) "+ Add Channels" else "+ Added (${myGuide.size})", selected = false, onClick = { showPicker = true })
        }
        if (showCategories) {
            com.nuvio.app.features.livetv.LiveTvGuideCategoriesDialog(matches = guideMatches, onDismiss = { showCategories = false })
        }
        if (needsSetup) {
            Column(
                Modifier.fillMaxSize().padding(NuvioTokens.Space.s24),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s12, Alignment.CenterVertically),
            ) {
                Text("Build Your Guide", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = tokens.colors.textPrimary)
                Text(
                    "Choose what you actually watch.\nYou can change this anytime.",
                    style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted, textAlign = TextAlign.Center,
                )
                Box(
                    Modifier.clip(RoundedCornerShape(NuvioTokens.Radius.full)).background(tokens.colors.textPrimary).clickable { showPicker = true }
                        .padding(horizontal = NuvioTokens.Space.s24, vertical = NuvioTokens.Space.s12),
                ) { Text("Get Started", color = tokens.colors.background, fontWeight = FontWeight.Bold) }
                Text(
                    "Browse All Channels", style = MaterialTheme.typography.titleSmall, color = tokens.colors.textMuted,
                    modifier = Modifier.clickable { mineOnly = false }.padding(NuvioTokens.Space.s8),
                )
            }
            if (showPicker) GuideChannelPicker(shownChannels, { ui.epgPrograms[it.id].orEmpty().isNotEmpty() }) { showPicker = false }
            return@Column
        }
        if (showPicker) GuideChannelPicker(shownChannels, { ui.epgPrograms[it.id].orEmpty().isNotEmpty() }) { showPicker = false; mineOnly = true }
        GuideSearchField(query, { query = it }, Modifier.padding(horizontal = NuvioTokens.Space.s16))
        Spacer(Modifier.height(NuvioTokens.Space.s8))
        if (rows.isEmpty()) {
            val message = when {
                ui.isEpgLoading || ui.isLoading -> "Loading the guide…"
                !ui.hasPlaylist -> "Add a playlist in Settings to see its guide."
                ui.epgPrograms.isEmpty() -> "No guide data yet. Add or refresh an EPG source in Live TV settings."
                else -> "Nothing matches in the next $GUIDE_WINDOW_HOURS hours."
            }
            if (ui.isEpgLoading || ui.isLoading) {
                Column(Modifier.padding(NuvioTokens.Space.s16), verticalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s8)) {
                    repeat(6) {
                        Row(horizontalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s8)) {
                            com.nuvio.app.core.ui.SkeletonBlock(modifier = Modifier.width(GUIDE_CHANNEL_WIDTH), height = GUIDE_ROW_HEIGHT - 6.dp)
                            com.nuvio.app.core.ui.SkeletonBlock(modifier = Modifier.weight(1f), height = GUIDE_ROW_HEIGHT - 6.dp)
                        }
                    }
                }
            } else {
                Text(message, style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted, modifier = Modifier.padding(NuvioTokens.Space.s16))
            }
        } else {
            Row(Modifier.fillMaxWidth().height(42.dp)) {
                Box(Modifier.width(GUIDE_CHANNEL_WIDTH).fillMaxHeight(), contentAlignment = Alignment.CenterStart) {
                    Text(
                        "TODAY",
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                        color = tokens.colors.textMuted,
                        modifier = Modifier.padding(start = NuvioTokens.Space.s16, bottom = 14.dp),
                    )
                }
                Box(Modifier.weight(1f).fillMaxHeight().horizontalScroll(shared)) {
                    Box(Modifier.width(timelineWidth).fillMaxHeight()) {
                        Row(Modifier.fillMaxSize()) {
                            repeat(GUIDE_WINDOW_HOURS * 2) { slot ->
                                Text(
                                    clockText(windowStart + slot * HALF_HOUR_MS, use24h),
                                    style = MaterialTheme.typography.labelMedium,
                                    fontWeight = if (slot == 0) FontWeight.SemiBold else FontWeight.Medium,
                                    color = if (slot == 0) tokens.colors.textPrimary else tokens.colors.textMuted,
                                    modifier = Modifier.width((30 * GUIDE_DP_PER_MINUTE).dp).padding(top = 2.dp, start = 6.dp),
                                )
                            }
                        }
                        // "Now" marker riding on the time ruler, above the red line that runs down the rows.
                        val nowX = ((now - windowStart) / 60_000f * GUIDE_DP_PER_MINUTE).dp
                        Text(
                            "NOW",
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Black,
                            color = Color.White,
                            modifier = Modifier.align(Alignment.BottomStart).offset(x = nowX - 16.dp)
                                .clip(RoundedCornerShape(50)).background(com.nuvio.app.features.sports.ui.SportsLiveRed)
                                .padding(horizontal = 6.dp, vertical = 1.dp),
                        )
                    }
                }
            }
            LazyColumn(state = guideListState, contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16))) {
                items(rows, key = { it.channel.id }) { row ->
                    Row(Modifier.fillMaxWidth().height(GUIDE_ROW_HEIGHT)) {
                        GuideChannelCell(
                            row.channel, row.channel.id in myGuide, Modifier.width(GUIDE_CHANNEL_WIDTH).fillMaxHeight(),
                            onLongClick = {
                                val adding = row.channel.id !in myGuide
                                GuideChannelStore.toggle(row.channel.id)
                                NuvioToastController.show(if (adding) "Added to My Guide" else "Removed from My Guide")
                            },
                        ) { onChannelClick(row.channel) }
                        Box(Modifier.weight(1f).fillMaxHeight().horizontalScroll(shared)) {
                            Box(Modifier.width(timelineWidth).fillMaxHeight()) {
                                if (row.programs.isEmpty()) {
                                    Text("No guide data for this channel", style = MaterialTheme.typography.labelMedium, color = tokens.colors.textMuted, modifier = Modifier.padding(start = 12.dp, top = 26.dp))
                                }
                                row.programs.forEach { program ->
                                    GuideProgram(program, windowStart, windowEnd, now, use24h) { onChannelClick(row.channel) }
                                }
                                val nowX = ((now - windowStart) / 60_000f * GUIDE_DP_PER_MINUTE).dp
                                Box(Modifier.offset(x = nowX - 1.dp).width(2.dp).fillMaxHeight().background(com.nuvio.app.features.sports.ui.SportsLiveRed.copy(alpha = 0.9f)))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GuideSearchField(query: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val tokens = MaterialTheme.nuvio
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(50)).background(tokens.colors.textPrimary.copy(alpha = 0.08f))
            .padding(horizontal = NuvioTokens.Space.s16, vertical = NuvioTokens.Space.s12),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s8),
    ) {
        Icon(Icons.Rounded.Search, contentDescription = null, tint = tokens.colors.textMuted, modifier = Modifier.size(18.dp))
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) Text("Search channels or programmes…", style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted)
            BasicTextField(
                value = query,
                onValueChange = onChange,
                singleLine = true,
                textStyle = TextStyle(color = tokens.colors.textPrimary, fontSize = MaterialTheme.typography.bodyMedium.fontSize),
                cursorBrush = SolidColor(tokens.colors.accent),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GuideChannelCell(channel: LiveTvChannel, inGuide: Boolean, modifier: Modifier, onLongClick: () -> Unit, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    Column(
        modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick).padding(start = NuvioTokens.Space.s12, end = 6.dp, top = 5.dp, bottom = 4.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        com.nuvio.app.features.livetv.LiveTvLogoPlate(channel, Modifier.fillMaxWidth().weight(1f), radius = 10.dp, logoPadding = 7.dp) {
            if (inGuide) {
                Icon(
                    Icons.Rounded.Star,
                    contentDescription = "In My Guide",
                    tint = tokens.colors.warning,
                    modifier = Modifier.align(Alignment.TopEnd).padding(3.dp).size(10.dp),
                )
            }
        }
        Text(
            com.nuvio.app.features.livetv.liveTvDisplayName(channel.name),
            style = MaterialTheme.typography.labelSmall,
            color = tokens.colors.textMuted,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun GuideProgram(program: LiveTvEpgProgram, windowStart: Long, windowEnd: Long, now: Long, use24h: Boolean, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    val start = maxOf(program.startMillis, windowStart)
    val end = minOf(program.endMillis, windowEnd)
    val x: Dp = ((start - windowStart) / 60_000f * GUIDE_DP_PER_MINUTE).dp
    val w: Dp = ((end - start) / 60_000f * GUIDE_DP_PER_MINUTE).dp
    val airing = program.isAiringAt(now)
    val ended = program.endMillis <= now
    val shape = RoundedCornerShape(10.dp)
    val (title, flag) = com.nuvio.app.features.livetv.liveTvProgramTitle(program.title)
    val blockWidth = (w - 4.dp).coerceAtLeast(6.dp)
    Box(
        Modifier.offset(x = x).width(blockWidth).fillMaxHeight().padding(vertical = 3.dp)
            .clip(shape)
            .background(if (airing) tokens.colors.textPrimary.copy(alpha = 0.14f) else tokens.colors.textPrimary.copy(alpha = 0.06f))
            .clickable(onClick = onClick),
    ) {
        // How far through the programme we are, as a soft wash behind the text.
        if (airing) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(program.progressAt(now)).background(tokens.colors.textPrimary.copy(alpha = 0.08f)))
        }
        // Programmes too short to read get just their block.
        if (blockWidth >= 44.dp) {
            Column(
                Modifier.fillMaxSize().padding(horizontal = 10.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text(
                    title,
                    style = MaterialTheme.typography.labelLarge,
                    color = if (ended) tokens.colors.textMuted else tokens.colors.textPrimary,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = if (blockWidth < 96.dp) 1 else 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    flag?.let { com.nuvio.app.features.livetv.LiveTvFlag(it, solid = it == "LIVE") }
                    Text(
                        if (airing) com.nuvio.app.features.livetv.liveTvMinutesLeft(program, now) else clockText(program.startMillis, use24h),
                        style = MaterialTheme.typography.labelSmall,
                        color = if (airing) tokens.colors.textSecondary else tokens.colors.textMuted,
                        maxLines = 1,
                    )
                }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------ Sports

@Composable
private fun LiveSportsScreen(segment: LiveSegment, onSelect: (LiveSegment) -> Unit, actions: SportsActions, modifier: Modifier = Modifier) {
    val tokens = MaterialTheme.nuvio
    val repo = SportsRepository
    LaunchedEffect(Unit) { SportsReminders.start(); LiveTvRepository.ensureLoaded() }
    DisposableEffect(Unit) {
        repo.setViewing(true)
        onDispose { repo.setViewing(false) }
    }
    val events by repo.events.collectAsStateWithLifecycle()
    val known by repo.known.collectAsStateWithLifecycle()
    val follows by repo.follows.collectAsStateWithLifecycle()
    val settings by repo.settings.collectAsStateWithLifecycle()
    val matches by repo.matches.collectAsStateWithLifecycle()
    val use24h = use24h()
    val now = rememberLiveTvEpgNowMillis()
    var forYou by rememberSaveable { mutableStateOf(false) }
    var sportName by rememberSaveable { mutableStateOf<String?>(null) }

    val live = remember(events, known) { (events + known).distinctBy { it.id }.filter { it.state == GameState.LIVE } }
    val scoped = remember(live, forYou, follows) { if (forYou) live.filter { isMine(it, follows) } else live }
    val sports = remember(scoped) { scoped.mapNotNull { SportsCatalog.league(it.leagueId)?.sport }.distinct() }
    val shown = remember(scoped, sportName) { if (sportName == null) scoped else scoped.filter { SportsCatalog.league(it.leagueId)?.sport?.name == sportName } }

    LaunchedEffect(shown.take(6).map { it.id }) { shown.take(6).forEach { com.nuvio.app.features.sports.SportsWatch.warm(it) } }
    LazyColumn(
        modifier = modifier.fillMaxSize().background(tokens.colors.background),
        contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
        verticalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s12),
    ) {
        item {
            Column(Modifier.statusBarsPadding()) {
                NuvioScreenHeader(title = stringResource(Res.string.live_tv_title), includeStatusBarPadding = false, modifier = Modifier.padding(horizontal = NuvioTokens.Space.s16))
                LiveSegmentedControl(segment, onSelect, Modifier.padding(horizontal = NuvioTokens.Space.s16).padding(top = 6.dp))
            }
        }
        item {
            Row(Modifier.padding(horizontal = NuvioTokens.Space.s16), horizontalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s8)) {
                PillChip("For You", selected = forYou, onClick = { forYou = true })
                PillChip("All Live", selected = !forYou, onClick = { forYou = false })
            }
        }
        item {
            Text(
                when (scoped.size) { 0 -> "No games live right now"; 1 -> "1 game currently live"; else -> "${scoped.size} games currently live" },
                style = MaterialTheme.typography.titleMedium,
                color = tokens.colors.textMuted,
                modifier = Modifier.padding(horizontal = NuvioTokens.Space.s16),
            )
        }
        if (sports.size > 1) {
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = NuvioTokens.Space.s16), horizontalArrangement = Arrangement.spacedBy(NuvioTokens.Space.s8)) {
                    item { Chip("All", selected = sportName == null, onClick = { sportName = null }) }
                    items(sports, key = { it.name }) { s -> Chip(s.label, selected = sportName == s.name, onClick = { sportName = s.name }) }
                }
            }
        }
        // The same score card as the Sports tab: tap to watch, hold for the Game Centre.
        items(shown, key = { "live-" + it.id }) { ev ->
            ScoreCard(
                ev = ev,
                follows = follows,
                now = now,
                use24h = use24h,
                hideScores = settings.hideScores,
                onClick = { actions.watchOrOpen(ev, matches) },
                onDetails = { actions.onOpenGame(ev) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = NuvioTokens.Space.s16),
            )
        }
    }
}
