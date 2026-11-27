package com.nuvio.app.features.search

import androidx.compose.foundation.background
import com.nuvio.app.features.home.components.HomeTop10Row
import com.nuvio.app.features.explore.ExploreBrowserScreen
import com.nuvio.app.features.explore.ExploreCatalog
import com.nuvio.app.features.explore.ExploreCollectionCard
import com.nuvio.app.features.explore.ExploreCollectionScreen
import com.nuvio.app.features.explore.ExploreSelection
import com.nuvio.app.features.recommendations.RecommendationEngine
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.remember
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.Groups
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.Sensors
import androidx.compose.material.icons.rounded.Theaters
import androidx.compose.material.icons.rounded.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.NuvioShelfSection
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.components.HomePosterCard
import com.nuvio.app.features.home.components.HomeSkeletonRow
import com.nuvio.app.features.home.components.PosterGridRow
import com.nuvio.app.features.home.components.PosterGridSkeletonRow
import com.nuvio.app.features.home.components.posterGridColumnCountForWidth
import com.nuvio.app.features.home.stableKey
import com.nuvio.app.features.watching.application.WatchingState

/** A page opened from the Search home. They stack: Genres opens a genre's list, and back returns to Genres. */
internal sealed interface SearchPage {
    /** A poster list; with more than one option (Movies / Series) it gets a chip for each. */
    data class Grid(val title: String, val options: List<Pair<String, BrowseSpec>>) : SearchPage
    /** One Explore collection (the same page Home opens). */
    data class Explore(val id: String) : SearchPage
    /** Every Explore collection, by family. */
    data object ExploreAll : SearchPage
    data object Genres : SearchPage
    /** One genre's own page: a hero and rows of its titles. */
    data class Genre(val index: Int) : SearchPage
    data object Decades : SearchPage
    data class People(val directors: Boolean) : SearchPage
}

internal fun SearchPage.title(): String = when (this) {
    is SearchPage.Grid -> title
    is SearchPage.Explore -> ExploreCatalog[id]?.title.orEmpty()
    SearchPage.ExploreAll -> "Explore Collections"
    SearchPage.Genres -> "Genres"
    is SearchPage.Genre -> SEARCH_GENRES.getOrNull(index)?.name.orEmpty()
    SearchPage.Decades -> "Decades"
    is SearchPage.People -> if (directors) "Directors" else "Actors"
}

private fun movieAndSeries(title: String, movie: BrowseSpec?, tv: BrowseSpec?) =
    SearchPage.Grid(title, listOfNotNull(movie?.let { "Movies" to it }, tv?.let { "Series" to it }))

/** The Search tab's start page: popular searches, collections, Browse All and what is trending this week. */
internal fun LazyListScope.searchHomeSections(
    onOpen: (SearchPage) -> Unit,
    showLiveTv: Boolean,
    onOpenLiveTv: () -> Unit,
    watchedKeys: Set<String>,
    fullyWatchedSeriesKeys: Set<String>,
    onPosterClick: ((MetaPreview) -> Unit)?,
    onPosterLongClick: ((MetaPreview) -> Unit)?,
) {
    // Every section uses Home's shelf: the same heading, spacing and edge-to-edge rows.
    item(key = "sh-popular") {
        NuvioShelfSection(
            title = "Popular searches",
            entries = SEARCH_POPULAR,
            modifier = Modifier.padding(bottom = SECTION_GAP),
            headerHorizontalPadding = 16.dp,
            rowContentPadding = PaddingValues(horizontal = 16.dp),
            itemSpacing = 8.dp,
            key = { it.key },
        ) { spec ->
            PopularChip(spec.title) { onOpen(SearchPage.Grid(spec.title, listOf("" to spec))) }
        }
    }
    item(key = "sh-collections") {
        // The same collections and cards as Home (this profile's selection for the week).
        val taste = RecommendationEngine.state.collectAsState().value.taste
        val picks = remember(taste.genres.keys) { ExploreSelection.forHomeToday(taste, com.nuvio.app.features.watchprogress.CurrentDateProvider.todayIsoDate()) }
        NuvioShelfSection(
            title = "Explore Collections",
            entries = picks,
            modifier = Modifier.padding(bottom = SECTION_GAP),
            headerHorizontalPadding = 16.dp,
            rowContentPadding = PaddingValues(horizontal = 16.dp),
            itemSpacing = 12.dp,
            onViewAllClick = { onOpen(SearchPage.ExploreAll) },
            key = { it.id },
        ) { collection ->
            ExploreCollectionCard(collection, 250.dp, onClick = { onOpen(SearchPage.Explore(collection.id)) })
        }
    }
    item(key = "sh-browse") {
        val tiles = buildList {
            add(BrowseEntry(BrowseArt.Genres, "Genres", Color(0xFFE5484D)) { onOpen(SearchPage.Genres) })
            add(BrowseEntry(BrowseArt.Actors, "Actors", Color(0xFF3E7BFA)) { onOpen(SearchPage.People(directors = false)) })
            add(BrowseEntry(BrowseArt.Directors, "Directors", Color(0xFF8E4EC6)) { onOpen(SearchPage.People(directors = true)) })
            add(BrowseEntry(BrowseArt.Decades, "Decades", Color(0xFFE38A1C)) { onOpen(SearchPage.Decades) })
            if (showLiveTv) add(BrowseEntry(BrowseArt.LiveTv, "Live TV", Color(0xFF2EA66B), onOpenLiveTv))
        }
        NuvioShelfSection(
            title = "Browse All",
            entries = tiles,
            modifier = Modifier.padding(bottom = SECTION_GAP),
            headerHorizontalPadding = 16.dp,
            rowContentPadding = PaddingValues(horizontal = 16.dp),
            key = { it.label },
        ) { BrowseTile(it) }
    }
    item(key = "sh-trending") {
        val trending by produceState<List<MetaPreview>>(emptyList()) { value = SearchBrowseData.trending() }
        if (trending.isEmpty()) {
            HomeSkeletonRow(modifier = Modifier.padding(horizontal = 16.dp))
        } else {
            // Ranked like Home's Top 10 rows.
            HomeTop10Row(
                items = trending.take(10),
                sectionPadding = 16.dp,
                title = "Trending This Week",
                modifier = Modifier.padding(bottom = SECTION_GAP),
                onPosterClick = onPosterClick,
                onPosterLongClick = onPosterLongClick,
            )
        }
    }
}

private val SECTION_GAP = 18.dp

@Composable
internal fun SearchPill(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) =
    com.nuvio.app.core.ui.PillChip(label, selected, onClick, modifier)

@Composable
private fun PopularChip(label: String, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(tokens.colors.textPrimary.copy(alpha = 0.08f))
            .clickable(onClick = onClick)
            .padding(start = 12.dp, end = 16.dp, top = 9.dp, bottom = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Rounded.Search, contentDescription = null, tint = tokens.colors.textMuted, modifier = Modifier.size(16.dp))
        Text(label, style = MaterialTheme.typography.labelLarge, color = tokens.colors.textPrimary, maxLines = 1)
    }
}

/** The page a Search home tile opens, under a back arrow. */
@Composable
internal fun SearchBrowsePage(
    page: SearchPage,
    onBack: () -> Unit,
    onOpen: (SearchPage) -> Unit,
    watchedKeys: Set<String>,
    fullyWatchedSeriesKeys: Set<String>,
    onPosterClick: ((MetaPreview) -> Unit)?,
    onPosterLongClick: ((MetaPreview) -> Unit)?,
    onPersonClick: (id: Int, name: String, photo: String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = MaterialTheme.nuvio
    Column(modifier.fillMaxSize().background(tokens.colors.background)) {
        // Explore pages open with their own artwork and back button, so they have no bar of their own.
        if (page !is SearchPage.Explore && page !is SearchPage.ExploreAll) {
            Row(
                Modifier.fillMaxWidth().statusBarsPadding().height(48.dp).clickable(onClick = onBack).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = "Back", tint = tokens.colors.textPrimary)
                Text(
                    page.title(),
                    color = tokens.colors.textPrimary,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 12.dp),
                )
            }
        }
        when (page) {
            is SearchPage.Grid -> GridPageContent(page, watchedKeys, fullyWatchedSeriesKeys, onPosterClick, onPosterLongClick)
            is SearchPage.Explore -> ExploreCollectionScreen(
                collectionId = page.id,
                onCollectionClick = { onOpen(SearchPage.Explore(it.id)) },
                onPosterClick = onPosterClick,
                onPosterLongClick = onPosterLongClick,
                onBack = onBack,
                alwaysShowBack = true,
            )
            SearchPage.ExploreAll -> ExploreBrowserScreen(
                onCollectionClick = { onOpen(SearchPage.Explore(it.id)) },
                onBack = onBack,
                alwaysShowBack = true,
            )
            SearchPage.Genres -> GenresIndexContent(onOpen)
            is SearchPage.Genre -> SEARCH_GENRES.getOrNull(page.index)?.let { genre ->
                GenreHubContent(genre, onOpen, onPosterClick, onPosterLongClick)
            }
            SearchPage.Decades -> DecadeHubContent(onOpen, onPosterClick, onPosterLongClick)
            is SearchPage.People -> PeopleContent(page.directors, onPersonClick)
        }
    }
}

@Composable
private fun GridPageContent(
    page: SearchPage.Grid,
    watchedKeys: Set<String>,
    fullyWatchedSeriesKeys: Set<String>,
    onPosterClick: ((MetaPreview) -> Unit)?,
    onPosterLongClick: ((MetaPreview) -> Unit)?,
) {
    val tokens = MaterialTheme.nuvio
    var selected by rememberSaveable(page.title) { mutableIntStateOf(0) }
    val spec = page.options.getOrNull(selected)?.second
    val items by produceState<List<MetaPreview>?>(null, spec?.key) {
        value = null
        value = spec?.let { SearchBrowseData.list(it) }.orEmpty()
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val columns = posterGridColumnCountForWidth(maxWidth)
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (page.options.size > 1) {
                item(key = "chips") {
                    Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        page.options.forEachIndexed { index, (label, _) -> SearchPill(label, selected = selected == index, onClick = { selected = index }) }
                    }
                }
            }
            val list = items
            when {
                list == null -> items(2) { PosterGridSkeletonRow(columns = columns, modifier = Modifier.padding(horizontal = 16.dp)) }
                list.isEmpty() -> item(key = "empty") {
                    Text("Nothing to show right now.", style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted, modifier = Modifier.padding(horizontal = 16.dp))
                }
                else -> items(count = (list.size + columns - 1) / columns, key = { "row-$it" }) { rowIndex ->
                    val first = rowIndex * columns
                    PosterGridRow(
                        items = list.subList(first, minOf(first + columns, list.size)),
                        columns = columns,
                        modifier = Modifier.padding(horizontal = 16.dp),
                        watchedKeys = watchedKeys,
                        fullyWatchedSeriesKeys = fullyWatchedSeriesKeys,
                        onPosterClick = onPosterClick,
                        onPosterLongClick = onPosterLongClick,
                    )
                }
            }
        }
    }
}

@Composable
private fun PeopleContent(directors: Boolean, onPersonClick: (id: Int, name: String, photo: String?) -> Unit) {
    val tokens = MaterialTheme.nuvio
    val people by produceState<List<PersonHit>?>(null, directors) {
        value = if (directors) SearchBrowseData.directors() else SearchBrowseData.popularActors()
    }
    val list = people
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when {
            list == null -> item(key = "loading") { HomeSkeletonRow() }
            list.isEmpty() -> item(key = "empty") { Text("Nothing to show right now.", style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textMuted) }
            else -> items(list, key = { "p-${it.id}" }) { person ->
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(tokens.colors.surface)
                        .clickable { onPersonClick(person.id, person.name, person.photo) }.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(Modifier.size(52.dp).clip(CircleShape).background(tokens.colors.surfaceElevated), contentAlignment = Alignment.Center) {
                        if (person.photo != null) AsyncImage(model = person.photo, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                        else Icon(Icons.Rounded.Person, contentDescription = null, tint = tokens.colors.textMuted)
                    }
                    Column(Modifier.weight(1f)) {
                        Text(person.name, style = MaterialTheme.typography.titleSmall, color = tokens.colors.textPrimary, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        person.subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = tokens.colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    }
                    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = tokens.colors.textMuted)
                }
            }
        }
    }
}

