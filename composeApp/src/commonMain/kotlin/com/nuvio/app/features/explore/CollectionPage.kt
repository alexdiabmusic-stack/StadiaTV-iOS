package com.nuvio.app.features.explore

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.NuvioBottomSheetActionRow
import com.nuvio.app.core.ui.NuvioBottomSheetDivider
import com.nuvio.app.core.ui.NuvioModalBottomSheet
import com.nuvio.app.core.ui.NuvioPosterWatchedOverlay
import com.nuvio.app.core.ui.NuvioShelfSection
import com.nuvio.app.core.ui.dismissNuvioBottomSheet
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.core.ui.posterCardClickable
import com.nuvio.app.core.ui.rememberPosterCardStyleUiState
import com.nuvio.app.features.explore.ExploreResolver.allItems
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.components.PosterGridSkeletonRow
import com.nuvio.app.features.library.LibraryRepository
import com.nuvio.app.features.recommendations.RecommendationEngine
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watching.application.WatchingState
import kotlinx.coroutines.launch

private val ControlsHeight = 52.dp

/**
 * A collection's page. One scroll holds everything: a cinematic header that scrolls away (leaving a compact title in the top bar),
 * the filter and sort controls (pinned under the top bar once they would scroll off), and the titles in a multi-row grid or in
 * chapters. What is on the page, and in what order, is [CollectionPlan]'s; this draws it and keeps the member's place
 * ([CollectionBrowseState]) so coming back from a title lands where they left.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ExploreCollectionScreen(
    collectionId: String,
    onCollectionClick: (ExploreCollection) -> Unit,
    onPosterClick: ((MetaPreview) -> Unit)?,
    onPosterLongClick: ((MetaPreview) -> Unit)?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    /** Inside a tab (Search) there is no native back button, so the page always draws its own. */
    alwaysShowBack: Boolean = false,
) {
    val collection = remember(collectionId) { ExploreCatalog[collectionId] } ?: return
    if (collection.episodes != null) {
        HolidayEpisodesScreen(collection, onBack, modifier, alwaysShowBack)
        return
    }
    val tokens = MaterialTheme.nuvio
    val scope = rememberCoroutineScope()
    val haptic = LocalHapticFeedback.current
    val state = remember(collectionId) { CollectionBrowseStore.of(collectionId) }

    val watchedState by remember { WatchedRepository.ensureLoaded(); WatchedRepository.uiState }.collectAsState()
    val fullyWatched by WatchedRepository.fullyWatchedSeriesKeys.collectAsState()
    val personal by RecommendationEngine.state.collectAsState()
    val library by LibraryRepository.uiState.collectAsState()
    val watchedKeys = remember(watchedState.watchedKeys, personal.watchedTmdbKeys) { watchedState.watchedKeys + personal.watchedTmdbKeys }
    val completedKeys = remember(fullyWatched, personal.completedSeriesTmdbKeys) { fullyWatched + personal.completedSeriesTmdbKeys }

    // The titles: shown at once from what the page last had, then checked against TMDB. Content already on screen is only
    // ever replaced by a complete answer, never by a half-loaded one, so the page does not shrink under the member's finger.
    var loaded by remember(collectionId) { mutableStateOf(state.resolved != null) }
    var attempt by remember(collectionId) { mutableIntStateOf(0) }
    var refreshing by remember { mutableStateOf(false) }
    LaunchedEffect(collectionId, attempt) {
        val had = state.resolved?.let { it.sections.isNotEmpty() || it.upcoming.isNotEmpty() } == true
        val result = ExploreResolver.resolve(collection) { if (!had) state.resolved = it }
        if (result.sections.isNotEmpty() || result.upcoming.isNotEmpty() || !had) state.resolved = result
        loaded = true
    }
    val art by produceState<CollectionArt?>(null, collectionId) { value = ExploreResolver.art(collection, size = "w1280") }
    val children = remember(collectionId) { ExploreCatalog.children(collection) }
    val awards = remember(collectionId) { ExploreAwards.entries(collectionId) }
    val sorts = remember(collectionId) { CollectionBrowse.sortsFor(collection) }

    val resolved = state.resolved
    val all = remember(resolved) { resolved?.allItems().orEmpty() }
    val hasBoth = remember(all) { all.any { it.type == "series" } && all.any { it.type == "movie" } }

    // A list carries no runtime; it is looked up (a few titles at a time) only when a runtime filter or sort asks for it.
    val needsRuntime = state.filters.needsRuntime || state.sort.needsRuntime
    var loadingRuntimes by remember { mutableStateOf(false) }
    LaunchedEffect(needsRuntime, resolved) {
        if (!needsRuntime || resolved == null) return@LaunchedEffect
        loadingRuntimes = true
        ExploreResolver.loadRuntimes(all + resolved.upcoming) { state.runtimes = it }
        loadingRuntimes = false
    }

    val ctx = remember(watchedKeys, completedKeys, library, state.runtimes, resolved, awards) {
        BrowseContext(
            isWatched = { WatchingState.isPosterWatched(watchedKeys, it, completedKeys) },
            isSaved = { LibraryRepository.isSaved(it.id, it.type) },
            runtimes = state.runtimes,
            ratings = resolved?.ratings.orEmpty(),
            story = collection.storyOrder,
            awards = awards,
        )
    }

    var showSort by remember { mutableStateOf(false) }
    var showFilters by remember { mutableStateOf(false) }

    BoxWithConstraints(modifier.fillMaxSize().background(tokens.colors.background)) {
        val density = LocalDensity.current
        val contentWidth = minOf(maxWidth.value, CollectionBrowse.MAX_CONTENT_WIDTH_DP)
        val columns = CollectionBrowse.columns(contentWidth - 32f, density.fontScale)
        val childrenPerRow = if (contentWidth >= 700f) 3 else 2
        val shelfCardWidth = (maxWidth * 0.52f).coerceIn(190.dp, 300.dp)
        val top = rememberPageTop(alwaysShowBack)
        val statusTop = top.inset
        val barHeight = top.barHeight
        val heroHeight = CollectionBrowse.heroHeightDp(maxWidth.value, maxHeight.value).dp + statusTop

        val rows = remember(collection, children, resolved, loaded, state.filters, state.sort, ctx, columns, childrenPerRow) {
            CollectionPlan.build(collection, children, resolved, loaded, state.filters, state.sort, ctx, columns, childrenPerRow)
        }
        val listState = state.listState
        val heroPx = with(density) { heroHeight.toPx() }
        val barPx = with(density) { barHeight.toPx() }
        // 0 while the header fills the top, 1 once it has scrolled away: the top bar fills in and shows the title.
        val collapse by remember(heroPx, barPx) {
            derivedStateOf {
                if (listState.firstVisibleItemIndex > 0) 1f
                else ((listState.firstVisibleItemScrollOffset - (heroPx - barPx * 2f)) / barPx).coerceIn(0f, 1f)
            }
        }
        // The controls pin under the top bar when the copy in the list reaches it or has gone past it.
        val pinned by remember(barPx) {
            derivedStateOf {
                val visible = listState.layoutInfo.visibleItemsInfo
                val controls = visible.firstOrNull { it.key == "controls" }
                if (controls != null) controls.offset < barPx
                else visible.any { (it.key as? String)?.startsWith("body:") == true }
            }
        }

        fun tick() = haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)

        // A new sort or filter starts at the top of the grid, not at the old position in a different list. Only when the
        // member has already scrolled past the controls (so a change made from the header does not scroll it away), and not on
        // the first composition (so coming back from a title keeps the place).
        var firstChange by remember(collectionId) { mutableStateOf(true) }
        LaunchedEffect(state.sort, state.filters) {
            if (firstChange) { firstChange = false; return@LaunchedEffect }
            val controlsIndex = rows.indexOfFirst { it is PlanRow.Controls }
            if (controlsIndex >= 0 && listState.firstVisibleItemIndex >= controlsIndex) {
                listState.scrollToItem(controlsIndex, scrollOffset = -barPx.toInt())
            }
        }

        val controls: @Composable () -> Unit = {
            BrowseControls(
                state = state,
                hasBoth = hasBoth,
                loadingRuntimes = loadingRuntimes,
                onSort = { showSort = true },
                onFilters = { showFilters = true },
                onChanged = ::tick,
            )
        }

        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = {
                scope.launch {
                    refreshing = true
                    val fresh = ExploreResolver.refresh(collection)
                    if (fresh.sections.isNotEmpty() || fresh.upcoming.isNotEmpty() || state.resolved == null) state.resolved = fresh
                    refreshing = false
                }
            },
            modifier = Modifier.fillMaxSize(),
        ) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(24.dp)),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                items(rows, key = { it.key }) { row ->
                    if (row is PlanRow.Hero) {
                        CollectionHeroHeader(collection, art, all, heroHeight, top.heroTextTop)
                    } else {
                        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                            Column(Modifier.widthIn(max = CollectionBrowse.MAX_CONTENT_WIDTH_DP.dp).fillMaxWidth().sideSafe()) {
                                when (row) {
                                    PlanRow.Hero -> Unit
                                    PlanRow.Progress -> {
                                        val seen = all.count { WatchingState.isPosterWatched(watchedKeys, it, completedKeys) }
                                        FranchiseProgress(seen, all.size, Modifier.padding(horizontal = 16.dp))
                                    }
                                    is PlanRow.Chapters -> LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        items(row.chapters, key = { it.title }) { chapter ->
                                            BrowseChip(chapter.title, selected = state.chapter == chapter.title) {
                                                state.chapter = chapter.title
                                                tick()
                                                scope.launch {
                                                    CollectionPlan.indexOfChapter(rows, chapter.title)?.let {
                                                        // Land the heading just under the top bar and the pinned controls.
                                                        listState.animateScrollToItem(it, scrollOffset = -with(density) { (barHeight + ControlsHeight).roundToPx() })
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    is PlanRow.ChildrenTitle -> SectionTitle(row.title)
                                    is PlanRow.ChildrenRow -> Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                        row.items.forEach { child ->
                                            BoxWithConstraints(Modifier.weight(1f)) { ExploreCollectionCard(child, maxWidth, onClick = { onCollectionClick(child) }) }
                                        }
                                        repeat(row.perRow - row.items.size) { Spacer(Modifier.weight(1f)) }
                                    }
                                    is PlanRow.ChildrenShelf -> NuvioShelfSection(
                                        title = "Explore Further",
                                        entries = row.items,
                                        headerHorizontalPadding = 16.dp,
                                        rowContentPadding = PaddingValues(horizontal = 16.dp),
                                        itemSpacing = 12.dp,
                                        key = { it.id },
                                    ) { child -> ExploreCollectionCard(child, shelfCardWidth, onClick = { onCollectionClick(child) }) }
                                    PlanRow.Controls -> controls()
                                    is PlanRow.Heading -> HeadingRow(row.text, row.count)
                                    is PlanRow.Posters -> CollectionPosterRow(
                                        items = row.items, columns = columns, awards = awards,
                                        isWatched = { WatchingState.isPosterWatched(watchedKeys, it, completedKeys) },
                                        onClick = onPosterClick, onLongClick = onPosterLongClick,
                                    )
                                    is PlanRow.Sparse -> Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                        row.items.forEach { item ->
                                            SparseTitleCard(
                                                item = item, awards = awards, watched = WatchingState.isPosterWatched(watchedKeys, item, completedKeys),
                                                onClick = onPosterClick?.let { { it(item) } }, onLongClick = onPosterLongClick?.let { { it(item) } },
                                            )
                                        }
                                    }
                                    PlanRow.Skeleton -> Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                                        repeat(2) { PosterGridSkeletonRow(columns = columns) }
                                    }
                                    PlanRow.LoadError -> MessageBlock(
                                        title = "Nothing to show right now",
                                        body = "The titles couldn't be loaded. Check the connection and try again.",
                                        action = "Try Again",
                                    ) { attempt++ }
                                    is PlanRow.NoMatches -> MessageBlock(
                                        title = "No ${row.noun} match these filters.",
                                        body = null,
                                        action = "Reset Filters",
                                    ) { state.filters = BrowseFilters(); tick() }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (pinned) {
            Box(
                Modifier.align(Alignment.TopCenter).fillMaxWidth().padding(top = barHeight).background(tokens.colors.background),
                contentAlignment = Alignment.TopCenter,
            ) {
                Box(Modifier.widthIn(max = CollectionBrowse.MAX_CONTENT_WIDTH_DP.dp).fillMaxWidth().sideSafe()) { controls() }
            }
        }

        // The top bar: the Back button over the artwork, filling in with the collection's title once the header has scrolled away.
        Box(Modifier.align(Alignment.TopCenter).fillMaxWidth().height(barHeight).background(tokens.colors.background.copy(alpha = collapse)))
        Row(
            Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .sideSafe()
                .padding(top = top.stripTop)
                .height(top.stripHeight)
                .padding(start = if (top.native) top.titleStart else 12.dp, end = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ExploreBackButton(onBack, alwaysShowBack, overArtwork = true)
            Text(
                collection.title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = tokens.colors.textPrimary.copy(alpha = collapse),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        if (showSort) SortSheet(
            sorts = sorts, current = state.sort, loadingRuntimes = loadingRuntimes,
            onPick = { state.sort = it; tick() }, onDismiss = { showSort = false },
        )
        if (showFilters) FilterSheet(
            collection = collection, all = all, ratingsKnown = resolved?.ratings?.isNotEmpty() == true, awards = awards,
            current = state.filters, onApply = { state.filters = it; tick() }, onDismiss = { showFilters = false },
        )
    }
}

// ---------------------------------------------------------------------------------------------------- Header

private fun kindLabel(kind: CollectionKind) = when (kind) {
    CollectionKind.Editorial -> "Curated Collection"
    CollectionKind.Franchise -> "Franchise"
    CollectionKind.Metadata -> "Collection"
    CollectionKind.Personalized -> "Made for You"
}

/** "120 Films · Curated Collection": the count is of the titles the page actually found. */
private fun metaLine(collection: ExploreCollection, all: List<MetaPreview>): String {
    val noun = when (CollectionPlan.noun(all)) { "movies" -> "Films"; "series" -> "Series"; else -> "Titles" }
    return listOfNotNull(if (all.isNotEmpty()) "${all.size} $noun" else null, kindLabel(collection.kind), collection.subtitle).joinToString(" · ")
}

@Composable
private fun CollectionHeroHeader(collection: ExploreCollection, art: CollectionArt?, all: List<MetaPreview>, height: Dp, textTop: Dp) {
    val tokens = MaterialTheme.nuvio
    Box(Modifier.fillMaxWidth().height(height).background(tokens.colors.surface)) {
        art?.backdrop?.let { AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        // Dark where the text sits and at the very top (behind the status bar), clear in between so the artwork shows.
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.0f to Color.Black.copy(alpha = 0.5f),
                    0.28f to Color.Transparent,
                    0.55f to tokens.colors.background.copy(alpha = 0.55f),
                    0.82f to tokens.colors.background.copy(alpha = 0.92f),
                    1.0f to tokens.colors.background,
                ),
            ),
        )
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth().sideSafe().padding(start = 20.dp, end = 20.dp, bottom = 14.dp, top = textTop),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                collection.category.title.uppercase(),
                style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp),
                color = tokens.colors.textPrimary.copy(alpha = 0.7f),
                maxLines = 1,
            )
            if (art?.logo != null) {
                AsyncImage(model = art.logo, contentDescription = collection.title, contentScale = ContentScale.Fit, alignment = Alignment.CenterStart, modifier = Modifier.fillMaxWidth(0.6f).heightIn(max = 84.dp))
            } else {
                Text(
                    collection.title,
                    style = TextStyle(fontSize = 30.sp, lineHeight = 33.sp, fontWeight = FontWeight.ExtraBold),
                    color = tokens.colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.semantics { contentDescription = collection.title },
                )
            }
            Text(
                collection.description,
                style = MaterialTheme.typography.bodyMedium,
                color = tokens.colors.textPrimary.copy(alpha = 0.85f),
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            Text(metaLine(collection, all), style = MaterialTheme.typography.labelMedium, color = tokens.colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(title, style = MaterialTheme.typography.titleLarge, color = MaterialTheme.nuvio.colors.textPrimary, modifier = Modifier.padding(horizontal = 16.dp))
}

@Composable
private fun HeadingRow(text: String, count: Int?) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(text, style = MaterialTheme.typography.titleLarge, color = MaterialTheme.nuvio.colors.textPrimary, modifier = Modifier.semantics { contentDescription = text })
        if (count != null) Text("$count", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.nuvio.colors.textMuted, modifier = Modifier.padding(bottom = 2.dp))
    }
}

@Composable
private fun FranchiseProgress(seen: Int, total: Int, modifier: Modifier = Modifier) {
    val tokens = MaterialTheme.nuvio
    val fraction = if (total == 0) 0f else seen.toFloat() / total
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            if (seen == 0) "$total titles" else if (seen >= total) "You've watched all $total" else "You've watched $seen of $total",
            style = MaterialTheme.typography.labelLarge,
            color = tokens.colors.textMuted,
        )
        Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.12f))) {
            Box(Modifier.fillMaxHeight().fillMaxWidth(fraction).clip(RoundedCornerShape(50)).background(MaterialTheme.colorScheme.primary))
        }
    }
}

@Composable
private fun MessageBlock(title: String, body: String?, action: String, onAction: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, color = tokens.colors.textPrimary, textAlign = TextAlign.Center)
        if (body != null) Text(body, style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted, textAlign = TextAlign.Center)
        BrowseChip(action, selected = false, onClick = onAction)
    }
}

// ---------------------------------------------------------------------------------------------------- Controls

/** A chip with a comfortable 44 dp touch target around a slimmer pill. */
@Composable
internal fun BrowseChip(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    Box(modifier.heightIn(min = 44.dp).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            color = if (selected) tokens.colors.background else tokens.colors.textPrimary,
            maxLines = 1,
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(if (selected) tokens.colors.textPrimary else tokens.colors.textPrimary.copy(alpha = 0.12f))
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .semantics { contentDescription = if (selected) "$label, selected" else label },
        )
    }
}

/** Sort and Filters first (the sort in use is always visible), then the quick chips. One horizontal strip, so it never crowds. */
@Composable
private fun BrowseControls(
    state: CollectionBrowseState,
    hasBoth: Boolean,
    loadingRuntimes: Boolean,
    onSort: () -> Unit,
    onFilters: () -> Unit,
    onChanged: () -> Unit,
) {
    val tokens = MaterialTheme.nuvio
    val f = state.filters
    Column(Modifier.fillMaxWidth()) {
        LazyRow(
            Modifier.height(ControlsHeight),
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            item(key = "sort") { BrowseChip("Sort: ${state.sort.label}", selected = state.sort != BrowseSort.Curated, onClick = onSort) }
            item(key = "filters") {
                BrowseChip(if (f.advancedCount > 0) "Filters · ${f.advancedCount}" else "Filters", selected = f.advancedCount > 0, onClick = onFilters)
            }
            items(WatchFilter.entries, key = { "w-" + it.name }) { w ->
                BrowseChip(w.label, selected = f.watch == w) { state.filters = f.copy(watch = w); onChanged() }
            }
            if (hasBoth) items(listOf(BrowseMedia.Movies, BrowseMedia.Series), key = { "m-" + it.name }) { m ->
                // Tapping the chosen one again goes back to both.
                BrowseChip(m.label, selected = f.media == m) { state.filters = f.copy(media = if (f.media == m) BrowseMedia.All else m); onChanged() }
            }
        }
        if (loadingRuntimes) {
            Text("Checking runtimes…", style = MaterialTheme.typography.labelSmall, color = tokens.colors.textMuted, modifier = Modifier.padding(start = 16.dp, bottom = 4.dp))
        }
    }
}

// ---------------------------------------------------------------------------------------------------- Titles

/** Short text for a title's wins: "2025 · Best Picture", "2013, 2014 · Drama Series". Nothing when the title has none. */
private fun awardLine(item: MetaPreview, awards: Map<String, List<AwardEntry>>): String? {
    val wins = awards[CollectionBrowse.key(item)].orEmpty().sortedBy { it.ceremonyYear }
    if (wins.isEmpty()) return null
    val years = if (wins.size <= 3) wins.joinToString(", ") { it.ceremonyYear.toString() } else "${wins.first().ceremonyYear}–${wins.last().ceremonyYear} (${wins.size} wins)"
    val category = wins.map { it.category.removePrefix("Outstanding ") }.distinct().singleOrNull()
    return listOfNotNull(years, category).joinToString(" · ")
}

@Composable
private fun CollectionPosterRow(
    items: List<MetaPreview>,
    columns: Int,
    awards: Map<String, List<AwardEntry>>,
    isWatched: (MetaPreview) -> Boolean,
    onClick: ((MetaPreview) -> Unit)?,
    onLongClick: ((MetaPreview) -> Unit)?,
) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.Top) {
        items.forEach { item ->
            CollectionPosterTile(
                item = item,
                award = awardLine(item, awards),
                watched = isWatched(item),
                modifier = Modifier.weight(1f),
                onClick = onClick?.let { { it(item) } },
                onLongClick = onLongClick?.let { { it(item) } },
            )
        }
        repeat(columns - items.size) { Spacer(Modifier.weight(1f)) }
    }
}

private fun spokenLabel(item: MetaPreview, award: String?, watched: Boolean): String =
    listOfNotNull(item.name, item.releaseInfo?.take(4), award?.let { "won $it" }, if (watched) "watched" else null).joinToString(", ")

/** A 2:3 poster with its title and year below. The watched mark is the app's own overlay; nothing is drawn over the artwork otherwise. */
@Composable
private fun CollectionPosterTile(
    item: MetaPreview,
    award: String?,
    watched: Boolean,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)?,
    onLongClick: (() -> Unit)?,
) {
    val tokens = MaterialTheme.nuvio
    val radius = rememberPosterCardStyleUiState().cornerRadiusDp.dp
    val haptic = LocalHapticFeedback.current
    Column(modifier.semantics(mergeDescendants = true) { contentDescription = spokenLabel(item, award, watched) }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(radius))
                .background(tokens.colors.surface)
                .posterCardClickable(
                    onClick = onClick,
                    onLongClick = onLongClick?.let { go -> { haptic.performHapticFeedback(HapticFeedbackType.LongPress); go() } },
                    zoomImageUrl = item.poster,
                    zoomCornerRadius = radius,
                ),
        ) {
            if (item.poster != null) AsyncImage(model = item.poster, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            NuvioPosterWatchedOverlay(isWatched = watched)
        }
        Text(item.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
        item.releaseInfo?.take(4)?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = tokens.colors.textMuted, maxLines = 1) }
        award?.let { Text(it, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary, maxLines = 2, overflow = TextOverflow.Ellipsis) }
    }
}

/** For a collection of one to three titles: a wide card with the poster and what it is about, not one poster in an empty grid. */
@Composable
private fun SparseTitleCard(item: MetaPreview, awards: Map<String, List<AwardEntry>>, watched: Boolean, onClick: (() -> Unit)?, onLongClick: (() -> Unit)?) {
    val tokens = MaterialTheme.nuvio
    val award = awardLine(item, awards)
    Row(
        Modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = spokenLabel(item, award, watched) },
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        CollectionPosterTile(item, award = null, watched = watched, modifier = Modifier.width(132.dp), onClick = onClick, onLongClick = onLongClick)
        Column(Modifier.weight(1f).padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(item.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, color = tokens.colors.textPrimary, maxLines = 3, overflow = TextOverflow.Ellipsis)
            Text(listOfNotNull(item.releaseInfo?.take(4), item.genres.take(2).joinToString(", ").ifBlank { null }).joinToString(" · "), style = MaterialTheme.typography.labelLarge, color = tokens.colors.textMuted)
            award?.let { Text(it, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary) }
            item.description?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textPrimary.copy(alpha = 0.8f), maxLines = 6, overflow = TextOverflow.Ellipsis) }
        }
    }
}

// ---------------------------------------------------------------------------------------------------- Sheets

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SortSheet(sorts: List<BrowseSort>, current: BrowseSort, loadingRuntimes: Boolean, onPick: (BrowseSort) -> Unit, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    NuvioModalBottomSheet(onDismissRequest = { scope.launch { dismissNuvioBottomSheet(sheetState, onDismiss) } }, sheetState = sheetState) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(bottom = nuvioSafeBottomPadding(16.dp))) {
            Text("Sort", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, color = MaterialTheme.nuvio.colors.textPrimary, modifier = Modifier.padding(horizontal = 16.dp, vertical = 14.dp))
            NuvioBottomSheetDivider()
            sorts.forEach { s ->
                NuvioBottomSheetActionRow(title = s.label, selected = s == current, onClick = { onPick(s); scope.launch { dismissNuvioBottomSheet(sheetState, onDismiss) } })
            }
            if (sorts.any { it.needsRuntime }) {
                Text(
                    "Runtime sorting looks up each title's length, so it can take a moment on a long collection.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.nuvio.colors.textMuted, modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                )
            }
        }
    }
}

private val LANGUAGE_NAMES = mapOf(
    "en" to "English", "fr" to "French", "es" to "Spanish", "de" to "German", "it" to "Italian", "ja" to "Japanese", "ko" to "Korean",
    "zh" to "Chinese", "cn" to "Cantonese", "hi" to "Hindi", "pt" to "Portuguese", "ru" to "Russian", "sv" to "Swedish", "da" to "Danish",
    "no" to "Norwegian", "nb" to "Norwegian", "fi" to "Finnish", "nl" to "Dutch", "pl" to "Polish", "tr" to "Turkish", "th" to "Thai",
    "ar" to "Arabic", "he" to "Hebrew", "el" to "Greek", "cs" to "Czech", "hu" to "Hungarian", "is" to "Icelandic", "ta" to "Tamil", "te" to "Telugu",
)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun FilterSheet(
    collection: ExploreCollection,
    all: List<MetaPreview>,
    ratingsKnown: Boolean,
    awards: Map<String, List<AwardEntry>>,
    current: BrowseFilters,
    onApply: (BrowseFilters) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val tokens = MaterialTheme.nuvio
    var draft by remember { mutableStateOf(current) }
    val facets = remember(all, awards) { CollectionBrowse.facets(all, awards) }
    val categories = remember(collection.id) { ExploreAwards.categories(collection.id) }
    val isAward = awards.isNotEmpty()

    @Composable
    fun Group(title: String, content: @Composable () -> Unit) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary)
            content()
        }
    }

    NuvioModalBottomSheet(onDismissRequest = { scope.launch { dismissNuvioBottomSheet(sheetState, onDismiss) } }, sheetState = sheetState, fullHeight = true) {
        Column(Modifier.fillMaxSize().padding(bottom = nuvioSafeBottomPadding(8.dp))) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Filters", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, color = tokens.colors.textPrimary, modifier = Modifier.weight(1f))
                BrowseChip("Reset", selected = false) { draft = draft.copy(genres = emptySet(), decades = emptySet(), runtime = null, minRating = null, languages = emptySet(), awardCategory = null) }
            }
            NuvioBottomSheetDivider()
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                if (categories.size > 1) Group("Award") {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        categories.forEach { c -> BrowseChip(c.removePrefix("Outstanding "), draft.awardCategory == c) { draft = draft.copy(awardCategory = if (draft.awardCategory == c) null else c) } }
                    }
                }
                if (facets.genres.isNotEmpty()) Group("Genre") {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        facets.genres.forEach { (g, _) -> BrowseChip(g, g in draft.genres) { draft = draft.copy(genres = draft.genres.toggle(g)) } }
                    }
                }
                if (facets.decades.isNotEmpty()) Group(if (isAward) "Ceremony decade" else "Decade") {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        facets.decades.forEach { d -> BrowseChip(CollectionBrowse.decadeLabel(d), d in draft.decades) { draft = draft.copy(decades = draft.decades.toggle(d)) } }
                    }
                }
                Group("Runtime") {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        RuntimeBand.entries.forEach { b -> BrowseChip(b.label, draft.runtime == b) { draft = draft.copy(runtime = if (draft.runtime == b) null else b) } }
                    }
                    Text("Runtimes are looked up as needed. A title with no runtime listed is left out of a runtime filter.", style = MaterialTheme.typography.bodySmall, color = tokens.colors.textMuted)
                }
                if (ratingsKnown) Group("Rating") {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(6.0, 7.0, 8.0).forEach { r -> BrowseChip("${r.toInt()}+", draft.minRating == r) { draft = draft.copy(minRating = if (draft.minRating == r) null else r) } }
                    }
                }
                if (facets.languages.isNotEmpty()) Group("Language") {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        facets.languages.take(12).forEach { (code, _) ->
                            BrowseChip(LANGUAGE_NAMES[code] ?: code.uppercase(), code in draft.languages) { draft = draft.copy(languages = draft.languages.toggle(code)) }
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
            NuvioBottomSheetDivider()
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                BrowseChip("Cancel", selected = false, modifier = Modifier.weight(1f)) { scope.launch { dismissNuvioBottomSheet(sheetState, onDismiss) } }
                BrowseChip("Apply", selected = true, modifier = Modifier.weight(1f)) { onApply(draft); scope.launch { dismissNuvioBottomSheet(sheetState, onDismiss) } }
            }
        }
    }
}

private fun <T> Set<T>.toggle(value: T): Set<T> = if (value in this) this - value else this + value
