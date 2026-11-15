package com.nuvio.app.core.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.backhandler.PredictiveBackHandler
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

@OptIn(ExperimentalComposeUiApi::class)
@Composable
actual fun PlatformPredictiveBackHandler(
    enabled: Boolean,
    onBack: suspend (progress: Flow<Float>) -> Unit,
) {
    PredictiveBackHandler(enabled = enabled) { events -> onBack(events.map { it.progress }) }
}
