package com.nuvio.app.features.livetv

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.CalendarViewDay
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material.icons.rounded.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.NuvioShelfSection
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioScreenSideBleed

// ------------------------------------------------------------------------------------------ Names and titles

private val REGION_PREFIX = Regex("""^\s*[A-Za-z]{2,4}\s*[★❖|:•]+\s*""")
private val QUALITY_SUFFIX = Regex("""(\s+(HD|FHD|UHD|SD|4K|HEVC|RAW|ᴴᴰ|ᶠᴴᴰ|ᵁᴴᴰ|ᴿᴬᵂ|◉))+\s*$""", RegexOption.IGNORE_CASE)

/** A channel name without the playlist's country tag and quality words: "CA ★ CTV Toronto HD" reads "CTV Toronto". */
internal fun liveTvDisplayName(name: String): String {
    val cleaned = name.replace(REGION_PREFIX, "").replace(QUALITY_SUFFIX, "").trim()
    return cleaned.ifEmpty { name.trim() }
}

/** Guide titles carry their flags as superscript letters ("Morning Show ᴺᵉʷ"); this splits them into a badge. */
internal fun liveTvProgramTitle(title: String): Pair<String, String?> {
    val trimmed = title.trimEnd()
    return when {
        trimmed.endsWith("ᴺᵉʷ") -> trimmed.removeSuffix("ᴺᵉʷ").trimEnd() to "NEW"
        trimmed.endsWith("ᴸᶦᵛᵉ") -> trimmed.removeSuffix("ᴸᶦᵛᵉ").trimEnd() to "LIVE"
        else -> trimmed to null
    }
}

internal fun liveTvMinutesLeft(program: LiveTvEpgProgram, nowMillis: Long): String {
    val minutes = ((program.endMillis - nowMillis) / 60_000L).coerceAtLeast(0L)
    return when {
        minutes < 1 -> "Ending now"
        minutes < 60 -> "${minutes}m left"
        else -> "${minutes / 60}h ${(minutes % 60).toString().padStart(2, '0')}m left"
    }
}

internal val LiveTvRed = Color(0xFFE53935)

@Composable
internal fun LiveTvFlag(text: String, modifier: Modifier = Modifier, solid: Boolean = text == "LIVE") {
    Text(
        text,
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.Black,
        color = Color.White,
        maxLines = 1,
        modifier = modifier
            .clip(RoundedCornerShape(4.dp))
            .background(if (solid) LiveTvRed else Color.White.copy(alpha = 0.22f))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    )
}

// ------------------------------------------------------------------------------------------ Home

internal class LiveTvHomeShelf(val key: String, val title: String, val channels: List<LiveTvChannel>, val onViewAll: (() -> Unit)?)

/**
 * The front page of Live TV: the channel you were watching, then what's on now across your favourites, recents
 * and guide line-up, each as a row of wide channel tiles.
 */
internal fun androidx.compose.foundation.lazy.LazyListScope.liveTvHome(
    hero: LiveTvChannel?,
    heroIsResume: Boolean,
    shelves: List<LiveTvHomeShelf>,
    epgPrograms: Map<String, List<LiveTvEpgProgram>>,
    nowMillis: Long,
    favoriteChannelIds: Set<String>,
    totalChannels: Int,
    onPlay: (LiveTvChannel) -> Unit,
    onGuide: (LiveTvChannel) -> Unit,
    onBrowseAll: () -> Unit,
) {
    if (hero != null) {
        item(key = "live-home-hero") {
            LiveTvHero(
                channel = hero,
                isResume = heroIsResume,
                programs = epgPrograms[hero.id].orEmpty(),
                nowMillis = nowMillis,
                isFavorite = hero.id in favoriteChannelIds,
                onWatch = { onPlay(hero) },
                onGuide = { onGuide(hero) },
                modifier = Modifier.padding(top = 4.dp, bottom = 10.dp),
            )
        }
    }
    shelves.forEach { shelf ->
        item(key = "live-home-shelf:${shelf.key}") {
            NuvioShelfSection(
                title = shelf.title,
                entries = shelf.channels,
                modifier = Modifier.nuvioScreenSideBleed().padding(vertical = 10.dp),
                headerHorizontalPadding = 16.dp,
                rowContentPadding = PaddingValues(horizontal = 16.dp),
                itemSpacing = 12.dp,
                onViewAllClick = shelf.onViewAll,
                key = { "${shelf.key}:${it.id}" },
            ) { channel ->
                LiveTvChannelTile(
                    channel = channel,
                    programs = epgPrograms[channel.id].orEmpty(),
                    nowMillis = nowMillis,
                    isFavorite = channel.id in favoriteChannelIds,
                    onClick = { onPlay(channel) },
                    onLongClick = { onGuide(channel) },
                )
            }
        }
    }
    item(key = "live-home-browse") {
        LiveTvBrowseAllRow(totalChannels, onBrowseAll, Modifier.padding(top = 14.dp, bottom = 8.dp))
    }
}

// ------------------------------------------------------------------------------------------ Hero

@Composable
private fun LiveTvHero(
    channel: LiveTvChannel,
    isResume: Boolean,
    programs: List<LiveTvEpgProgram>,
    nowMillis: Long,
    isFavorite: Boolean,
    onWatch: () -> Unit,
    onGuide: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = MaterialTheme.nuvio
    val current = programs.currentProgram(nowMillis)
    val next = programs.nextProgram(nowMillis)
    val shape = RoundedCornerShape(22.dp)
    // Short screens (iPhone Duo cover screen, small iPhones): the card is about 40% of the screen at full size, so it
    // tightens up to leave room for the rows underneath.
    val compact = with(androidx.compose.ui.platform.LocalDensity.current) {
        androidx.compose.ui.platform.LocalWindowInfo.current.containerSize.height.toDp() < 720.dp
    }
    val pad = if (compact) 14.dp else 20.dp
    val gap = if (compact) 10.dp else 18.dp
    Box(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(tokens.colors.surfaceCard)
            .border(1.dp, Color.White.copy(alpha = 0.08f), shape)
            .clickable(onClick = onWatch),
    ) {
        // The channel's own logo, blown up and blurred, gives every hero its own colour wash.
        if (!channel.logoUrl.isNullOrBlank()) {
            AsyncImage(
                model = channel.logoUrl,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.matchParentSize().graphicsLayer { scaleX = 1.6f; scaleY = 1.6f; alpha = 0.55f }.blur(56.dp),
            )
        }
        Box(
            Modifier.matchParentSize().background(
                Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.15f), 0.55f to Color.Black.copy(alpha = 0.55f), 1f to Color.Black.copy(alpha = 0.85f)),
            ),
        )
        Column(Modifier.fillMaxWidth().padding(pad)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    if (isResume) "CONTINUE WATCHING" else "ON NOW",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold,
                    color = Color.White.copy(alpha = 0.7f),
                    letterSpacing = 1.5.sp,
                    modifier = Modifier.weight(1f),
                )
                LiveTvLivePulse()
            }
            Spacer(Modifier.height(gap))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                LiveTvLogoPlate(
                    channel,
                    if (compact) Modifier.size(width = 84.dp, height = 52.dp) else Modifier.size(width = 104.dp, height = 64.dp),
                    radius = 14.dp, glass = true, logoFraction = 0.72f,
                )
                if (current != null) Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            liveTvDisplayName(channel.name),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = Color.White,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        if (isFavorite) Icon(Icons.Rounded.Star, contentDescription = null, tint = tokens.colors.warning, modifier = Modifier.size(16.dp))
                    }
                    channel.group?.takeIf { it.isNotBlank() }?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            Spacer(Modifier.height(gap))
            if (current != null) {
                val (title, flag) = liveTvProgramTitle(current.title)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        title,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    flag?.let { LiveTvFlag(it) }
                }
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        "${formatLiveTvClock(current.startMillis)} – ${formatLiveTvClock(current.endMillis)}",
                        style = MaterialTheme.typography.labelLarge,
                        color = Color.White.copy(alpha = 0.75f),
                        maxLines = 1,
                    )
                    LiveTvEpgProgressBar(
                        progress = current.progressAt(nowMillis),
                        trackColor = Color.White.copy(alpha = 0.22f),
                        progressColor = Color.White,
                        modifier = Modifier.weight(1f),
                    )
                    Text(liveTvMinutesLeft(current, nowMillis), style = MaterialTheme.typography.labelLarge, color = Color.White.copy(alpha = 0.75f), maxLines = 1)
                }
                if (next != null) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Up next  ${formatLiveTvClock(next.startMillis)} · ${liveTvProgramTitle(next.title).first}",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.6f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            } else {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        liveTvDisplayName(channel.name),
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    if (isFavorite) Icon(Icons.Rounded.Star, contentDescription = null, tint = tokens.colors.warning, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    listOfNotNull(channel.group?.takeIf { it.isNotBlank() }, "Live now").joinToString(" · "),
                    style = MaterialTheme.typography.labelLarge,
                    color = Color.White.copy(alpha = 0.7f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.height(if (compact) 12.dp else 20.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Row(
                    Modifier.height(44.dp).clip(RoundedCornerShape(50)).background(Color.White).clickable(onClick = onWatch).padding(horizontal = 24.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Rounded.PlayArrow, contentDescription = null, tint = Color.Black, modifier = Modifier.size(24.dp))
                    Text(if (isResume) "Resume" else "Watch Live", color = Color.Black, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
                }
                if (programs.isNotEmpty()) {
                    Row(
                        Modifier.height(44.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.22f)).clickable(onClick = onGuide).padding(horizontal = 20.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Icon(Icons.Rounded.CalendarViewDay, contentDescription = null, tint = Color.White, modifier = Modifier.size(20.dp))
                        Text("Schedule", color = Color.White, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.titleMedium)
                    }
                }
            }
        }
    }
}

@Composable
private fun LiveTvLivePulse() {
    Row(
        Modifier.clip(RoundedCornerShape(50)).background(Color.Black.copy(alpha = 0.35f)).padding(horizontal = 9.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(LiveTvRed))
        Text("LIVE", style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.Black, color = Color.White)
    }
}

// ------------------------------------------------------------------------------------------ Tiles

@Composable
internal fun LiveTvLogoPlate(
    channel: LiveTvChannel,
    modifier: Modifier,
    radius: Dp = 12.dp,
    glass: Boolean = false,
    logoPadding: Dp = 10.dp,
    /** When set, the logo fits a box this fraction of the plate's width and height instead of using [logoPadding]. */
    logoFraction: Float? = null,
    content: @Composable BoxScope.() -> Unit = {},
) {
    val tokens = MaterialTheme.nuvio
    val shape = RoundedCornerShape(radius)
    Box(
        modifier
            .clip(shape)
            .background(
                if (glass) Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0.08f)))
                else Brush.verticalGradient(listOf(tokens.colors.surfaceElevated, tokens.colors.surfaceCard)),
            )
            .border(1.dp, Color.White.copy(alpha = if (glass) 0.14f else 0.06f), shape),
        contentAlignment = Alignment.Center,
    ) {
        if (!channel.logoUrl.isNullOrBlank()) {
            AsyncImage(
                model = channel.logoUrl,
                contentDescription = channel.name,
                contentScale = ContentScale.Fit,
                modifier = if (logoFraction != null) Modifier.fillMaxWidth(logoFraction).fillMaxHeight(logoFraction * 0.9f)
                else Modifier.fillMaxSize().padding(logoPadding),
            )
        } else {
            Text(
                liveTvDisplayName(channel.name),
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
                color = tokens.colors.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
        }
        content()
    }
}

private val TILE_WIDTH = 176.dp

/** A wide channel card: the logo on a lit plate with what's airing and how far through it is. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LiveTvChannelTile(
    channel: LiveTvChannel,
    programs: List<LiveTvEpgProgram>,
    nowMillis: Long,
    isFavorite: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier.width(TILE_WIDTH),
) {
    val tokens = MaterialTheme.nuvio
    val current = programs.currentProgram(nowMillis)
    Column(modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        LiveTvLogoPlate(channel, Modifier.fillMaxWidth().aspectRatio(16f / 9f), radius = 14.dp, logoFraction = 0.56f) {
            if (isFavorite) {
                Icon(
                    Icons.Rounded.Star,
                    contentDescription = null,
                    tint = tokens.colors.warning,
                    modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(16.dp),
                )
            }
            if (current != null) {
                Box(
                    Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color.White.copy(alpha = 0.12f)),
                ) {
                    Box(Modifier.fillMaxHeight().fillMaxWidth(current.progressAt(nowMillis)).background(LiveTvRed))
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            if (current != null) {
                val (title, flag) = liveTvProgramTitle(current.title)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        title,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = tokens.colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    flag?.let { LiveTvFlag(it) }
                }
                Text(
                    "${liveTvDisplayName(channel.name)} · ${liveTvMinutesLeft(current, nowMillis)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = tokens.colors.textMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            } else {
                Text(
                    liveTvDisplayName(channel.name),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = tokens.colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    channel.group?.takeIf { it.isNotBlank() } ?: "Live",
                    style = MaterialTheme.typography.bodySmall,
                    color = tokens.colors.textMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun LiveTvBrowseAllRow(total: Int, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val tokens = MaterialTheme.nuvio
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(tokens.colors.textPrimary.copy(alpha = 0.07f))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(Modifier.size(40.dp).clip(CircleShape).background(tokens.colors.textPrimary.copy(alpha = 0.1f)), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.Tv, contentDescription = null, tint = tokens.colors.textPrimary, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f)) {
            Text("Browse All Channels", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary)
            Text("${formatCount(total)} channels in your playlists", style = MaterialTheme.typography.bodySmall, color = tokens.colors.textMuted)
        }
        Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = tokens.colors.textMuted)
    }
}

private fun formatCount(n: Int): String {
    val s = n.toString()
    val out = StringBuilder()
    s.forEachIndexed { i, c ->
        if (i > 0 && (s.length - i) % 3 == 0) out.append(',')
        out.append(c)
    }
    return out.toString()
}

/** 12- or 24-hour clock the way the rest of the app shows times. */
@Composable
internal fun formatLiveTvClock(millis: Long): String =
    com.nuvio.app.features.sports.clockText(millis, com.nuvio.app.features.sports.ui.use24h())

// ------------------------------------------------------------------------------------------ Rows

/** A row in the channel list: the logo on a wide plate, the name, and what's on with its progress. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LiveTvChannelRow(
    channel: LiveTvChannel,
    categoryName: String,
    isFavorite: Boolean,
    programs: List<LiveTvEpgProgram>,
    nowMillis: Long,
    onPlay: () -> Unit,
    onFavorite: () -> Unit,
    onGuide: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = MaterialTheme.nuvio
    val current = programs.currentProgram(nowMillis)
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .combinedClickable(onClick = onPlay, onLongClick = onGuide)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        LiveTvLogoPlate(channel, Modifier.size(width = 100.dp, height = 58.dp), radius = 12.dp, logoFraction = 0.7f)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                liveTvDisplayName(channel.name),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = tokens.colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (current != null) {
                val (title, flag) = liveTvProgramTitle(current.title)
                Row(
                    Modifier.clickable(onClick = onGuide),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        title,
                        style = MaterialTheme.typography.bodySmall,
                        color = tokens.colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    flag?.let { LiveTvFlag(it) }
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    LiveTvEpgProgressBar(
                        progress = current.progressAt(nowMillis),
                        trackColor = tokens.colors.textPrimary.copy(alpha = 0.12f),
                        progressColor = LiveTvRed,
                        modifier = Modifier.weight(1f),
                    )
                    Text(liveTvMinutesLeft(current, nowMillis), style = MaterialTheme.typography.labelSmall, color = tokens.colors.textMuted, maxLines = 1)
                }
            } else {
                Text(categoryName, style = MaterialTheme.typography.bodySmall, color = tokens.colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Box(
            Modifier.size(36.dp).clip(CircleShape).clickable(onClick = onFavorite),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (isFavorite) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                contentDescription = if (isFavorite) "Remove from favourites" else "Add to favourites",
                tint = if (isFavorite) tokens.colors.warning else tokens.colors.textMuted.copy(alpha = 0.7f),
                modifier = Modifier.size(20.dp),
            )
        }
    }
}
