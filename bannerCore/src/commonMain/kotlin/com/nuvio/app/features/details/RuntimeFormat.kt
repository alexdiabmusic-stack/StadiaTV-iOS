package com.nuvio.app.features.details

import kotlinx.coroutines.runBlocking
import com.nuvio.app.core.text.CoreStrings
import com.nuvio.app.core.text.CoreText

private val hourTokenRegex = Regex("""(?i)(\d+)\s*h(?:ours?)?""")
private val minuteTokenRegex = Regex("""(?i)(\d+)\s*m(?:in(?:ute)?s?)?""")
private val hourMinuteColonRegex = Regex("""^\s*(\d+)\s*:\s*(\d{1,2})\s*$""")
private val digitsOnlyRegex = Regex("""^\s*(\d+)\s*$""")

fun formatRuntimeForDisplay(rawRuntime: String?): String? {
    val normalized = rawRuntime?.trim()?.takeIf { it.isNotBlank() } ?: return null
    val totalMinutes = parseRuntimeMinutes(normalized) ?: return normalized
    return formatRuntimeFromMinutes(totalMinutes)
}

fun formatRuntimeFromMinutes(totalMinutes: Int): String {
    if (totalMinutes <= 0) return ""
    val hours = totalMinutes / 60
    val minutes = totalMinutes % 60

    return runBlocking {
        when {
            hours > 0 && minutes > 0 -> CoreText.get(CoreStrings.detailsRuntimeHoursMinutes, hours, minutes)
            hours > 0 -> CoreText.get(CoreStrings.detailsRuntimeHoursOnly, hours)
            else -> CoreText.get(CoreStrings.detailsRuntimeMinutesOnly, minutes)
        }
    }
}

fun parseRuntimeMinutes(rawRuntime: String?): Int? {
    val value = rawRuntime?.trim()?.takeIf(String::isNotBlank) ?: return null
    hourMinuteColonRegex.matchEntire(value)?.let { match ->
        val hours = match.groupValues[1].toIntOrNull() ?: return null
        val minutes = match.groupValues[2].toIntOrNull() ?: return null
        return (hours * 60) + minutes
    }

    val hoursToken = hourTokenRegex.find(value)?.groupValues?.getOrNull(1)?.toIntOrNull()
    val minutesToken = minuteTokenRegex.find(value)?.groupValues?.getOrNull(1)?.toIntOrNull()
    if (hoursToken != null || minutesToken != null) {
        val hours = (hoursToken ?: 0).coerceAtLeast(0)
        val minutes = (minutesToken ?: 0).coerceAtLeast(0)
        return (hours * 60) + minutes
    }

    digitsOnlyRegex.matchEntire(value)?.let { match ->
        return match.groupValues[1].toIntOrNull()?.coerceAtLeast(0)
    }

    return null
}
