package com.nuvio.app.features.player.skip

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nuvio.app.core.ui.glass.ambientLiquidGlass
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.player_next_episode
import nuvio.composeapp.generated.resources.player_next_episode_countdown_description
import nuvio.composeapp.generated.resources.player_next_episode_finding_source
import nuvio.composeapp.generated.resources.player_next_episode_identifier
import nuvio.composeapp.generated.resources.player_still_watching_continue
import nuvio.composeapp.generated.resources.player_still_watching_stop
import nuvio.composeapp.generated.resources.player_still_watching_title
import nuvio.composeapp.generated.resources.player_watch_credits
import org.jetbrains.compose.resources.stringResource

/**
 * The end of an episode, as two actions in the bottom-right corner over the full-screen video: a quiet Watch Credits and a
 * high-emphasis Next Episode. While the autoplay countdown runs, the Next Episode button fills from the left. Nothing about
 * where the next episode comes from is shown; if no source is ready yet the button says so quietly and stays usable.
 *
 * After Watch Credits the choice is the viewer's for the whole episode: only Next Episode remains, with no countdown.
 */
@Composable
fun PostPlayEpisodeActions(
    nextEpisode: NextEpisodeInfo?,
    visible: Boolean,
    preparing: Boolean,
    countdownSec: Int?,
    countdownTotalSec: Int,
    watchCreditsChosen: Boolean,
    onWatchCredits: () -> Unit,
    onPlayNext: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (nextEpisode == null) return
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(tween(220)),
        exit = fadeOut(tween(160)),
        modifier = modifier,
    ) {
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = stringResource(Res.string.player_next_episode_identifier, nextEpisode.season, nextEpisode.episode),
                color = Color.White.copy(alpha = 0.72f),
                fontSize = 12.sp,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                if (!watchCreditsChosen) SecondaryAction(stringResource(Res.string.player_watch_credits), onWatchCredits)
                NextEpisodeAction(
                    label = if (preparing && countdownSec == null) stringResource(Res.string.player_next_episode_finding_source) else stringResource(Res.string.player_next_episode),
                    countdownSec = countdownSec,
                    countdownTotalSec = countdownTotalSec,
                    onClick = onPlayNext,
                )
            }
        }
    }
}

@Composable
private fun SecondaryAction(label: String, onClick: () -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    Box(
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clip(shape)
            .ambientLiquidGlass(
                shape = shape,
                tint = Color(0xFF1E1E1E).copy(alpha = 0.6f),
                fallback = Color(0xFF1E1E1E).copy(alpha = 0.85f),
                blurRadius = 18.dp,
                refractionHeight = 10.dp,
                refractionAmount = 14.dp,
            )
            .semantics { role = Role.Button }
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text = label, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
private fun NextEpisodeAction(label: String, countdownSec: Int?, countdownTotalSec: Int, onClick: () -> Unit) {
    val shape = RoundedCornerShape(10.dp)
    val fill = remember { Animatable(0f) }
    val running = countdownSec != null
    // The fill runs once from the moment the countdown starts, linearly over its whole length.
    LaunchedEffect(running) {
        if (running) fill.animateTo(1f, tween(durationMillis = countdownTotalSec.coerceAtLeast(1) * 1000, easing = LinearEasing))
        else fill.snapTo(0f)
    }
    val description = if (countdownSec != null) {
        stringResource(Res.string.player_next_episode_countdown_description, countdownSec)
    } else {
        label
    }
    Box(
        modifier = Modifier
            .heightIn(min = 44.dp)
            .clip(shape)
            .background(Color.White)
            .semantics { role = Role.Button; contentDescription = description }
            .clickable(onClick = onClick),
        contentAlignment = Alignment.CenterStart,
    ) {
        // The countdown: a darker wash moving across the button.
        Box(
            Modifier
                .fillMaxHeight()
                .fillMaxWidth(fill.value)
                .background(Color.Black.copy(alpha = 0.14f))
                .align(Alignment.CenterStart),
        )
        Row(
            modifier = Modifier.padding(horizontal = 18.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Default.PlayArrow, contentDescription = null, tint = Color.Black, modifier = Modifier.width(20.dp))
            Text(text = label, color = Color.Black, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/**
 * "Are you still watching?" after several episodes in a row that started on their own. It waits for an answer, with no timer
 * and nothing that moves, and nothing plays on until the viewer chooses.
 */
@Composable
fun StillWatchingPrompt(
    visible: Boolean,
    onContinue: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    AnimatedVisibility(visible = visible, enter = fadeIn(tween(200)), exit = fadeOut(tween(150)), modifier = modifier) {
        com.nuvio.app.core.ui.PlatformBackHandler(enabled = visible, onBack = onStop)
        Box(
            modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.72f)).clickable(enabled = false) {},
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
                Text(
                    text = stringResource(Res.string.player_still_watching_title),
                    color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.SemiBold,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    SecondaryAction(stringResource(Res.string.player_still_watching_stop), onStop)
                    Box(
                        modifier = Modifier
                            .heightIn(min = 44.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .background(Color.White)
                            .semantics { role = Role.Button }
                            .clickable(onClick = onContinue)
                            .padding(horizontal = 22.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = stringResource(Res.string.player_still_watching_continue),
                            color = Color.Black, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }
        }
    }
}
