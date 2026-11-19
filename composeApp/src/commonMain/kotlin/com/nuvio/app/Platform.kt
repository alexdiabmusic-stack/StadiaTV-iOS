package com.nuvio.app

interface Platform {
    val name: String
}

expect fun getPlatform(): Platform

internal expect val isIos: Boolean

/** True in development (debug) builds; gates diagnostics that must never appear in a release build. */
internal expect val isDebugBuild: Boolean

internal expect val supportsPosterNavigationMotion: Boolean
