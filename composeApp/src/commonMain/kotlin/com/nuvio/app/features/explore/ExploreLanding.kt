package com.nuvio.app.features.explore

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.features.explore.ExploreResolver.allItems
import kotlinx.coroutines.launch

/** What the landing page remembers while the app runs: its scroll position and which families are expanded. */
private object LandingMemory {
    val listState = LazyListState()
    var expanded by mutableStateOf(emptyList<String>())
}

private sealed interface LandingRow {
    val key: String
    data object Hero : LandingRow { override val key = "hero" }
    data class Heading(val text: String, val id: String, val count: Int? = null) : LandingRow { override val key = "h:$id" }
    data object Chips : LandingRow { override val key = "chips" }
    /** [slots] is how many cards fit across this row, so a short last row keeps its cards the same size as the others. */
    data class Cards(val block: CollectionLanding.Block, val id: String, val slots: Int) : LandingRow { override val key = "c:$id" }
    data class SeeAll(val id: String, val count: Int, val expanded: Boolean) : LandingRow { override val key = "all:$id" }
}

/**
 * The Collections landing page: a featured collection across the top, the other featured ones in a mosaic of wide and paired
 * cards, then every family (universes, genres, awards, seasonal, decades, quick picks and the rest) in a fixed order. Each family
 * shows a handful and expands in place. Nothing here is random, so the page looks the same on every visit.
 */
@Composable
fun ExploreBrowserScreen(
    onCollectionClick: (ExploreCollection) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    alwaysShowBack: Boolean = false,
) {
    val tokens = MaterialTheme.nuvio
    val scope = rememberCoroutineScope()
    val hero = remember { CollectionLanding.hero() }
    val featured = remember { CollectionLanding.featured() }
    val families = remember { CollectionLanding.families() }
    var expandedIds by LandingMemory::expanded
    val listState = LandingMemory.listState

    BoxWithConstraints(modifier.fillMaxSize().background(tokens.colors.background)) {
        val density = LocalDensity.current
        val contentWidth = minOf(maxWidth.value, CollectionBrowse.MAX_CONTENT_WIDTH_DP)
        val perRow = if (contentWidth >= 700f) 3 else 2
        val top = rememberPageTop(alwaysShowBack)
        val statusTop = top.inset
        val heroHeight = CollectionBrowse.heroHeightDp(maxWidth.value, maxHeight.value).dp + statusTop

        val rows = remember(expandedIds, perRow) {
            buildList {
                if (hero != null) add(LandingRow.Hero)
                if (featured.isNotEmpty()) {
                    add(LandingRow.Heading("Featured Collections", "featured"))
                    CollectionLanding.mosaic(featured).forEachIndexed { i, b -> add(LandingRow.Cards(b, "featured-$i", slots = if (b.wide) 1 else 2)) }
                }
                add(LandingRow.Chips)
                families.forEach { family ->
                    val id = family.category.name
                    val expanded = id in expandedIds
                    add(LandingRow.Heading(family.title, id, family.collections.size))
                    val shown = if (expanded) family.collections else family.collections.take(CollectionLanding.PREVIEW + if (family.category == CollectionCategory.Universes) 3 else 0)
                    // Universes get the editorial mosaic; every other family is a tidy grid of pairs (triples on a wide screen).
                    if (family.category == CollectionCategory.Universes) {
                        CollectionLanding.mosaic(shown).forEachIndexed { i, b -> add(LandingRow.Cards(b, "$id-$i", slots = if (b.wide) 1 else 2)) }
                    } else {
                        shown.chunked(perRow).forEachIndexed { i, chunk -> add(LandingRow.Cards(CollectionLanding.Block(wide = false, items = chunk), "$id-$i", slots = perRow)) }
                    }
                    if (family.collections.size > shown.size || expanded) add(LandingRow.SeeAll(id, family.collections.size, expanded))
                }
            }
        }

        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(28.dp)),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            items(rows, key = { it.key }) { row ->
                when (row) {
                    LandingRow.Hero -> if (hero != null) LandingHero(hero, heroHeight, top.heroTextTop, onClick = { onCollectionClick(hero) })
                    else -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
                        Column(Modifier.widthIn(max = CollectionBrowse.MAX_CONTENT_WIDTH_DP.dp).fillMaxWidth().sideSafe()) {
                            when (row) {
                                LandingRow.Hero -> Unit
                                is LandingRow.Heading -> Row(Modifier.padding(horizontal = 16.dp).padding(top = 10.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Text(row.text, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = tokens.colors.textPrimary, modifier = Modifier.semantics { contentDescription = row.text })
                                    row.count?.let { Text("$it", style = MaterialTheme.typography.labelLarge, color = tokens.colors.textMuted, modifier = Modifier.padding(bottom = 2.dp)) }
                                }
                                LandingRow.Chips -> Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                    Text("Browse by category", style = MaterialTheme.typography.titleSmall, color = tokens.colors.textMuted, modifier = Modifier.padding(horizontal = 16.dp))
                                    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        items(families, key = { it.category.name }) { family ->
                                            BrowseChip(family.title, selected = false) {
                                                scope.launch { rows.indexOfFirst { it is LandingRow.Heading && it.id == family.category.name }.takeIf { it >= 0 }?.let { listState.animateScrollToItem(it) } }
                                            }
                                        }
                                    }
                                }
                                is LandingRow.Cards -> Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                    row.block.items.forEach { c -> BoxWithConstraints(Modifier.weight(1f)) { ExploreCollectionCard(c, maxWidth, onClick = { onCollectionClick(c) }) } }
                                    repeat((row.slots - row.block.items.size).coerceAtLeast(0)) { Spacer(Modifier.weight(1f)) }
                                }
                                is LandingRow.SeeAll -> Text(
                                    if (row.expanded) "Show fewer" else "See all ${row.count}",
                                    style = MaterialTheme.typography.labelLarge,
                                    fontWeight = FontWeight.SemiBold,
                                    color = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier
                                        .padding(horizontal = 4.dp)
                                        .clickable { expandedIds = if (row.expanded) expandedIds - row.id else expandedIds + row.id }
                                        .padding(horizontal = 12.dp, vertical = 12.dp),
                                )
                            }
                        }
                    }
                }
            }
        }

        // The title and Back stay over the artwork while the page scrolls under them; once the hero has gone the bar fills in, so
        // the title never sits on top of card text.
        val heroPx = with(density) { heroHeight.toPx() }
        val barPx = with(density) { top.barHeight.toPx() }
        val barFill by remember(heroPx, barPx) {
            derivedStateOf {
                if (listState.firstVisibleItemIndex > 0) 1f
                else ((listState.firstVisibleItemScrollOffset - (heroPx - barPx * 2f)) / barPx).coerceIn(0f, 1f)
            }
        }
        Box(Modifier.align(Alignment.TopStart).fillMaxWidth().height(top.barHeight).background(tokens.colors.background.copy(alpha = barFill)))
        Row(
            Modifier.align(Alignment.TopStart).fillMaxWidth().sideSafe().padding(top = top.stripTop).height(top.stripHeight).padding(start = top.titleStart, end = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (!top.native) ExploreBackButton(onBack, alwaysShowBack, overArtwork = true)
            Text("Collections", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.semantics { contentDescription = "Collections" })
        }
    }
}

/** The featured collection: full-width artwork, its title and one line about it, and a restrained Explore button. */
@Composable
private fun LandingHero(collection: ExploreCollection, height: androidx.compose.ui.unit.Dp, textTop: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    val art by produceState<CollectionArt?>(null, collection.id) { value = ExploreResolver.art(collection, size = "w1280") }
    // The count is shown only once the collection has been opened (so it is a real count of what was found, never a guess).
    val count by produceState<Int?>(null, collection.id) { value = ExploreResolver.cached(collection.id)?.allItems()?.size?.takeIf { it > 0 } }
    val tagline = remember(collection.id) { collection.description.substringBefore(". ").trimEnd('.').plus(".") }
    val action = if (collection.category == CollectionCategory.Universes) "Explore Universe" else "Explore Collection"
    Box(Modifier.fillMaxWidth().height(height).background(tokens.colors.surface).clickable(onClick = onClick).semantics { contentDescription = "${collection.title}. $action" }) {
        art?.backdrop?.let { AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.0f to Color.Black.copy(alpha = 0.55f),
                    0.25f to Color.Transparent,
                    0.55f to tokens.colors.background.copy(alpha = 0.5f),
                    0.85f to tokens.colors.background.copy(alpha = 0.93f),
                    1.0f to tokens.colors.background,
                ),
            ),
        )
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth().sideSafe().padding(start = 20.dp, end = 20.dp, bottom = 14.dp, top = textTop),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text("FEATURED", style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.sp), color = tokens.colors.textPrimary.copy(alpha = 0.7f))
            if (art?.logo != null) {
                AsyncImage(model = art?.logo, contentDescription = collection.title, contentScale = ContentScale.Fit, alignment = Alignment.CenterStart, modifier = Modifier.fillMaxWidth(0.6f).height(72.dp))
            } else {
                Text(collection.title.uppercase(), style = TextStyle(fontSize = 28.sp, lineHeight = 31.sp, fontWeight = FontWeight.ExtraBold, letterSpacing = 0.5.sp), color = tokens.colors.textPrimary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Text(tagline, style = MaterialTheme.typography.bodyMedium, color = tokens.colors.textPrimary.copy(alpha = 0.85f), maxLines = 2, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    action,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = tokens.colors.background,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(tokens.colors.textPrimary).padding(horizontal = 18.dp, vertical = 10.dp),
                )
                count?.let { Text("$it titles", style = MaterialTheme.typography.labelMedium, color = tokens.colors.textMuted) }
            }
        }
    }
}
