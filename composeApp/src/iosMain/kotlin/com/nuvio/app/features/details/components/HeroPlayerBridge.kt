package com.nuvio.app.features.details.components

import platform.UIKit.UIView

/**
 * A light AVPlayer (AVFoundation) player for trailers, implemented in Swift (HeroAvPlayerBridge.swift).
 *
 * Trailers are muted clips behind artwork, so they use the system's hardware-decoded player instead of the full libmpv
 * engine: far less CPU and battery. AVPlayer only decodes H.264 and HEVC video and AAC audio, which the trailer extractor
 * now prefers on iOS; when a clip cannot be played here the surface falls back to the libmpv preview.
 */
interface HeroPlayerBridge {
    /** The view holding the AVPlayerLayer. */
    fun createView(): UIView

    /** Stops playback and releases everything. Call when the composable leaves the composition. */
    fun releasePlayer()

    /** True once the first frame can be shown. */
    fun isReady(): Boolean

    /** True when the stream could not be played. */
    fun isFailed(): Boolean

    fun isEnded(): Boolean

    fun setMuted(muted: Boolean)

    fun setPlaying(playing: Boolean)

    fun getPositionMs(): Long

    fun seekToMs(positionMs: Long)
}

interface HeroPlayerBridgeCreator {
    fun create(videoUrl: String, audioUrl: String?): HeroPlayerBridge
}

/** Swift registers the creator at startup, before Compose runs. */
object HeroPlayerBridgeFactory {
    private var creator: HeroPlayerBridgeCreator? = null

    fun registerFactory(creator: HeroPlayerBridgeCreator) {
        this.creator = creator
    }

    val isRegistered: Boolean get() = creator != null

    fun create(videoUrl: String, audioUrl: String?): HeroPlayerBridge? = creator?.create(videoUrl = videoUrl, audioUrl = audioUrl)
}
