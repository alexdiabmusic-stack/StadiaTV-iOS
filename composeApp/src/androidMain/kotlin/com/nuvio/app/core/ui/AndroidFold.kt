package com.nuvio.app.core.ui

import android.app.Activity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalDensity
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker

/**
 * The hinge of a foldable held half open like a laptop (tabletop posture: a horizontal fold with the screen bent
 * towards you), the same cue the iPhone Duo gives. The player then keeps the picture on the upper half and puts its
 * controls on the lower half, like Netflix does. Null on a phone, on a foldable that is flat or closed, and when the
 * fold runs vertically (book posture).
 */
@Composable
internal fun rememberAndroidFold(activity: Activity): Fold? {
    val density = LocalDensity.current
    val layouts = remember(activity) { WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity) }
    val info by layouts.collectAsState(initial = null)
    val feature = info?.displayFeatures?.filterIsInstance<FoldingFeature>()?.firstOrNull {
        it.state == FoldingFeature.State.HALF_OPENED && it.orientation == FoldingFeature.Orientation.HORIZONTAL
    } ?: return null
    return with(density) { Fold(top = feature.bounds.top.toDp(), bottom = feature.bounds.bottom.toDp()) }
}
