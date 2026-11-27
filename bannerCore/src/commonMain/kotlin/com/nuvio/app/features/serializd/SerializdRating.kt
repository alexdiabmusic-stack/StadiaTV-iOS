package com.nuvio.app.features.serializd

import kotlin.math.floor

/**
 * Half-star ratings, as the member sees them (0.5 to 5.0), and Serializd's integers 1 to 10 (10 is five stars).
 * `serializdRating = round(stars * 2)`, clamped to 1..10, and 0 means unrated: a missing rating is never sent as a real one.
 */
object SerializdRating {
    /** Unrated, then 0.5 up to 5.0. */
    val choices: List<Double?> = listOf<Double?>(null) + (1..10).map { it / 2.0 }

    /** The nearest valid half star, or null for anything unrated or out of range. */
    fun snap(stars: Double?): Double? {
        if (stars == null || stars <= 0.0) return null
        return (floor(stars * 2 + 0.5) / 2.0).coerceIn(0.5, 5.0)
    }

    /** What goes in the `rating` field: 1 to 10, or 0 for unrated. */
    fun toSerializd(stars: Double?): Int = snap(stars)?.let { floor(it * 2 + 0.5).toInt().coerceIn(1, 10) } ?: 0

    /** Serializd's value back to stars. 0, null and anything outside 1..10 are unrated. */
    fun fromSerializd(value: Int?): Double? = if (value != null && value in 1..10) value / 2.0 else null

    /** "4.5" or "4" for display. */
    fun label(stars: Double?): String = when {
        stars == null -> "Unrated"
        stars == stars.toInt().toDouble() -> stars.toInt().toString()
        else -> stars.toString()
    }

    /** Whole and half stars for drawing: (full, half, empty) out of five. */
    fun glyphs(stars: Double?): Triple<Int, Int, Int> {
        val s = snap(stars) ?: return Triple(0, 0, 5)
        val full = s.toInt()
        val half = if (s - full >= 0.5) 1 else 0
        return Triple(full, half, 5 - full - half)
    }
}

/** Calendar and clock arithmetic for the diary: ISO-8601 in and out, the civil date of a moment, no platform clock classes. */
object SerializdDates {
    private const val DAY_MS = 86_400_000L

    /** "2026-11-23T02:00:00Z" for an epoch-millisecond moment, in UTC, whole seconds: the `backdate` format Serializd takes. */
    fun isoUtc(ms: Long): String {
        val days = ms.floorDiv(DAY_MS)
        val rem = ms - days * DAY_MS
        val (y, m, d) = civil(days)
        val h = (rem / 3_600_000L).toInt(); val mi = ((rem % 3_600_000L) / 60_000L).toInt(); val s = ((rem % 60_000L) / 1_000L).toInt()
        return "${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}T${pad(h, 2)}:${pad(mi, 2)}:${pad(s, 2)}Z"
    }

    /** "yyyy-MM-dd" of the UTC day. */
    fun utcDate(ms: Long): String = isoUtc(ms).substring(0, 10)

    /** A parsed moment, and whether the text carried a time of day. */
    data class Parsed(val ms: Long, val dateOnly: Boolean)

    /**
     * Reads "yyyy-MM-dd", "yyyy-MM-ddTHH:mm:ss", with optional fraction and a "Z" or "+hh:mm" offset. No offset means UTC. Anything
     * else is null, never a guess.
     */
    fun parse(text: String?): Parsed? {
        val t = text?.trim().orEmpty()
        if (t.length < 10) return null
        val y = t.substring(0, 4).toIntOrNull() ?: return null
        if (t[4] != '-' || t[7] != '-') return null
        val mo = t.substring(5, 7).toIntOrNull() ?: return null
        val d = t.substring(8, 10).toIntOrNull() ?: return null
        if (mo !in 1..12 || d !in 1..31) return null
        val day = epochDay(y, mo, d)
        if (t.length == 10) return Parsed(day * DAY_MS, true)
        if (t[10] != 'T' && t[10] != ' ') return null
        val rest = t.substring(11)
        if (rest.length < 5 || rest[2] != ':') return null
        val h = rest.substring(0, 2).toIntOrNull() ?: return null
        val mi = rest.substring(3, 5).toIntOrNull() ?: return null
        var idx = 5
        var s = 0
        if (rest.length >= 8 && rest[5] == ':') { s = rest.substring(6, 8).toIntOrNull() ?: return null; idx = 8 }
        var millis = 0
        if (idx < rest.length && rest[idx] == '.') {
            var j = idx + 1
            while (j < rest.length && rest[j].isDigit()) j++
            val frac = rest.substring(idx + 1, j).take(3).padEnd(3, '0')
            millis = frac.toIntOrNull() ?: 0
            idx = j
        }
        var offsetMs = 0L
        if (idx < rest.length) {
            val tz = rest.substring(idx)
            when {
                tz == "Z" || tz == "z" -> Unit
                (tz[0] == '+' || tz[0] == '-') && tz.length >= 3 -> {
                    val oh = tz.substring(1, 3).toIntOrNull() ?: return null
                    val om = tz.removePrefix(tz.substring(0, 3)).removePrefix(":").take(2).toIntOrNull() ?: 0
                    offsetMs = (oh * 60L + om) * 60_000L * (if (tz[0] == '-') -1 else 1)
                }
                else -> return null
            }
        }
        if (h !in 0..23 || mi !in 0..59 || s !in 0..60) return null
        return Parsed(day * DAY_MS + h * 3_600_000L + mi * 60_000L + s * 1_000L + millis - offsetMs, false)
    }

    private fun pad(v: Int, w: Int) = v.toString().padStart(w, '0')

    /** Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm). */
    fun epochDay(year: Int, month: Int, day: Int): Long {
        val y = if (month <= 2) year - 1 else year
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val doy = (153 * (month + (if (month > 2) -3 else 9)) + 2) / 5 + day - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era.toLong() * 146097 + doe - 719468
    }

    private fun civil(epochDay: Long): Triple<Int, Int, Int> {
        val z = epochDay + 719468
        val era = z.floorDiv(146097L)
        val doe = z - era * 146097
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val d = (doy - (153 * mp + 2) / 5 + 1).toInt()
        val m = (if (mp < 10) mp + 3 else mp - 9).toInt()
        val y = (yoe + era * 400 + if (m <= 2) 1 else 0).toInt()
        return Triple(y, m, d)
    }
}
