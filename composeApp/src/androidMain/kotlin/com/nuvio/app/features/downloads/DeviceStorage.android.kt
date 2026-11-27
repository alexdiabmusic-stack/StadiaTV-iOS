package com.nuvio.app.features.downloads

import android.os.Environment
import android.os.StatFs

internal actual object DeviceStorage {
    actual fun freeBytes(): Long? = runCatching {
        StatFs(Environment.getDataDirectory().path).availableBytes
    }.getOrNull()
}
