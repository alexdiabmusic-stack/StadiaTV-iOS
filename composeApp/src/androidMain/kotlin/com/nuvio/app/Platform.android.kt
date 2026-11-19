package com.nuvio.app

import android.os.Build

class AndroidPlatform : Platform {
    override val name: String = "Android ${Build.VERSION.SDK_INT}"
}

actual fun getPlatform(): Platform = AndroidPlatform()

internal actual val isIos: Boolean = false

// Recommendation diagnostics are an iPhone development tool; Android builds don't collect them.
internal actual val isDebugBuild: Boolean = false

internal actual val supportsPosterNavigationMotion: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
