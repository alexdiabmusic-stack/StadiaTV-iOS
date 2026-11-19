package com.nuvio.app.features.search

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.PillChip
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.features.home.MetaPreview

/** A decade's defining film: its still is the decade's cover and it leads the decade's page. */
private class DefiningFilm(val title: String, val year: Int, val backdrop: String)

private fun definingFilm(start: Int): DefiningFilm = when (start) {
    2020 -> DefiningFilm("Top Gun: Maverick", 2022, "/AaV1YIdWKnjAIAOe8UUKBFm327v.jpg")
    2010 -> DefiningFilm("Avengers: Endgame", 2019, "/7RyHsO4yDXtBv1zUU3mTpHeQ0d5.jpg")
    2000 -> DefiningFilm("The Lord of the Rings: The Fellowship of the Ring", 2001, "/oiwc338EoBgS4sEI2ixAny4KQKg.jpg")
    1990 -> DefiningFilm("Jurassic Park", 1993, "/f082quUW2kAtZXFZVGEfhwacZoG.jpg")
    1980 -> DefiningFilm("Back to the Future", 1985, "/5bzPWQ2dFUl2aZKkp7ILJVVkRed.jpg")
    1970 -> DefiningFilm("Jaws", 1975, "/i1yf91svRHX45l9BXL8rVFzLoPH.jpg")
    1960 -> DefiningFilm("2001: A Space Odyssey", 1968, "/w5IDXtifKntw0ajv2co7jFlTQDM.jpg")
    else -> DefiningFilm("Singin' in the Rain", 1952, "/6qOyw4yfzbzTp5YsCX26C28Do0S.jpg")
}

/** Each decade's cover: a still from its defining film (a TMDB backdrop, chosen by hand). */
internal fun decadeCover(start: Int, size: String = "w780"): String = "https://image.tmdb.org/t/p/$size" + definingFilm(start).backdrop

/** A decade's rows: its defining films, the best rated, the series everyone watched and the hidden gems. */
private fun decadeShelves(start: Int): List<GenreShelf> {
    val from = "$start-01-01"
    val to = "${start + 9}-12-31"
    val films = mapOf("primary_release_date.gte" to from, "primary_release_date.lte" to to, "include_adult" to "false")
    val shows = mapOf("first_air_date.gte" to from, "first_air_date.lte" to to, "include_adult" to "false", "without_genres" to "10767,10763")
    fun shelf(key: String, title: String, tv: Boolean, query: Map<String, String>) = GenreShelf(
        title,
        BrowseSpec("decade-$start-$key", "${start}s: $title", if (tv) "discover/tv" else "discover/movie", (if (tv) shows else films) + query, tv),
    )
    return listOf(
        // The most voted-on films of the decade: the ones everybody saw.
        shelf("defining", "Defining Films", false, mapOf("sort_by" to "vote_count.desc")),
        shelf("top", "Top Rated", false, mapOf("sort_by" to "vote_average.desc", "vote_count.gte" to "1000")),
        shelf("series", "Popular Series", true, mapOf("sort_by" to "vote_count.desc", "vote_count.gte" to "100")),
        shelf("gems", "Hidden Gems", false, mapOf("sort_by" to "vote_average.desc", "vote_average.gte" to "7", "vote_count.gte" to "150", "vote_count.lte" to "1500")),
    )
}

/**
 * The Decades page: a timeline of decades pinned at the top; the chosen decade's defining film as
 * a full-width hero, then its rows. Moving along the timeline changes the whole page in place.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DecadeHubContent(
    onOpen: (SearchPage) -> Unit,
    onPosterClick: ((MetaPreview) -> Unit)?,
    onPosterLongClick: ((MetaPreview) -> Unit)?,
) {
    val tokens = MaterialTheme.nuvio
    // Oldest on the left, like a timeline; the newest decade is chosen first.
    val decades = SEARCH_DECADES.sorted()
    var start by rememberSaveable { mutableIntStateOf(decades.last()) }
    val timeline = rememberLazyListState(initialFirstVisibleItemIndex = decades.indexOf(start).coerceAtLeast(0))
    LaunchedEffect(start) { timeline.animateScrollToItem((decades.indexOf(start) - 1).coerceAtLeast(0)) }
    val shelves = decadeShelves(start)

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        stickyHeader(key = "decade-timeline") {
            LazyRow(
                state = timeline,
                modifier = Modifier.fillMaxWidth().background(tokens.colors.background).padding(vertical = 6.dp),
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                itemsIndexed(decades, key = { _, d -> "t-$d" }) { _, d ->
                    PillChip("${d}s", selected = d == start, onClick = { start = d })
                }
            }
        }
        item(key = "decade-hero") {
            Crossfade(targetState = start, label = "decade-hero") { d -> DecadeHero(d, onPosterClick) }
        }
        shelves.forEach { shelf ->
            item(key = "decade-shelf-${shelf.spec.key}") {
                GenreShelfRow(shelf, onOpen, onPosterClick, onPosterLongClick, preloaded = null)
            }
        }
    }
}

/** The chosen decade's defining film, full width: the decade in large type, the film and More Info. */
@Composable
private fun DecadeHero(start: Int, onPosterClick: ((MetaPreview) -> Unit)?) {
    val tokens = MaterialTheme.nuvio
    val pick = definingFilm(start)
    val film by produceState<MetaPreview?>(null, start) { value = SearchBrowseData.film(pick.title, pick.year) }
    val open: () -> Unit = { film?.let { onPosterClick?.invoke(it) } }
    Box(Modifier.fillMaxWidth().aspectRatio(16f / 11f).clickable(onClick = open)) {
        AsyncImage(model = decadeCover(start, "w1280"), contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.35f to Color.Transparent, 1f to tokens.colors.background)))
        Column(Modifier.align(Alignment.BottomStart).padding(horizontal = 16.dp, vertical = 8.dp)) {
            Text("${start}s", style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Black, color = Color.White)
            Text(
                "${pick.title} · ${pick.year}",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = tokens.colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            film?.description?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = tokens.colors.textSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
            Row(
                Modifier
                    .padding(top = 12.dp)
                    .height(40.dp)
                    .clip(RoundedCornerShape(50))
                    .background(Color.White)
                    .clickable(onClick = open)
                    .padding(horizontal = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Outlined.Info, contentDescription = null, tint = Color.Black, modifier = Modifier.size(20.dp))
                Text("More Info", color = Color.Black, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleSmall)
            }
        }
    }
}
