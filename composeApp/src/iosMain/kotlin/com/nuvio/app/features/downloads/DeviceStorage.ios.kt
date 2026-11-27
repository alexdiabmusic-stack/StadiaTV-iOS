package com.nuvio.app.features.downloads

import kotlinx.cinterop.ExperimentalForeignApi
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileSystemFreeSize
import platform.Foundation.NSHomeDirectory
import platform.Foundation.NSNumber

@OptIn(ExperimentalForeignApi::class)
internal actual object DeviceStorage {
    actual fun freeBytes(): Long? {
        val attributes = NSFileManager.defaultManager.attributesOfFileSystemForPath(NSHomeDirectory(), null) ?: return null
        return (attributes[NSFileSystemFreeSize] as? NSNumber)?.longLongValue
    }
}
