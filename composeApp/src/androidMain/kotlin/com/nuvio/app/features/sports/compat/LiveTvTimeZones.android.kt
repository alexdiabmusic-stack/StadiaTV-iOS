package com.nuvio.app.features.sports.compat

import java.util.TimeZone

object AndroidLiveTvTimeZones : LiveTvTimeZonesBackend {
    override fun isKnown(zoneId: String): Boolean =
        zoneId == LiveTvTimeZones.SYSTEM || zoneId.equals("UTC", ignoreCase = true) || TimeZone.getAvailableIDs().contains(zoneId)

    override fun offsetMs(zone: String, epochMs: Long): Long {
        val tz = when {
            zone == LiveTvTimeZones.SYSTEM -> TimeZone.getDefault()
            isKnown(zone) -> TimeZone.getTimeZone(zone)
            else -> return 0L
        }
        return tz.getOffset(epochMs).toLong()
    }
}
