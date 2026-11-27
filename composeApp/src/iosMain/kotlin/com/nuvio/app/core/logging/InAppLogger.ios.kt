package com.nuvio.app.core.logging

import platform.Foundation.NSDate
import platform.Foundation.NSDateFormatter

internal fun platformInAppLogTimestamp(): String {
    val formatter = NSDateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.stringFromDate(NSDate())
}
