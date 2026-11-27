package com.nuvio.app.features.downloads

/** How much room the device has left for downloads. Null when the platform will not say. */
internal expect object DeviceStorage {
    fun freeBytes(): Long?
}
