package com.nuvio.app.features.explore

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.NuvioBackButton
import com.nuvio.app.core.ui.NuvioShelfSection
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.PillChip
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.core.ui.rememberPosterCardStyleUiState
import com.nuvio.app.features.explore.ExploreResolver.allItems
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.components.PosterGridRow
import com.nuvio.app.features.home.components.PosterGridSkeletonRow
import com.nuvio.app.features.home.components.posterGridColumnCountForWidth
import com.nuvio.app.features.recommendations.RecommendationEngine
import com.nuvio.app.features.watched.WatchedRepository
import com.nuvio.app.features.watching.application.WatchingState

// ---------------------------------------------------------------------------------------------------- Card

/**
 * A collection as a wide cinematic card, in the spirit of Disney+'s collection tiles: the collection's artwork, a
 * gradient that is only dark where the text sits, the franchise logo or a set title, and a small COLLECTION label.
 * The text sits low on the card so it doesn't cover the artwork's subject.
 */
@Composable
fun ExploreCollectionCard(
    collection: ExploreCollection,
    width: Dp,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val radius = rememberPosterCardStyleUiState().cornerRadiusDp.dp
    val shape = RoundedCornerShape(radius)
    val art by produceState<CollectionArt?>(null, collection.id) { value = ExploreResolver.art(collection) }
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed) 0.96f else 1f, tween(140), label = "collectionCardPress")
    Box(
        modifier = modifier
            .width(width)
            .aspectRatio(16f / 9f)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .clip(shape)
            .background(MaterialTheme.nuvio.colors.surface)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
    ) {
        art?.backdrop?.let {
            AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.0f to Color.Black.copy(alpha = 0.05f),
                    0.45f to Color.Black.copy(alpha = 0.15f),
                    1.0f to Color.Black.copy(alpha = 0.78f),
                ),
            ),
        )
        CollectionWordmark(
            collection = collection,
            logo = art?.logo,
            titleSize = (width.value * 0.075f).coerceIn(14f, 22f),
            logoMaxHeight = width * 0.2f,
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
        )
    }
}

/** The franchise logo (when the catalog names one and TMDB has it) or the title, over a small COLLECTION label. */
@Composable
private fun CollectionWordmark(
    collection: ExploreCollection,
    logo: String?,
    titleSize: Float,
    logoMaxHeight: Dp,
    modifier: Modifier = Modifier,
    label: String = "COLLECTION",
) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        if (logo != null) {
            AsyncImage(
                model = logo,
                contentDescription = collection.title,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxWidth(0.7f).heightIn(max = logoMaxHeight),
            )
        } else {
            Text(
                collection.title,
                style = TextStyle(
                    fontSize = titleSize.sp,
                    lineHeight = (titleSize * 1.08f).sp,
                    fontWeight = FontWeight.ExtraBold,
                    letterSpacing = 0.2.sp,
                    shadow = Shadow(Color.Black.copy(alpha = 0.6f), blurRadius = 12f),
                ),
                color = Color.White,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            label,
            style = TextStyle(fontSize = 8.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 3.sp),
            color = Color.White.copy(alpha = 0.78f),
            maxLines = 1,
        )
    }
}

// ---------------------------------------------------------------------------------------------------- Home rail

/** "Explore Collections" on Home: a profile's subset of collections, with See All opening the full browser. */
@Composable
fun ExploreCollectionsRail(
    collections: List<ExploreCollection>,
    sectionPadding: Dp,
    onCollectionClick: (ExploreCollection) -> Unit,
    onSeeAll: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (collections.isEmpty()) return
    BoxWithConstraints(modifier.fillMaxWidth()) {
        // Wide cards: about one and a half across a phone, more on wider screens.
        val cardWidth = (maxWidth * 0.62f).coerceIn(220.dp, 340.dp)
        NuvioShelfSection(
            title = "Explore Collections",
            entries = collections,
            headerHorizontalPadding = sectionPadding,
            rowContentPadding = PaddingValues(horizontal = sectionPadding),
            itemSpacing = 12.dp,
            onViewAllClick = onSeeAll,
            key = { it.id },
        ) { collection ->
            ExploreCollectionCard(collection, cardWidth, onClick = { onCollectionClick(collection) })
        }
    }
}

// ---------------------------------------------------------------------------------------------------- Browser

/** Every published collection, grouped by family (Featured, Universes, Genres, Moods, ...). */
@Composable
fun ExploreBrowserScreen(
    onCollectionClick: (ExploreCollection) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    alwaysShowBack: Boolean = false,
) {
    val groups = remember { ExploreCatalog.byCategory() }
    BoxWithConstraints(modifier.fillMaxSize().background(MaterialTheme.nuvio.colors.background)) {
        val cardWidth = (maxWidth * 0.52f).coerceIn(190.dp, 300.dp)
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            item(key = "header") {
                Column(Modifier.statusBarsPadding().padding(horizontal = 16.dp).padding(top = 8.dp)) {
                    ExploreBackButton(onBack, alwaysShowBack)
                    Spacer(Modifier.height(12.dp))
                    Text("Explore Collections", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = MaterialTheme.nuvio.colors.textPrimary)
                    Text(
                        "Franchises, moods, decades, awards and more.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.nuvio.colors.textMuted,
                    )
                }
            }
            items(groups, key = { it.first.name }) { (category, list) ->
                NuvioShelfSection(
                    title = category.title,
                    entries = list,
                    headerHorizontalPadding = 16.dp,
                    rowContentPadding = PaddingValues(horizontal = 16.dp),
                    itemSpacing = 12.dp,
                    key = { it.id },
                ) { collection -> ExploreCollectionCard(collection, cardWidth, onClick = { onCollectionClick(collection) }) }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------- Collection page

private enum class MediaFilter(val label: String) { All("All"), Movies("Movies"), Series("Series") }

private enum class SortMode(val label: String) {
    Curated("Collection Order"), Release("Release Order"), Story("Story Order"), Newest("Newest"), TopRated("Top Rated")
}

/**
 * A collection's own page: cinematic artwork with the logo or title and description, franchise progress, nested
 * collections, then the titles in shelves (or as one sorted grid). Shelves appear as each one is found.
 */
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
    val watchedState by remember { WatchedRepository.ensureLoaded(); WatchedRepository.uiState }.collectAsState()
    val fullyWatched by WatchedRepository.fullyWatchedSeriesKeys.collectAsState()
    val personal by RecommendationEngine.state.collectAsState()
    val watchedKeys = remember(watchedState.watchedKeys, personal.watchedTmdbKeys) { watchedState.watchedKeys + personal.watchedTmdbKeys }
    val completedKeys = remember(fullyWatched, personal.completedSeriesTmdbKeys) { fullyWatched + personal.completedSeriesTmdbKeys }

    var attempt by remember { mutableIntStateOf(0) }
    var done by remember(collectionId, attempt) { mutableStateOf(false) }
    val resolved by produceState<ResolvedCollection?>(null, collectionId, attempt) {
        value = ExploreResolver.resolve(collection) { value = it }
        done = true
    }
    val art by produceState<CollectionArt?>(null, collectionId) { value = ExploreResolver.art(collection, size = "w1280") }
    val children = remember(collectionId) { ExploreCatalog.children(collection) }

    var filter by rememberSaveable(collectionId) { mutableStateOf(MediaFilter.All) }
    var sort by rememberSaveable(collectionId) { mutableStateOf(SortMode.Curated) }
    val all = resolved?.allItems().orEmpty()
    val hasBoth = all.any { it.type == "series" } && all.any { it.type == "movie" }
    val sorts = buildList {
        add(SortMode.Curated)
        if (collection.kind == CollectionKind.Franchise) add(SortMode.Release)
        if (collection.storyOrder != null) add(SortMode.Story)
        add(SortMode.Newest)
        add(SortMode.TopRated)
    }

    fun MetaPreview.passes() = when (filter) {
        MediaFilter.All -> true
        MediaFilter.Movies -> type == "movie"
        MediaFilter.Series -> type == "series"
    }

    BoxWithConstraints(modifier.fillMaxSize().background(tokens.colors.background)) {
        val columns = posterGridColumnCountForWidth(maxWidth)
        val childCardWidth = (maxWidth * 0.52f).coerceIn(190.dp, 300.dp)
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            item(key = "hero") { CollectionHero(collection, art, onBack, alwaysShowBack) }

            if (collection.kind == CollectionKind.Franchise && all.isNotEmpty()) {
                item(key = "progress") {
                    val seen = all.count { WatchingState.isPosterWatched(watchedKeys, it, completedKeys) }
                    FranchiseProgress(seen, all.size, Modifier.padding(horizontal = 16.dp))
                }
            }

            if (children.isNotEmpty() && collection.sections.isEmpty()) {
                // A collection of collections (Movie Universes, The Complete Saga): its collections are the page.
                val perRow = if (maxWidth >= 700.dp) 3 else 2
                item(key = "children-title") { SectionTitle("Collections") }
                children.chunked(perRow).forEachIndexed { index, row ->
                    item(key = "children-$index") {
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            row.forEach { child ->
                                BoxWithConstraints(Modifier.weight(1f)) {
                                    ExploreCollectionCard(child, maxWidth, onClick = { onCollectionClick(child) })
                                }
                            }
                            repeat(perRow - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            } else if (children.isNotEmpty()) {
                item(key = "children") {
                    NuvioShelfSection(
                        title = "Explore Further",
                        entries = children,
                        headerHorizontalPadding = 16.dp,
                        rowContentPadding = PaddingValues(horizontal = 16.dp),
                        itemSpacing = 12.dp,
                        key = { it.id },
                    ) { child -> ExploreCollectionCard(child, childCardWidth, onClick = { onCollectionClick(child) }) }
                }
            }

            if (all.isNotEmpty()) {
                item(key = "controls") {
                    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (hasBoth) items(MediaFilter.entries, key = { "f-" + it.name }) { f -> PillChip(f.label, filter == f, { filter = f }) }
                        if (hasBoth) item(key = "gap") { Spacer(Modifier.width(8.dp)) }
                        items(sorts, key = { "s-" + it.name }) { s -> PillChip(s.label, sort == s, { sort = s }) }
                    }
                }
            }

            val r = resolved
            when {
                collection.sections.isEmpty() -> Unit
                r == null || (r.sections.isEmpty() && !done) -> item(key = "loading") {
                    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        repeat(2) { PosterGridSkeletonRow(columns = columns) }
                    }
                }
                r.sections.isEmpty() && r.upcoming.isEmpty() -> item(key = "empty") {
                    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("Nothing to show right now", style = MaterialTheme.typography.titleMedium, color = tokens.colors.textPrimary)
                        Text("The titles couldn't be loaded. Check the connection and try again.", style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted, textAlign = TextAlign.Center)
                        PillChip("Try Again", false, { attempt++ })
                    }
                }
                sort == SortMode.Curated -> {
                    r.sections.forEach { section ->
                        val shown = section.items.filter { it.passes() }
                        if (shown.isEmpty()) return@forEach
                        item(key = "h-" + section.title) { SectionTitle(section.title) }
                        shown.chunked(columns).forEachIndexed { index, row ->
                            item(key = "r-${section.title}-$index") {
                                PosterGridRow(row, columns, Modifier.padding(horizontal = 16.dp), watchedKeys, completedKeys, onPosterClick, onPosterLongClick)
                            }
                        }
                    }
                }
                else -> {
                    val ordered = sorted(all.filter { it.passes() }, sort, collection.storyOrder, r.ratings)
                    item(key = "h-sorted") { SectionTitle(sort.label) }
                    ordered.chunked(columns).forEachIndexed { index, row ->
                        item(key = "sorted-${sort.name}-$index") {
                            PosterGridRow(row, columns, Modifier.padding(horizontal = 16.dp), watchedKeys, completedKeys, onPosterClick, onPosterLongClick)
                        }
                    }
                }
            }

            val upcoming = r?.upcoming.orEmpty().filter { it.passes() }
            if (upcoming.isNotEmpty()) {
                item(key = "h-upcoming") { SectionTitle("Announced") }
                upcoming.chunked(columns).forEachIndexed { index, row ->
                    item(key = "up-$index") { PosterGridRow(row, columns, Modifier.padding(horizontal = 16.dp), watchedKeys, completedKeys, onPosterClick, onPosterLongClick) }
                }
            }
        }
    }
}

private fun sorted(items: List<MetaPreview>, sort: SortMode, story: List<TitleRef>?, ratings: Map<String, Double>): List<MetaPreview> = when (sort) {
    SortMode.Curated -> items
    SortMode.Release -> items.sortedBy { it.rawReleaseDate ?: "9999" }
    SortMode.Newest -> items.sortedByDescending { it.rawReleaseDate ?: "" }
    SortMode.TopRated -> items.sortedByDescending { ratings[it.id] ?: 0.0 }
    SortMode.Story -> {
        // Titles in the curated story order first; anything else in the collection follows in release order.
        val position = story.orEmpty().mapIndexed { i, ref -> "tmdb:${ref.tmdbId}|${if (ref.tv) "series" else "movie"}" to i }.toMap()
        items.sortedWith(compareBy({ position["${it.id}|${it.type}"] ?: Int.MAX_VALUE }, { it.rawReleaseDate ?: "9999" }))
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleLarge,
        color = MaterialTheme.nuvio.colors.textPrimary,
        modifier = Modifier.padding(horizontal = 16.dp),
    )
}

@Composable
private fun CollectionHero(collection: ExploreCollection, art: CollectionArt?, onBack: () -> Unit, alwaysShowBack: Boolean) {
    val tokens = MaterialTheme.nuvio
    Box(Modifier.fillMaxWidth().height(360.dp).background(tokens.colors.surface)) {
        art?.backdrop?.let { AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.0f to Color.Black.copy(alpha = 0.45f),
                    0.3f to Color.Transparent,
                    0.62f to tokens.colors.background.copy(alpha = 0.55f),
                    1.0f to tokens.colors.background,
                ),
            ),
        )
        ExploreBackButton(onBack, alwaysShowBack, Modifier.statusBarsPadding().padding(start = 12.dp, top = 8.dp), overArtwork = true)
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CollectionWordmark(collection, art?.logo, titleSize = 30f, logoMaxHeight = 96.dp)
            collection.subtitle?.let { Text(it, style = MaterialTheme.typography.labelMedium, color = tokens.colors.textMuted) }
            Text(
                collection.description,
                style = MaterialTheme.typography.bodyMedium,
                color = tokens.colors.textPrimary.copy(alpha = 0.85f),
                textAlign = TextAlign.Center,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
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

/** The app's back button; [always] draws it even where native navigation would supply its own. */
@Composable
internal fun ExploreBackButton(onBack: () -> Unit, always: Boolean, modifier: Modifier = Modifier, overArtwork: Boolean = false) {
    val container = if (overArtwork) Color.Black.copy(alpha = 0.4f) else MaterialTheme.nuvio.colors.surface
    val content = if (overArtwork) Color.White else MaterialTheme.nuvio.colors.textPrimary
    if (!always) {
        NuvioBackButton(onClick = onBack, containerColor = container, contentColor = content, modifier = modifier)
        return
    }
    Box(
        modifier.size(40.dp).clip(androidx.compose.foundation.shape.CircleShape).background(container).clickable(onClick = onBack),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.material3.Icon(
            Icons.AutoMirrored.Rounded.ArrowBack,
            contentDescription = "Back",
            tint = content,
        )
    }
}
