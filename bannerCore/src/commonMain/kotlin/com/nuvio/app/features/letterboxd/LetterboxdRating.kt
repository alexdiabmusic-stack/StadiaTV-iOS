package com.nuvio.app.features.letterboxd

import kotlin.math.roundToInt

/** Half-star ratings: Letterboxd's 0.5 to 5.0, and the 1 to 10 scale the site's rate action takes. */
object LetterboxdRating {
    /** Unrated, then 0.5 up to 5.0. */
    val choices: List<Double?> = listOf<Double?>(null) + (1..10).map { it / 2.0 }

    fun isValid(stars: Double?): Boolean = stars == null || (stars in 0.5..5.0 && (stars * 2).let { it == it.toInt().toDouble() })

    /** The nearest valid half star, or null for anything unrated or out of range. */
    fun snap(stars: Double?): Double? {
        if (stars == null || stars <= 0.0) return null
        return ((stars * 2).let { kotlin.math.floor(it + 0.5) } / 2.0).coerceIn(0.5, 5.0)
    }

    /** Half-stars to the rate action's 0-10 integer (1 to 10): 0.5 stars is 1, 4.5 is 9, 5.0 is 10. */
    fun toSiteScale(stars: Double): Int = (kotlin.math.floor(stars * 2 + 0.5).toInt()).coerceIn(1, 10)

    fun fromSiteScale(value: Int): Double? = if (value in 1..10) value / 2.0 else null

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

    internal fun percent(stars: Double): Int = (stars * 20).roundToInt()
}

/** Calendar dates as "yyyy-MM-dd" strings, with the few operations the diary rules need. */
object LetterboxdDates {
    fun format(year: Int, month: Int, day: Int): String =
        year.toString().padStart(4, '0') + "-" + month.toString().padStart(2, '0') + "-" + day.toString().padStart(2, '0')

    /** Days since 1970-01-01 (the civil-date algorithm), or null when [iso] is not a date. */
    fun epochDay(iso: String): Long? {
        val p = iso.take(10).split("-").mapNotNull { it.toIntOrNull() }
        if (p.size != 3) return null
        val (y0, m, d) = p
        if (m !in 1..12 || d !in 1..31) return null
        val y = if (m <= 2) y0 - 1 else y0
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val doy = (153 * (m + (if (m > 2) -3 else 9)) + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era.toLong() * 146097 + doe - 719468
    }

    fun daysBetween(from: String, to: String): Long? {
        val a = epochDay(from) ?: return null
        val b = epochDay(to) ?: return null
        return b - a
    }

    private val MONTHS = listOf("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")

    fun monthNumber(name: String): Int? = MONTHS.indexOf(name.trim().lowercase().take(3)).takeIf { it >= 0 }?.plus(1)

    /**
     * Only a prior diary entry more than a day before the viewing makes it a rewatch (Jellyscribe's Helpers.IsRewatch):
     * a second entry the same or the next day is the same sitting.
     */
    fun isRewatch(lastDiaryDate: String?, viewingDate: String): Boolean {
        if (lastDiaryDate == null) return false
        return (daysBetween(lastDiaryDate, viewingDate) ?: return false) > 1
    }
}
