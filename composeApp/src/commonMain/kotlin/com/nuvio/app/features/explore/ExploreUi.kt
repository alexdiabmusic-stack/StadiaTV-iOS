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
