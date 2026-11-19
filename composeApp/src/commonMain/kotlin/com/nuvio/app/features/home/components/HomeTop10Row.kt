package com.nuvio.app.features.home.components

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.nuvio.app.core.ui.NuvioPosterCard
import com.nuvio.app.core.ui.NuvioPosterShape
import com.nuvio.app.core.ui.NuvioShelfSection
import com.nuvio.app.core.ui.nuvio
import com.nuvio.app.core.ui.rememberPosterCardStyleUiState
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.stableKey

/**
 * Netflix-style "Top 10 Today": films and series in one ranking (see HomeTrendingState.top10), each poster beside a
 * huge outlined rank number tucked slightly behind its left edge, with a small FILM or SERIES tag on the poster.
 */
@Composable
fun HomeTop10Row(
    items: List<MetaPreview>,
    sectionPadding: Dp,
    modifier: Modifier = Modifier,
    title: String = "Top 10 Today",
    onPosterClick: ((MetaPreview) -> Unit)? = null,
    onPosterLongClick: ((MetaPreview) -> Unit)? = null,
) {
    val style = rememberPosterCardStyleUiState()
    val ranked = remember(items) { items.mapIndexed { index, item -> (index + 1) to item } }
    NuvioShelfSection(
        title = title,
        entries = ranked,
        modifier = modifier,
        headerHorizontalPadding = sectionPadding,
        rowContentPadding = PaddingValues(horizontal = sectionPadding),
        itemSpacing = 6.dp,
        key = { (_, item) -> "top10:" + item.stableKey() },
        state = rememberLazyListState(),
    ) { (rank, item) ->
        Top10Card(
            rank = rank,
            item = item,
            posterHeight = style.heightDp.dp,
            onClick = onPosterClick?.let { { it(item) } },
            onLongClick = onPosterLongClick?.let { { it(item) } },
        )
    }
}

@Composable
private fun Top10Card(
    rank: Int,
    item: MetaPreview,
    posterHeight: Dp,
    onClick: (() -> Unit)?,
    onLongClick: (() -> Unit)?,
) {
    val tokens = MaterialTheme.nuvio
    val fontSize = (posterHeight.value * 0.8f).sp
    // The number slides under the poster by about a fifth of its width; "10" is drawn tighter so it isn't wider
    // than the poster beside it.
    val digits = rank.toString().length
    val overlap = (fontSize.value * 0.56f * digits * 0.2f).dp
    val base = TextStyle(
        fontSize = if (digits > 1) fontSize * 0.92f else fontSize,
        fontWeight = FontWeight.Black,
        letterSpacing = if (digits > 1) (-0.12).em else (-0.06).em,
        lineHeight = fontSize,
        textAlign = TextAlign.Center,
    )
    Row(verticalAlignment = Alignment.Bottom) {
        Box(
            // The rank is part of the card: tapping or holding it does what the poster does.
            modifier = Modifier
                .combinedClickable(
                    enabled = onClick != null || onLongClick != null,
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = { onClick?.invoke() },
                    onLongClick = onLongClick,
                )
                .layout { measurable, constraints ->
                val placeable = measurable.measure(constraints)
                val shrink = overlap.roundToPx()
                // Text leaves room under the digits; shift down so they stand on the poster's bottom edge.
                val drop = (fontSize.value * 0.17f).dp.roundToPx()
                layout((placeable.width - shrink).coerceAtLeast(0), placeable.height) { placeable.place(0, drop) }
            },
        ) {
            // The outline goes down first at double width, then the fill (the page background) covers its inner half.
            // Drawn the other way round, the strokes where a digit's own shapes overlap show through (a stray mark
            // inside the 2).
            Text(
                text = rank.toString(),
                style = base.copy(drawStyle = Stroke(width = 12f, join = StrokeJoin.Round)),
                color = Color.White.copy(alpha = 0.82f),
                maxLines = 1,
                softWrap = false,
            )
            Text(text = rank.toString(), style = base, color = tokens.colors.background, maxLines = 1, softWrap = false)
        }
        Box {
            NuvioPosterCard(
                title = item.name,
                imageUrl = item.poster,
                fallbackImageUrl = item.banner,
                shape = NuvioPosterShape.Poster,
                showTitleBelow = false,
                onClick = onClick,
                onLongClick = onLongClick,
            )
            // Films and series share the chart, so each poster says which it is.
            Text(
                text = if (item.type.equals("series", true) || item.type.equals("tv", true)) "SERIES" else "FILM",
                style = TextStyle(fontSize = 8.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.2.sp),
                color = Color.White.copy(alpha = 0.92f),
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(6.dp)
                    .clip(RoundedCornerShape(4.dp))
                    .background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 5.dp, vertical = 2.dp),
            )
        }
    }
}
