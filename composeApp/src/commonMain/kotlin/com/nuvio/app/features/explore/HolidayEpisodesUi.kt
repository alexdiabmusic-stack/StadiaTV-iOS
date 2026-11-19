package com.nuvio.app.features.explore

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.PillChip
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.core.ui.rememberPosterCardStyleUiState
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watchprogress.CurrentDateProvider

/**
 * An episode collection's own page: hero, Random Episode, filters (show, watched) and sort, then the episodes as
 * landscape cards with their stills. Tapping plays that exact episode through the app's normal episode playback
 * (source resolution, downloads, resume); holding opens the series on that episode.
 */
@Composable
internal fun HolidayEpisodesScreen(
    collection: ExploreCollection,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    alwaysShowBack: Boolean = false,
) {
    val tokens = MaterialTheme.nuvio
    val all = remember(collection.id) { HolidayEpisodes.of(collection.episodes.orEmpty()) }
    val watchedState by remember { WatchedRepository.ensureLoaded(); WatchedRepository.uiState }.collectAsState()
    val watchedKeys = watchedState.watchedKeys
    val week = remember { ExploreSelection.monthAndWeek(CurrentDateProvider.todayIsoDate()).second }

    var series by rememberSaveable(collection.id) { mutableStateOf<Int?>(null) }
    var watch by rememberSaveable(collection.id) { mutableStateOf(HolidayEpisodes.WatchFilter.All) }
    var sort by rememberSaveable(collection.id) { mutableStateOf(HolidayEpisodes.Sort.Featured) }
    val shows = remember(all) {
        all.groupBy { it.seriesTmdbId }.entries.sortedByDescending { it.value.size }.map { it.key to it.value.first().seriesName }
    }
    val shown = remember(all, series, watch, sort, watchedKeys) {
        HolidayEpisodes.sorted(HolidayEpisodes.filtered(all, series, watch, watchedKeys), sort, week)
    }
    val hero = remember(all) { HolidayEpisodes.featured(all, week).firstOrNull { it.still != null } }
    fun play(ep: HolidayEpisode) {
        (ExploreEpisodeActions.play ?: ExploreEpisodeActions.openDetails)?.invoke(ep)
    }

    BoxWithConstraints(modifier.fillMaxSize().background(tokens.colors.background)) {
        val columns = if (maxWidth >= 900.dp) 4 else if (maxWidth >= 600.dp) 3 else 2
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item(key = "hero") {
                Box(Modifier.fillMaxWidth().height(340.dp).background(tokens.colors.surface)) {
                    hero?.artwork("w1280")?.let { AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                    Box(
                        Modifier.fillMaxSize().background(
                            Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.45f), 0.3f to Color.Transparent, 0.62f to tokens.colors.background.copy(alpha = 0.6f), 1f to tokens.colors.background),
                        ),
                    )
                    ExploreBackButton(onBack, alwaysShowBack, Modifier.statusBarsPadding().padding(start = 12.dp, top = 8.dp), overArtwork = true)
                    Column(
                        Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(collection.title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.ExtraBold, color = Color.White, textAlign = TextAlign.Center)
                        Text(
                            "${all.size} episodes from ${shows.size} shows · ${collection.description}",
                            style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textPrimary.copy(alpha = 0.85f),
                            textAlign = TextAlign.Center, maxLines = 3, overflow = TextOverflow.Ellipsis,
                        )
                        Row(
                            Modifier.clip(RoundedCornerShape(50)).background(Color.White)
                                .combinedClickable(enabled = shown.isNotEmpty(), onClick = { HolidayEpisodes.random(shown)?.let(::play) })
                                .padding(horizontal = 20.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Rounded.Shuffle, contentDescription = null, tint = Color.Black, modifier = Modifier.size(20.dp))
                            Text("Random Episode", color = Color.Black, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleSmall)
                        }
                    }
                }
            }
            item(key = "shows") {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    item(key = "all") { PillChip("All Shows", series == null, { series = null }) }
                    items(shows, key = { it.first }) { (id, name) -> PillChip(name, series == id, { series = if (series == id) null else id }) }
                }
            }
            item(key = "filters") {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(HolidayEpisodes.WatchFilter.entries, key = { "w" + it.name }) { f -> PillChip(f.label, watch == f, { watch = f }) }
                    item(key = "gap") { Spacer(Modifier.width(8.dp)) }
                    items(HolidayEpisodes.Sort.entries, key = { "s" + it.name }) { s -> PillChip(s.label, sort == s, { sort = s }) }
                }
            }
            if (shown.isEmpty()) {
                item(key = "empty") {
                    Text(
                        if (watch == HolidayEpisodes.WatchFilter.Unwatched) "You've watched every episode here." else "No episodes match these filters.",
                        style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted,
                        modifier = Modifier.fillMaxWidth().padding(24.dp), textAlign = TextAlign.Center,
                    )
                }
            }
            shown.chunked(columns).forEachIndexed { index, row ->
                item(key = "row-$index-${row.first().key}") {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        row.forEach { ep ->
                            EpisodeCard(
                                ep, HolidayEpisodes.isWatched(ep, watchedKeys), Modifier.weight(1f),
                                onClick = { play(ep) },
                                onLongClick = { ExploreEpisodeActions.openDetails?.invoke(ep) },
                            )
                        }
                        repeat(columns - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun EpisodeCard(ep: HolidayEpisode, watched: Boolean, modifier: Modifier, onClick: () -> Unit, onLongClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    val radius = rememberPosterCardStyleUiState().cornerRadiusDp.dp
    Column(modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(radius)).background(tokens.colors.surface)) {
            ep.artwork()?.let { AsyncImage(model = it, contentDescription = ep.title, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
            Box(
                Modifier.align(Alignment.BottomEnd).padding(6.dp).size(24.dp).clip(CircleShape)
                    .background(if (watched) MaterialTheme.colorScheme.primary else Color.Black.copy(alpha = 0.5f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    if (watched) Icons.Rounded.Check else Icons.Rounded.PlayArrow,
                    contentDescription = if (watched) "Watched" else "Play",
                    tint = Color.White,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        Text(ep.seriesName, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(
            "${ep.code} · ${ep.title}",
            style = MaterialTheme.typography.labelSmall, color = tokens.colors.textMuted,
            minLines = 2, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
    }
}
