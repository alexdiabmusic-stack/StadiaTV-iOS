package com.nuvio.app.core.ui

import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

data class Fold(val top: Dp, val bottom: Dp)

val LocalFold = compositionLocalOf<Fold?> { null }

/**
 * iPhone Duo cover screen held sideways: the camera sits in a band along the top (or, turned the other way, the
 * bottom) edge. [top]/[bottom] is the band's thickness on that edge, [cameraStart]/[cameraEnd] the width of the corner
 * the camera itself takes up inside the band. The rest of the screen is almost exactly 16:9.
 */
data class CameraBand(
    val top: Dp = 0.dp,
    val bottom: Dp = 0.dp,
    val cameraStart: Dp = 0.dp,
    val cameraEnd: Dp = 0.dp,
)

/** Null everywhere except the iPhone Duo's cover screen in landscape. */
val LocalCameraBand = compositionLocalOf<CameraBand?> { null }
