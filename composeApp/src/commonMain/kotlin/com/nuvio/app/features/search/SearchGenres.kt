package com.nuvio.app.features.search

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import com.nuvio.app.core.ui.NuvioShelfSection
import com.nuvio.app.core.ui.NuvioTokens
import com.nuvio.app.core.ui.PillChip
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.nuvioSafeBottomPadding
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.components.HomePosterCard
import com.nuvio.app.features.home.stableKey

/** Each genre's own colour, washed over its artwork so the grid reads at a glance. */
private fun genreColor(name: String): Color = when (name) {
    "Action & Adventure" -> Color(0xFFE5484D)
    "Animation" -> Color(0xFFF5A524)
    "Comedy" -> Color(0xFFF2C94C)
    "Crime" -> Color(0xFF6E56CF)
    "Documentary" -> Color(0xFF2EA66B)
    "Drama" -> Color(0xFF3E7BFA)
    "Family" -> Color(0xFFFF8A4C)
    "Fantasy & Sci-Fi" -> Color(0xFF12A5C9)
    "History" -> Color(0xFFA17C4E)
    "Horror" -> Color(0xFFB4232A)
    "Kids" -> Color(0xFFFF6FB1)
    "Music" -> Color(0xFFD946EF)
    "Mystery" -> Color(0xFF5B5BD6)
    "Reality" -> Color(0xFFE38A1C)
    "Romance" -> Color(0xFFE5486F)
    "Thriller" -> Color(0xFF4B5563)
    "War" -> Color(0xFF6B7A3A)
    "Western" -> Color(0xFFB7652B)
    else -> Color(0xFF3E7BFA)
}

/**
 * Each genre's cover, chosen by hand: a TMDB backdrop that says the genre at a glance. The most popular
 * title in a genre isn't safe to show (Music's turned out to be an explicit film), so these never change.
 */
private fun genreCover(name: String): String? = when (name) {
    "Action & Adventure" -> "/gqrnQA6Xppdl8vIb2eJc58VC1tW.jpg" // Mad Max: Fury Road
    "Animation" -> "/kVd3a9YeLGkoeR50jGEXM6EqseS.jpg" // Spider-Man: Across the Spider-Verse
    "Comedy" -> "/jK65srQczOKTpW62wPxwwKztGgE.jpg" // The Grand Budapest Hotel
    "Crime" -> "/tSPT36ZKlP2WVHJLM4cQPLSzv3b.jpg" // The Godfather
    "Documentary" -> "/z2uuQasY4gQJ8VDAFki746JWeQJ.jpg" // Free Solo
    "Drama" -> "/pNjh59JSxChQktamG3LMp9ZoQzp.jpg" // The Shawshank Redemption
    "Family" -> "/iJgNOTSBNrC90U2xyYq9ln0b35o.jpg" // Paddington 2
    "Fantasy & Sci-Fi" -> "/8sNiAPPYU14PUepFNeSNGUTiHW.jpg" // Interstellar
    "History" -> "/neeNHeXjMF5fXoCJRsOmkNGC7q.jpg" // Oppenheimer
    "Horror" -> "/nHRUtBwFNnNN70vcQ7lAsjc2T6S.jpg" // A Quiet Place
    "Kids" -> "/tWdNZ3xuFBhJ2ZoQ9vShNGHTb85.jpg" // Bluey
    "Music" -> "/dcvbs8z0GEXslC1kCT77x19XDeR.jpg" // Bohemian Rhapsody: Freddie Mercury on stage
    "Mystery" -> "/4HWAQu28e2yaWrtupFPGFkdNU7V.jpg" // Knives Out
    "Reality" -> "/nchu3aEyE8gsHbUyeRqRGMRUTKv.jpg" // The Great British Bake Off
    "Romance" -> "/1Onam6oWyFAUCcoxtdWkACtEiNr.jpg" // Pride & Prejudice
    "Thriller" -> "/3RFmTz5h2UuFWEV4oH00XICBR9y.jpg" // Prisoners
    "War" -> "/2lBOQK06tltt8SQaswgb8d657Mv.jpg" // 1917
    "Western" -> "/x4biAVdPVCghBlsVIzB6NmbghIz.jpg" // The Good, the Bad and the Ugly
    else -> null
}?.let { "https://image.tmdb.org/t/p/w780$it" }

/** A genre's main kind: films, unless it only exists for series (Kids, Reality). */
private fun SearchGenre.prefersSeries(): Boolean = movieId == null

/** The Genres page: a grid of artwork tiles, each in its genre's colour. */
@Composable
internal fun GenresIndexContent(onOpen: (SearchPage) -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val columns = when {
            maxWidth >= 900.dp -> 4
            maxWidth >= 600.dp -> 3
            else -> 2
        }
        val rows = SEARCH_GENRES.indices.chunked(columns)
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(rows.size, key = { "genre-row-$it" }) { rowIndex ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    rows[rowIndex].forEach { index ->
                        GenreTile(SEARCH_GENRES[index], Modifier.weight(1f)) { onOpen(SearchPage.Genre(index)) }
                    }
                    repeat(columns - rows[rowIndex].size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

@Composable
private fun GenreTile(genre: SearchGenre, modifier: Modifier, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    val tint = genreColor(genre.name)
    val cover = genreCover(genre.name)
    Box(
        modifier
            .aspectRatio(16f / 10f)
            .clip(RoundedCornerShape(14.dp))
            .background(tokens.colors.surface)
            .clickable(onClick = onClick),
    ) {
        cover?.let { AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
        Box(
            Modifier.fillMaxSize().background(
                Brush.linearGradient(listOf(tint.copy(alpha = 0.92f), tint.copy(alpha = 0.35f), Color.Black.copy(alpha = 0.55f))),
            ),
        )
        Text(
            genre.name,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = Color.White,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.BottomStart).padding(12.dp),
        )
    }
}

internal class GenreShelf(val title: String, val spec: BrowseSpec)

private fun genreShelves(genre: SearchGenre, tv: Boolean): List<GenreShelf> {
    val popular = genreSpec(genre, tv) ?: return emptyList()
    val kind = if (tv) "tv" else "movie"
    val id = popular.query["with_genres"].orEmpty()
    val base = popular.query - "sort_by" - "vote_count.gte"
    // True-crime and making-of documentaries swamp the rating-sorted rows of every other genre.
    val noDocs = if (genre.name == "Documentary") base else {
        val existing = base["without_genres"]
        base + ("without_genres" to listOfNotNull(existing, "99").joinToString(","))
    }
    val date = if (tv) "first_air_date.gte" else "primary_release_date.gte"
    fun spec(suffix: String, title: String, query: Map<String, String>) =
        BrowseSpec("genre-$kind-$id-$suffix", "${genre.name}: $title", popular.endpoint, noDocs + query, tv)
    return listOf(
        GenreShelf("Popular", popular),
        GenreShelf("New & Recent", spec("new", "New & Recent", mapOf(date to "{TWO_YEARS_AGO}", "sort_by" to "popularity.desc", "vote_count.gte" to "50"))),
        GenreShelf("Top Rated", spec("top", "Top Rated", mapOf("sort_by" to "vote_average.desc", "vote_count.gte" to if (tv) "400" else "1500"))),
        GenreShelf(
            "Hidden Gems",
            spec("gems", "Hidden Gems", mapOf("sort_by" to "vote_average.desc", "vote_average.gte" to "7", "vote_count.gte" to "150", "vote_count.lte" to "1500")),
        ),
    )
}

/** One genre: its biggest title as a hero, then Popular, New & Recent, Top Rated and Hidden Gems rows. */
@Composable
internal fun GenreHubContent(
    genre: SearchGenre,
    onOpen: (SearchPage) -> Unit,
    onPosterClick: ((MetaPreview) -> Unit)?,
    onPosterLongClick: ((MetaPreview) -> Unit)?,
) {
    val hasMovies = genre.movieId != null
    val hasSeries = genre.tvId != null
    var series by rememberSaveable(genre.name) { mutableStateOf(genre.prefersSeries()) }
    val shelves = genreShelves(genre, series)
    val popular by produceState<List<MetaPreview>?>(null, genre.name, series) {
        value = null
        value = shelves.firstOrNull()?.let { SearchBrowseData.list(it.spec) }.orEmpty()
    }
    val hero = popular?.firstOrNull { it.banner != null }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(bottom = nuvioSafeBottomPadding(NuvioTokens.Space.s16)),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item(key = "genre-hero") {
            GenreHero(genre, hero, onClick = { hero?.let { onPosterClick?.invoke(it) } })
        }
        if (hasMovies && hasSeries) {
            item(key = "genre-kind") {
                Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    PillChip("Movies", selected = !series, onClick = { series = false })
                    PillChip("Series", selected = series, onClick = { series = true })
                }
            }
        }
        shelves.forEach { shelf ->
            item(key = "genre-shelf-${shelf.spec.key}") {
                GenreShelfRow(shelf, onOpen, onPosterClick, onPosterLongClick, preloaded = popular.takeIf { shelf === shelves.first() })
            }
        }
    }
}

@Composable
private fun GenreHero(genre: SearchGenre, hero: MetaPreview?, onClick: () -> Unit) {
    val tokens = MaterialTheme.nuvio
    val tint = genreColor(genre.name)
    Box(
        Modifier
            .fillMaxWidth()
            .aspectRatio(16f / 11f)
            .background(Brush.verticalGradient(listOf(tint.copy(alpha = 0.6f), tokens.colors.background))),
    ) {
        hero?.banner?.let {
            AsyncImage(model = it, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clickable(onClick = onClick))
        }
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(0f to tint.copy(alpha = 0.25f), 0.55f to Color.Transparent, 1f to tokens.colors.background),
            ),
        )
        Column(Modifier.align(Alignment.BottomStart).padding(horizontal = 16.dp, vertical = 8.dp)) {
            Text(
                genre.name.uppercase(),
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
                color = tint,
            )
            if (hero != null) {
                Text(
                    hero.name,
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.Bold,
                    color = tokens.colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                hero.description?.let {
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
                        .clickable(onClick = onClick)
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
}

@Composable
internal fun GenreShelfRow(
    shelf: GenreShelf,
    onOpen: (SearchPage) -> Unit,
    onPosterClick: ((MetaPreview) -> Unit)?,
    onPosterLongClick: ((MetaPreview) -> Unit)?,
    preloaded: List<MetaPreview>?,
) {
    val items by produceState(preloaded, shelf.spec.key, preloaded) {
        value = preloaded ?: SearchBrowseData.list(shelf.spec)
    }
    val list = items ?: return
    // The hero's title leads Popular, so the row starts with the next one.
    val shown = if (preloaded != null) list.drop(1) else list
    if (shown.isEmpty()) return
    NuvioShelfSection(
        title = shelf.title,
        entries = shown.take(20),
        headerHorizontalPadding = 16.dp,
        rowContentPadding = PaddingValues(horizontal = 16.dp),
        onViewAllClick = { onOpen(SearchPage.Grid(shelf.spec.title, listOf("" to shelf.spec))) },
        key = { it.stableKey() },
    ) { item ->
        HomePosterCard(
            item = item,
            onClick = onPosterClick?.let { { it(item) } },
            onLongClick = onPosterLongClick?.let { { it(item) } },
        )
    }
}
