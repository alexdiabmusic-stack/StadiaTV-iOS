package com.nuvio.app.core.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/**
 * The system's edge-swipe back gesture with its progress (0 to 1) while the finger is down. The flow completes when
 * the swipe is committed and the collecting coroutine is cancelled when it is abandoned.
 */
@Composable
expect fun PlatformPredictiveBackHandler(
    enabled: Boolean,
    onBack: suspend (progress: Flow<Float>) -> Unit,
)

/**
 * A page that sits on top of another one and goes away with the iOS back swipe: while the finger drags in from the
 * left edge the page follows it, sliding to the right over the page it came from, which is revealed underneath
 * (drawn by [behind], and nudged and dimmed the way a UINavigationController does). Let go past the middle and the
 * page finishes leaving and [onBack] runs; let go early and it springs back.
 *
 * Use it wherever a screen swaps one page for another inside itself, so the swipe feels like the one the real
 * (pushed) screens already have. [behind] is only composed while a swipe is under way.
 */
@Composable
fun InteractiveBackLayer(
    onBack: () -> Unit,
    behind: @Composable () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    val progress = remember { Animatable(0f) }
    var swiping by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val latestOnBack by rememberUpdatedState(onBack)
    val background = MaterialTheme.colorScheme.background

    PlatformPredictiveBackHandler(enabled = enabled) { events ->
        try {
            swiping = true
            events.collect { progress.snapTo(it.coerceIn(0f, 1f)) }
            // Committed: finish the slide, then hand over to the page underneath in the same frame.
            progress.animateTo(1f, tween(durationMillis = 180, easing = FastOutSlowInEasing))
            latestOnBack()
            progress.snapTo(0f)
            swiping = false
        } catch (cancelled: CancellationException) {
            // Abandoned: spring back (the handler's scope is gone, so use ours).
            scope.launch {
                progress.animateTo(0f, tween(durationMillis = 200, easing = FastOutSlowInEasing))
                swiping = false
            }
            throw cancelled
        }
    }

    Box(modifier.fillMaxSize()) {
        if (swiping) {
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer { translationX = -size.width * 0.3f * (1f - progress.value) },
            ) {
                behind()
                Box(
                    Modifier
                        .fillMaxSize()
                        .graphicsLayer { alpha = 0.18f * (1f - progress.value) }
                        .background(Color.Black),
                )
            }
        }
        Box(
            Modifier
                .fillMaxSize()
                .graphicsLayer { translationX = progress.value * size.width }
                .drawBehind {
                    if (progress.value > 0f) {
                        val w = 14.dp.toPx()
                        drawRect(
                            brush = Brush.horizontalGradient(
                                colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.22f)),
                                startX = -w,
                                endX = 0f,
                            ),
                            topLeft = Offset(-w, 0f),
                            size = Size(w, size.height),
                        )
                    }
                }
                .background(background),
        ) {
            content()
        }
    }
}
