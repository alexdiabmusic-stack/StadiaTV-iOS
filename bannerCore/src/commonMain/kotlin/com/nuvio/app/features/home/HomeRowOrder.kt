package com.nuvio.app.features.home

/**
 * The order of the Home rows below Continue Watching, chosen by the user and synced with the profile (the `row_order`
 * list in the shared home-catalog settings, read by iOS, Android and the TV app alike).
 *
 * Rows are identified by a stable id (see [HomeRowIds]). The saved list is the order the user last saw on some device;
 * it can mention rows this device doesn't have (a TV-only row) and miss rows this device has (a row added since), so
 * applying it never drops or invents a row: rows the list doesn't mention stay where the default order put them.
 */
object HomeRowOrder {
    /** The key in the shared settings blob. */
    const val SYNC_KEY = "row_order"

    /**
     * [rows] in the user's order. Rows named in [saved] follow its order; any other row keeps its place relative to
     * the row that precedes it by default (or stays first when nothing precedes it).
     */
    fun <T> apply(rows: List<T>, saved: List<String>, keyOf: (T) -> String): List<T> {
        if (saved.isEmpty() || rows.size < 2) return rows
        val byKey = rows.associateBy(keyOf)
        val out = ArrayList<String>(rows.size)
        saved.distinct().forEach { if (it in byKey) out += it }
        if (out.isEmpty()) return rows
        val placed = out.toHashSet()
        rows.forEachIndexed { i, row ->
            val key = keyOf(row)
            if (key in placed) return@forEachIndexed
            // After the nearest earlier default row already in the list, else at the start.
            val before = rows.subList(0, i).map(keyOf).lastOrNull { it in placed }
            out.add(if (before == null) 0 else out.indexOf(before) + 1, key)
            placed += key
        }
        return out.map { byKey.getValue(it) }
    }

    /** [order] with [key] moved by [delta] places (negative is up), clamped to the ends. */
    fun moved(order: List<String>, key: String, delta: Int): List<String> {
        val from = order.indexOf(key)
        if (from < 0 || delta == 0) return order
        val to = (from + delta).coerceIn(0, order.lastIndex)
        if (to == from) return order
        return order.toMutableList().also { it.add(to, it.removeAt(from)) }
    }

    /**
     * What to save after the user arranged the rows they can see ([visible], in the new order): the visible rows in
     * that order, with every row only another device knows kept just after the row it followed in [saved].
     */
    fun toSave(saved: List<String>, visible: List<String>): List<String> {
        val shown = visible.distinct()
        val out = shown.toMutableList()
        val known = shown.toHashSet()
        saved.forEachIndexed { i, key ->
            if (key in known) return@forEachIndexed
            val before = saved.subList(0, i).lastOrNull { it in out }
            out.add(if (before == null) 0 else out.indexOf(before) + 1, key)
        }
        return out
    }
}

/** Row ids shared by every app, so one profile's order means the same thing everywhere. */
object HomeRowIds {
    const val TOP10 = "top10"
    const val TOP10_MOVIES = "top10:movies"
    const val TOP10_SHOWS = "top10:shows"
    const val RECOMMENDED = "recommended"
    const val EXPLORE = "explore"
    const val COMING_TO_DIGITAL = "coming"

    fun curated(key: String) = "curated:$key"
    fun personal(kind: String) = "personal:$kind"

    /** An add-on catalog or collection, by the key the catalog settings already give it. */
    fun catalog(settingsKey: String) = "cat:$settingsKey"
}
