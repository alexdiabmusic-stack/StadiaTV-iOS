package com.nuvio.app.features.search

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.MovieCreation
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.nuvio

/** What a Browse All tile shows: artwork made from what's inside it, all hand-picked so it never changes. */
internal enum class BrowseArt { Genres, Actors, Directors, Decades, LiveTv }

private const val IMG = "https://image.tmdb.org/t/p"

/** Mad Max: Fury Road, Spider-Verse, Paddington 2 (the Genres page covers). */
private val GENRE_FAN = listOf("/gqrnQA6Xppdl8vIb2eJc58VC1tW.jpg", "/kVd3a9YeLGkoeR50jGEXM6EqseS.jpg", "/iJgNOTSBNrC90U2xyYq9ln0b35o.jpg")

/** Tom Hanks, Zendaya, Denzel Washington. */
private val ACTOR_FACES = listOf("/oFvZoKI6lvU03n4YoNGAll9rkas.jpg", "/1qup8tSt95HLbcy2c2xrx4iJNxv.jpg", "/jj2Gcobpopokal0YstuCQW0ldJ4.jpg")

/** Christopher Nolan. */
private const val DIRECTOR_FACE = "/xuAIuYSmsUzKlUMBFGVZaWsY3DZ.jpg"

/** Singin' in the Rain, Jaws, Jurassic Park, Top Gun: Maverick (the Decades page covers). */
private val DECADE_STRIP = listOf("/6qOyw4yfzbzTp5YsCX26C28Do0S.jpg", "/i1yf91svRHX45l9BXL8rVFzLoPH.jpg", "/f082quUW2kAtZXFZVGEfhwacZoG.jpg", "/AaV1YIdWKnjAIAOe8UUKBFm327v.jpg")

/** NBC, ESPN, FOX, CBS (TMDB network logos). */
private val CHANNEL_LOGOS = listOf("/cm111bsDVlYaC1foL0itvEI4yLG.png", "/nGVnOlJb5axYcLLdUT3dmiw7vU.png", "/1DSpHrWyOORkL9N2QHX7Adt31mQ.png", "/wju8KhOUsR5y4bH9p3Jc50hhaLO.png")

internal class BrowseEntry(val art: BrowseArt, val label: String, val tint: Color, val onClick: () -> Unit)

/** A Browse All tile: the colour wash, its own artwork in the top right and its name at the bottom. */
@Composable
internal fun BrowseTile(entry: BrowseEntry) {
    val tokens = MaterialTheme.nuvio
    Box(
        modifier = Modifier
            .width(168.dp)
            .height(104.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(tokens.colors.surface)
            .background(Brush.linearGradient(listOf(entry.tint.copy(alpha = 0.75f), entry.tint.copy(alpha = 0.18f))))
            .clickable(onClick = entry.onClick),
    ) {
        when (entry.art) {
            BrowseArt.Genres -> GenreFan(Modifier.align(Alignment.TopEnd).padding(top = 10.dp, end = 14.dp))
            BrowseArt.Actors -> FaceStack(Modifier.align(Alignment.TopEnd).padding(top = 10.dp, end = 10.dp))
            BrowseArt.Directors -> DirectorBadge(Modifier.align(Alignment.TopEnd).padding(top = 8.dp, end = 10.dp))
            BrowseArt.Decades -> FilmStrip(Modifier.align(Alignment.TopCenter).padding(top = 10.dp))
            BrowseArt.LiveTv -> LiveBoard(Modifier.fillMaxSize().padding(10.dp))
        }
        Text(
            entry.label,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.Bold,
            color = Color.White,
            maxLines = 1,
            modifier = Modifier.align(Alignment.BottomStart).padding(12.dp),
        )
    }
}

/** Three genre covers fanned out like cards. */
@Composable
private fun GenreFan(modifier: Modifier) {
    Box(modifier.width(104.dp).height(58.dp)) {
        GENRE_FAN.forEachIndexed { i, path ->
            AsyncImage(
                model = "$IMG/w300$path",
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .align(Alignment.Center)
                    .offset(x = ((i - 1) * 22).dp, y = if (i == 1) (-4).dp else 2.dp)
                    .rotate((i - 1) * 12f)
                    .size(width = 58.dp, height = 38.dp)
                    .clip(RoundedCornerShape(5.dp))
                    .border(1.5.dp, Color.White.copy(alpha = 0.9f), RoundedCornerShape(5.dp)),
            )
        }
    }
}

/** Three famous faces overlapping, like a group avatar. */
@Composable
private fun FaceStack(modifier: Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy((-12).dp)) {
        ACTOR_FACES.forEach { path ->
            AsyncImage(
                model = "$IMG/w185$path",
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.size(40.dp).clip(CircleShape).border(2.dp, Color.White, CircleShape),
            )
        }
    }
}

/** A director's face with a clapperboard badge, so it reads apart from Actors. */
@Composable
private fun DirectorBadge(modifier: Modifier) {
    Box(modifier.size(58.dp)) {
        AsyncImage(
            model = "$IMG/w185$DIRECTOR_FACE",
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(52.dp).clip(RoundedCornerShape(14.dp)).border(2.dp, Color.White, RoundedCornerShape(14.dp)),
        )
        Box(
            Modifier.align(Alignment.BottomEnd).size(24.dp).clip(CircleShape).background(Color.Black).border(1.5.dp, Color.White, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Rounded.MovieCreation, contentDescription = null, tint = Color.White, modifier = Modifier.size(14.dp))
        }
    }
}

/** A strip of film with a still from four decades. */
@Composable
private fun FilmStrip(modifier: Modifier) {
    Column(
        modifier.width(148.dp).clip(RoundedCornerShape(3.dp)).background(Color(0xFF111111)).padding(horizontal = 4.dp),
    ) {
        Sprockets()
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            DECADE_STRIP.forEach { path ->
                AsyncImage(
                    model = "$IMG/w300$path",
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.weight(1f).height(26.dp).clip(RoundedCornerShape(2.dp)),
                )
            }
        }
        Sprockets()
    }
}

@Composable
private fun Sprockets() {
    Row(Modifier.fillMaxWidth().height(9.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        repeat(12) { Box(Modifier.size(width = 5.dp, height = 3.dp).clip(RoundedCornerShape(1.dp)).background(Color.White.copy(alpha = 0.75f))) }
    }
}

/** A pulsing LIVE badge over a little wall of channel logos. */
@Composable
private fun LiveBoard(modifier: Modifier) {
    val pulse by rememberInfiniteTransition(label = "live").animateFloat(
        initialValue = 1f,
        targetValue = 0.25f,
        animationSpec = infiniteRepeatable(tween(900, easing = LinearEasing), RepeatMode.Reverse),
        label = "live-dot",
    )
    Box(modifier) {
        Row(
            Modifier.align(Alignment.TopStart).clip(RoundedCornerShape(50)).background(Color(0xFFE5484D)).padding(horizontal = 6.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Box(Modifier.size(6.dp).alpha(pulse).clip(CircleShape).background(Color.White))
            Text("LIVE", color = Color.White, fontSize = 9.sp, fontWeight = FontWeight.Black)
        }
        Column(Modifier.align(Alignment.TopEnd), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            CHANNEL_LOGOS.chunked(2).forEach { pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    pair.forEach { path ->
                        Box(
                            Modifier.size(width = 40.dp, height = 22.dp).clip(RoundedCornerShape(5.dp)).background(Color.White).padding(horizontal = 5.dp, vertical = 4.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            AsyncImage(model = "$IMG/w154$path", contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                        }
                    }
                }
            }
        }
    }
}
