package com.nuvio.app.features.home

import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * The extra titles Home's TMDB rows have loaded as they were scrolled (or refilled after watched titles were hidden), so a
 * row never simply ends. [HomeTrendingRepository.loadMore] does the paging; this remembers what it returned for each row.
 */
internal class EndlessRows(private val scope: CoroutineScope) {
    private val extra = mutableStateMapOf<String, List<MetaPreview>>()
    private val exhausted = HashSet<String>()
    private val loading = HashSet<String>()

    fun isExhausted(key: String) = key in exhausted

    /** The row's own titles followed by everything loaded for it so far. */
    fun items(key: String, base: List<MetaPreview>): List<MetaPreview> {
        val more = extra[key]
        return if (more.isNullOrEmpty()) base else (base + more).distinctBy { it.id }
    }

    /** Loads one more batch for the row; false when there was nothing more (the row is finished) or one is already loading. */
    suspend fun loadOnce(key: String, base: List<MetaPreview>, shownIds: Set<String>): Boolean {
        if (key in exhausted || !loading.add(key)) return false
        try {
            val all = items(key, base)
            val more = runCatching { HomeTrendingRepository.loadMore(key, all, shownIds) }.getOrDefault(emptyList())
            val fresh = more.filter { m -> all.none { it.id == m.id } }
            if (fresh.isEmpty()) { exhausted += key; return false }
            extra[key] = (extra[key].orEmpty() + fresh).distinctBy { it.id }
            return true
        } finally {
            loading -= key
        }
    }

    /** Fire-and-forget [loadOnce], for a row that has been scrolled to its end. */
    fun more(key: String, base: List<MetaPreview>, shownIds: Set<String>) {
        scope.launch { loadOnce(key, base, shownIds) }
    }
}
