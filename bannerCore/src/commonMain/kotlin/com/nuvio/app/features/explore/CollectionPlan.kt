package com.nuvio.app.features.explore

import com.nuvio.app.features.explore.ExploreResolver.allItems
import com.nuvio.app.features.home.MetaPreview

/** One row of a collection page, in order. The screen draws each kind; what appears, and in what order, is decided here. */
sealed interface PlanRow {
    val key: String

    data object Hero : PlanRow { override val key = "hero" }

    /** "You've watched 3 of 20", for a franchise. */
    data object Progress : PlanRow { override val key = "progress" }

    /** Jump chips for the chapters (sagas, phases) of a long collection. */
    data class Chapters(val chapters: List<CollectionBrowse.Chapter>) : PlanRow { override val key = "chapters" }

    data class ChildrenTitle(val title: String) : PlanRow { override val key = "children-title" }
    data class ChildrenRow(val index: Int, val items: List<ExploreCollection>, val perRow: Int) : PlanRow { override val key = "children-$index" }
    data class ChildrenShelf(val items: List<ExploreCollection>) : PlanRow { override val key = "children-shelf" }

    /** The filter and sort bar. It also pins under the top bar while the grid scrolls. */
    data object Controls : PlanRow { override val key = "controls" }

    /** A chapter or group heading above its titles. [id] is what a chapter chip scrolls to. */
    data class Heading(val text: String, val id: String, val count: Int? = null) : PlanRow { override val key = "body:h:$id" }

    /** One row of the poster grid. */
    data class Posters(val items: List<MetaPreview>, val rowKey: String) : PlanRow { override val key = "body:p:$rowKey" }

    /** A very small collection: its titles larger, not a mostly empty grid. */
    data class Sparse(val items: List<MetaPreview>) : PlanRow { override val key = "body:sparse" }

    data object Skeleton : PlanRow { override val key = "body:skeleton" }
    data object LoadError : PlanRow { override val key = "body:error" }

    /** Filters left nothing. [noun] is "movies", "series" or "titles". */
    data class NoMatches(val noun: String) : PlanRow { override val key = "body:none" }
}

object CollectionPlan {
    private const val ANNOUNCED_ID = "announced"

    /** What a count of titles is called: "Films", "Series" or "Titles", from what the collection really holds. */
    fun noun(items: List<MetaPreview>): String {
        val movies = items.any { it.type == "movie" }
        val series = items.any { it.type == "series" }
        return when { movies && !series -> "movies"; series && !movies -> "series"; else -> "titles" }
    }

    fun build(
        collection: ExploreCollection,
        children: List<ExploreCollection>,
        resolved: ResolvedCollection?,
        /** True once the first load has finished (even if it found nothing). */
        loaded: Boolean,
        filters: BrowseFilters,
        sort: BrowseSort,
        ctx: BrowseContext,
        columns: Int,
        /** Children shown per row when the collection is made of collections. */
        childrenPerRow: Int = 2,
    ): List<PlanRow> = buildList {
        add(PlanRow.Hero)
        val all = resolved?.allItems().orEmpty()
        if (collection.kind == CollectionKind.Franchise && all.isNotEmpty()) add(PlanRow.Progress)

        val sections = resolved?.sections.orEmpty()
        // Chapters only help where the page has several shelves read in order; sorting merges them into one list.
        if (sort == BrowseSort.Curated && sections.count { it.items.isNotEmpty() } >= 2 && filters.isDefault) {
            add(PlanRow.Chapters(CollectionBrowse.chapters(sections)))
        }

        if (children.isNotEmpty() && collection.sections.isEmpty()) {
            // A collection of collections (Movie Universes): its collections are the page.
            add(PlanRow.ChildrenTitle("Collections"))
            children.chunked(childrenPerRow).forEachIndexed { i, row -> add(PlanRow.ChildrenRow(i, row, childrenPerRow)) }
        } else if (children.isNotEmpty()) {
            add(PlanRow.ChildrenShelf(children))
        }

        // Filters and sorts act on titles, so they appear once there are titles to act on.
        if (all.isNotEmpty()) add(PlanRow.Controls)

        val r = resolved
        val announced = r?.upcoming.orEmpty().let { CollectionBrowse.filter(it, filters, ctx) }
        when {
            collection.sections.isEmpty() -> Unit
            r == null || (r.sections.isEmpty() && r.upcoming.isEmpty() && !loaded) -> add(PlanRow.Skeleton)
            r.sections.isEmpty() && r.upcoming.isEmpty() -> add(PlanRow.LoadError)
            else -> {
                val filtered = CollectionBrowse.filter(all, filters, ctx)
                when {
                    filtered.isEmpty() && announced.isEmpty() -> add(PlanRow.NoMatches(noun(all)))
                    // A collection that is small to begin with is laid out as large cards, however it is filtered or sorted.
                    CollectionBrowse.density(all.size) == CollectionBrowse.Density.Sparse && filters.isDefault && sort == BrowseSort.Curated ->
                        add(PlanRow.Sparse(all))
                    sort == BrowseSort.Curated -> sections.forEach { section ->
                        val shown = CollectionBrowse.filter(section.items, filters, ctx)
                        if (shown.isEmpty()) return@forEach
                        add(PlanRow.Heading(section.title, section.title, shown.size))
                        shown.chunked(columns).forEachIndexed { i, row -> add(PlanRow.Posters(row, "${section.title}-$i")) }
                    }
                    else -> {
                        val ordered = CollectionBrowse.sort(filtered, sort, ctx)
                        add(PlanRow.Heading(sort.label, "sorted", ordered.size))
                        ordered.chunked(columns).forEachIndexed { i, row -> add(PlanRow.Posters(row, "sorted-${sort.name}-$i")) }
                    }
                }
                if (announced.isNotEmpty()) {
                    add(PlanRow.Heading("Announced", ANNOUNCED_ID, announced.size))
                    announced.chunked(columns).forEachIndexed { i, row -> add(PlanRow.Posters(row, "announced-$i")) }
                }
            }
        }
    }

    /** The index of the row a chapter chip scrolls to, or null when that chapter is not on the page. */
    fun indexOfChapter(rows: List<PlanRow>, title: String): Int? =
        rows.indexOfFirst { it is PlanRow.Heading && it.id == title }.takeIf { it >= 0 }

    /** How many titles the collection shows once filters are applied (what the hero and the controls count). */
    fun visibleCount(resolved: ResolvedCollection?, filters: BrowseFilters, ctx: BrowseContext): Int =
        CollectionBrowse.filter(resolved?.allItems().orEmpty(), filters, ctx).size
}
