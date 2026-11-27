package com.nuvio.app.core.logging

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal fun platformInAppLogTimestamp(): String =
    SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())
