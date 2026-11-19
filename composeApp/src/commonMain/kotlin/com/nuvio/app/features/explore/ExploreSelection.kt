package com.nuvio.app.features.explore

import com.nuvio.app.features.recommendations.TasteProfile

/**
 * Which collections the Home rail shows, and in what order. It weighs editorial priority, how well a collection suits
 * the profile's favourite genres and whether it is in season (Christmas Classics in December), keeps the categories
 * varied, and adds a small per-week variation. The same profile sees the same order all week, so Home stays
 * predictable; the order moves on the next week, or sooner only if the profile's top genres change.
 */
object ExploreSelection {
    const val HOME_COUNT = 10
    private const val MAX_PER_CATEGORY = 2
    private const val MAX_FEATURED = 7

    /**
     * @param month 1-12, for seasonal collections.
     * @param week Days since the epoch divided by seven; the variation is fixed within a week.
     */
    fun forHome(taste: TasteProfile, month: Int, week: Long, catalog: List<ExploreCollection> = ExploreCatalog.all): List<ExploreCollection> {
        val candidates = catalog.filter { c ->
            c.published && (c.sections.isNotEmpty() || c.children.isNotEmpty() || c.episodes != null)
        }.filter { c ->
            val inSeason = c.months.isEmpty() || month in c.months
            // The rail is featured collections, the strongest universes, and whatever is in season right now.
            inSeason && (c.featured || (c.category == CollectionCategory.Universes && c.priority >= 5) || (c.months.isNotEmpty() && month in c.months))
        }
        val scored = candidates.map { c -> c to score(c, taste, month, week) }.sortedByDescending { it.second }
        val picked = ArrayList<ExploreCollection>()
        val perCategory = HashMap<CollectionCategory, Int>()
        for ((c, _) in scored) {
            if (picked.size >= HOME_COUNT) break
            val cap = if (c.category == CollectionCategory.Featured) MAX_FEATURED else MAX_PER_CATEGORY
            val count = perCategory[c.category] ?: 0
            if (count >= cap) continue
            // A universe already reachable through a picked featured collection isn't shown twice in a row of ten.
            if (picked.any { c.id in it.children }) continue
            perCategory[c.category] = count + 1
            picked += c
        }
        return picked
    }

    /** [forHome] for today's date. */
    fun forHomeToday(taste: TasteProfile): List<ExploreCollection> {
        val (month, week) = monthAndWeek(com.nuvio.app.features.watchprogress.CurrentDateProvider.todayIsoDate())
        return forHome(taste, month, week)
    }

    /** Month (1-12) and week number (days since 1970-01-01, divided by seven) of an ISO date. */
    internal fun monthAndWeek(isoDate: String): Pair<Int, Long> {
        val parts = isoDate.take(10).split("-").mapNotNull { it.toIntOrNull() }
        if (parts.size < 3) return 1 to 0L
        val (y0, m, d) = parts
        // Days from civil date (Howard Hinnant's algorithm).
        val y = if (m <= 2) y0 - 1 else y0
        val era = (if (y >= 0) y else y - 399) / 400
        val yoe = y - era * 400
        val doy = (153 * (m + (if (m > 2) -3 else 9)) + 2) / 5 + d - 1
        val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        val days = era.toLong() * 146097 + doe - 719468
        return m to days.floorDiv(7L)
    }

    internal fun score(c: ExploreCollection, taste: TasteProfile, month: Int, week: Long): Double {
        val editorial = c.priority / 10.0
        val affinity = if (c.affinity.isEmpty() || taste.genres.isEmpty()) 0.0
        else c.affinity.maxOf { taste.genres[it] ?: 0.0 }
        val seasonal = if (c.months.isNotEmpty() && month in c.months) 1.5 else 0.0
        return editorial + 1.2 * affinity + seasonal + jitter(c.id, week)
    }

    /** A stable pseudo-random value in [0, 0.45) for this collection this week. */
    internal fun jitter(id: String, week: Long): Double {
        var h = 1125899906842597L xor week
        id.forEach { h = 31 * h + it.code }
        h = h xor (h ushr 33)
        h *= -0xae502812aa7333L
        h = h xor (h ushr 33)
        return ((h ushr 11).toDouble() / (1L shl 53).toDouble()) * 0.45
    }
}
