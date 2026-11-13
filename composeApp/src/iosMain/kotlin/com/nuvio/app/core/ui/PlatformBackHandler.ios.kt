package com.nuvio.app.core.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.backhandler.BackHandler

/**
 * Compose's own iOS back gesture: a swipe in from the left edge calls [onBack] while [enabled]. It sits beside the
 * system navigation controller's swipe, which still handles real screens (a show's page); this covers the pages that are
 * swapped inside one screen, like Search's Genres or Sports' Pick Your Teams.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
actual fun PlatformBackHandler(
    enabled: Boolean,
    onBack: () -> Unit,
) {
    BackHandler(enabled = enabled, onBack = onBack)
}
