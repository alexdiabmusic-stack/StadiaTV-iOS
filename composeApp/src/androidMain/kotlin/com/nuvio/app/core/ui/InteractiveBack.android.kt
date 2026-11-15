package com.nuvio.app.core.ui

import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.runtime.Composable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

@Composable
actual fun PlatformPredictiveBackHandler(
    enabled: Boolean,
    onBack: suspend (progress: Flow<Float>) -> Unit,
) {
    PredictiveBackHandler(enabled = enabled) { events -> onBack(events.map { it.progress }) }
}
