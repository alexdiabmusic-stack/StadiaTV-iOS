package com.nuvio.app.features.smartdownloads

/** Calendar dates from epoch milliseconds without a date library, so "has it aired yet" is one tested rule. */
object ReleaseDates {
    /** The UTC date of [epochMs] as yyyy-MM-dd. */
    fun isoDateUtc(epochMs: Long): String {
        val days = epochMs.floorDiv(86_400_000L)
        // Howard Hinnant's civil-from-days.
        val z = days + 719_468L
        val era = z.floorDiv(146_097L)
        val doe = z - era * 146_097L
        val yoe = (doe - doe / 1_460L + doe / 36_524L - doe / 146_096L) / 365L
        val y = yoe + era * 400L
        val doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
        val mp = (5L * doy + 2L) / 153L
        val d = doy - (153L * mp + 2L) / 5L + 1L
        val m = if (mp < 10L) mp + 3L else mp - 9L
        val year = if (m <= 2L) y + 1L else y
        return "${year.toString().padStart(4, '0')}-${m.toString().padStart(2, '0')}-${d.toString().padStart(2, '0')}"
    }

    /**
     * Whether an episode with this release date can be fetched now. A date that is missing or unreadable falls back to the
     * source's own availability flag; a date in the future is never available.
     */
    fun hasAired(released: String?, sourceSaysAvailable: Boolean, nowMs: Long): Boolean {
        val date = released?.trim()?.take(10)?.takeIf { it.length == 10 && it[4] == '-' && it[7] == '-' && it.filterNot { c -> c == '-' }.all(Char::isDigit) }
            ?: return sourceSaysAvailable
        return date <= isoDateUtc(nowMs) && sourceSaysAvailable
    }
}
