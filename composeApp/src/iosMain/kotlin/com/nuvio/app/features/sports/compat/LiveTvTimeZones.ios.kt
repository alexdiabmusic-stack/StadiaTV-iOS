package com.nuvio.app.features.sports.compat

import platform.Foundation.NSDate
import platform.Foundation.NSTimeZone
import platform.Foundation.dateWithTimeIntervalSince1970
import platform.Foundation.knownTimeZoneNames
import platform.Foundation.systemTimeZone
import platform.Foundation.timeZoneWithName

object IosLiveTvTimeZones : LiveTvTimeZonesBackend {
    override fun isKnown(zoneId: String): Boolean =
        zoneId == LiveTvTimeZones.SYSTEM || zoneId.equals("UTC", ignoreCase = true) ||
            NSTimeZone.knownTimeZoneNames.any { it == zoneId } || NSTimeZone.timeZoneWithName(zoneId) != null

    override fun offsetMs(zone: String, epochMs: Long): Long {
        val tz = when {
            zone == LiveTvTimeZones.SYSTEM -> NSTimeZone.systemTimeZone
            else -> NSTimeZone.timeZoneWithName(zone) ?: return 0L
        }
        val date = NSDate.dateWithTimeIntervalSince1970(epochMs / 1000.0)
        return tz.secondsFromGMTForDate(date) * 1000L
    }
}
