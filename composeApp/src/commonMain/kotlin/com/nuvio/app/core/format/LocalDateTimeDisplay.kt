package com.nuvio.app.core.format

expect fun formatLocalDateTime(epochMs: Long): String

expect fun formatLocalTime(epochMs: Long): String

/** The device's offset from UTC at [epochMs], in milliseconds (for wording a time as "today at 2:59 PM"). */
expect fun localUtcOffsetMs(epochMs: Long): Long
