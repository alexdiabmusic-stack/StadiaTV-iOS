package com.nuvio.app

import platform.UIKit.UIDevice

class IOSPlatform: Platform {
    override val name: String = UIDevice.currentDevice.systemName() + " " + UIDevice.currentDevice.systemVersion
}

actual fun getPlatform(): Platform = IOSPlatform()

internal actual val isIos: Boolean = true

@OptIn(kotlin.experimental.ExperimentalNativeApi::class)
internal actual val isDebugBuild: Boolean = kotlin.native.Platform.isDebugBinary

internal actual val supportsPosterNavigationMotion: Boolean = false
