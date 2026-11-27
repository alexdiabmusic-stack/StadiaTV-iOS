package com.nuvio.app.features.details.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.interop.UIKitView
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.interop.UIKitViewController
import co.touchlab.kermit.Logger
import com.nuvio.app.features.player.NuvioPlayerBridgeFactory
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

private const val HERO_TRAILER_IOS_TAG = "HeroTrailerIos"

@OptIn(ExperimentalForeignApi::class)
@Composable
private fun MpvHeroTrailerSurface(
    sourceUrl: String,
    sourceAudioUrl: String?,
    playWhenReady: Boolean,
    muted: Boolean,
    modifier: Modifier,
    startPositionMs: Long,
    onReady: () -> Unit,
    onEnded: () -> Unit,
    onError: () -> Unit,
    onPositionUpdate: (Long) -> Unit,
) {
    val latestOnReady = rememberUpdatedState(onReady)
    val latestOnEnded = rememberUpdatedState(onEnded)
    val latestOnError = rememberUpdatedState(onError)
    val latestOnPositionUpdate = rememberUpdatedState(onPositionUpdate)
    val bridge = remember { NuvioPlayerBridgeFactory.create() }

    if (bridge == null) {
        LaunchedEffect(Unit) { latestOnError.value() }
        return
    }

    LaunchedEffect(bridge, sourceUrl, sourceAudioUrl) {
        runCatching {
            bridge.setEmbeddedPreviewMode(true)
            bridge.setResizeMode(2) // Zoom: crop to fill, keep aspect ratio
            bridge.setMuted(muted)
            bridge.loadFileWithAudio(
                videoUrl = sourceUrl,
                audioUrl = sourceAudioUrl,
                headersJson = null,
                subtitlesJson = null,
            )
            if (playWhenReady) bridge.play() else bridge.pause()
        }.onFailure { error ->
            Logger.w(HERO_TRAILER_IOS_TAG, error) { "Failed to load iOS hero trailer preview" }
            latestOnError.value()
        }
    }

    LaunchedEffect(bridge, playWhenReady) {
        runCatching {
            if (playWhenReady) bridge.play() else bridge.pause()
        }.onFailure { error ->
            Logger.w(HERO_TRAILER_IOS_TAG, error) { "Failed to update iOS hero trailer playback state" }
            latestOnError.value()
        }
    }

    LaunchedEffect(bridge, muted) {
        runCatching { bridge.setMuted(muted) }
            .onFailure { error ->
                Logger.w(HERO_TRAILER_IOS_TAG, error) { "Failed to update iOS hero trailer mute state" }
            }
    }

    LaunchedEffect(bridge, sourceUrl, sourceAudioUrl) {
        var readyReported = false
        var lastErrorMessage: String? = null
        while (isActive) {
            val errorMessage = runCatching { bridge.getErrorMessage().ifBlank { null } }.getOrNull()
            if (errorMessage != null && errorMessage != lastErrorMessage) {
                lastErrorMessage = errorMessage
                latestOnError.value()
                return@LaunchedEffect
            }

            if (!readyReported) {
                val hasVideo = runCatching {
                    bridge.getVideoWidth() > 0 && bridge.getVideoHeight() > 0
                }.getOrDefault(false)
                val isPlaying = runCatching { bridge.getIsPlaying() }.getOrDefault(false)
                if (hasVideo || isPlaying) {
                    readyReported = true
                    // Only safe to seek once the file is actually loaded — seeking right after
                    // loadFileWithAudio() is issued is silently ignored since nothing is ready yet.
                    if (startPositionMs > 0L) {
                        runCatching { bridge.seekTo(startPositionMs) }
                    }
                    latestOnReady.value()
                }
            }

            if (runCatching { bridge.getIsEnded() }.getOrDefault(false)) {
                latestOnEnded.value()
                return@LaunchedEffect
            }
            if (readyReported) {
                runCatching { bridge.getPositionMs() }.getOrNull()?.let(latestOnPositionUpdate.value)
            }
            delay(250L)
        }
    }

    DisposableEffect(bridge) {
        onDispose {
            runCatching {
                bridge.pause()
                latestOnPositionUpdate.value(bridge.getPositionMs())
                bridge.destroy()
            }.onFailure { error ->
                Logger.w(HERO_TRAILER_IOS_TAG, error) { "Failed to dispose iOS hero trailer preview" }
            }
        }
    }

    Box(modifier = modifier.background(Color.Black)) {
        UIKitViewController(
            factory = { bridge.createPlayerViewController() },
            modifier = Modifier.fillMaxSize(),
            interactive = false,
        )
    }
}


/**
 * Trailers play in AVPlayer (hardware decode, far lighter than libmpv). If AVPlayer cannot play a clip (a codec it does not
 * decode, a stream that never becomes ready), the same clip is tried once in the libmpv preview, so nothing that played
 * before stops playing.
 */
@OptIn(ExperimentalForeignApi::class)
@Composable
actual fun HeroTrailerPlayerSurface(
    sourceUrl: String,
    sourceAudioUrl: String?,
    playWhenReady: Boolean,
    muted: Boolean,
    modifier: Modifier,
    startPositionMs: Long,
    onReady: () -> Unit,
    onEnded: () -> Unit,
    onError: () -> Unit,
    onPositionUpdate: (Long) -> Unit,
) {
    var avFailed by remember(sourceUrl, sourceAudioUrl) { mutableStateOf(false) }
    if (!avFailed && HeroPlayerBridgeFactory.isRegistered) {
        AvHeroTrailerSurface(
            sourceUrl = sourceUrl, sourceAudioUrl = sourceAudioUrl, playWhenReady = playWhenReady, muted = muted, modifier = modifier,
            startPositionMs = startPositionMs, onReady = onReady, onEnded = onEnded, onError = { avFailed = true }, onPositionUpdate = onPositionUpdate,
        )
    } else {
        MpvHeroTrailerSurface(
            sourceUrl = sourceUrl, sourceAudioUrl = sourceAudioUrl, playWhenReady = playWhenReady, muted = muted, modifier = modifier,
            startPositionMs = startPositionMs, onReady = onReady, onEnded = onEnded, onError = onError, onPositionUpdate = onPositionUpdate,
        )
    }
}

@OptIn(ExperimentalForeignApi::class)
@Composable
private fun AvHeroTrailerSurface(
    sourceUrl: String,
    sourceAudioUrl: String?,
    playWhenReady: Boolean,
    muted: Boolean,
    modifier: Modifier,
    startPositionMs: Long,
    onReady: () -> Unit,
    onEnded: () -> Unit,
    onError: () -> Unit,
    onPositionUpdate: (Long) -> Unit,
) {
    val latestOnReady = rememberUpdatedState(onReady)
    val latestOnEnded = rememberUpdatedState(onEnded)
    val latestOnError = rememberUpdatedState(onError)
    val latestOnPosition = rememberUpdatedState(onPositionUpdate)
    val bridge = remember(sourceUrl, sourceAudioUrl) { HeroPlayerBridgeFactory.create(sourceUrl, sourceAudioUrl) }
    if (bridge == null) {
        LaunchedEffect(Unit) { latestOnError.value() }
        return
    }

    LaunchedEffect(bridge) {
        var elapsedMs = 0L
        var readyReported = false
        // Generous budget: healthy trailers take 5-7 s to become ready on a slow link. After that, hand over to libmpv.
        while (isActive && !readyReported && elapsedMs < 12_000L) {
            delay(100)
            elapsedMs += 100
            when {
                bridge.isReady() -> {
                    readyReported = true
                    if (startPositionMs > 0L) bridge.seekToMs(startPositionMs)
                    latestOnReady.value()
                }
                bridge.isFailed() -> { latestOnError.value(); return@LaunchedEffect }
            }
        }
        if (!readyReported) { latestOnError.value(); return@LaunchedEffect }
        // Position is only needed to resume later: twice a second is plenty, and not at all while paused.
        while (isActive) {
            if (bridge.isEnded()) { latestOnEnded.value(); return@LaunchedEffect }
            if (bridge.isFailed()) { latestOnError.value(); return@LaunchedEffect }
            latestOnPosition.value(bridge.getPositionMs())
            delay(500)
        }
    }

    LaunchedEffect(bridge, playWhenReady) { bridge.setPlaying(playWhenReady) }

    DisposableEffect(bridge) {
        onDispose {
            runCatching {
                latestOnPosition.value(bridge.getPositionMs())
                bridge.releasePlayer()
            }
        }
    }

    UIKitView(
        modifier = modifier.background(Color.Black),
        factory = { bridge.createView() },
        update = { bridge.setMuted(muted) },
    )
}
