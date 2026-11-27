package com.nuvio.app.features.explore

import com.nuvio.app.features.home.MetaPreview

/**
 * How a collection page filters, sorts and lays out its titles. Everything here is a pure function of the resolved titles and
 * what the app knows about the profile, so the rules (the strict runtime boundaries, what a missing value means, the order
 * of a sort) are tested without a screen. The page only draws what this returns.
 */

enum class BrowseMedia(val label: String) { All("All"), Movies("Movies"), Series("Series") }

/** What the profile has done with a title. "Available to Watch" is not offered: nothing here can say a source exists. */
enum class WatchFilter(val label: String) { All("All"), Unwatched("Unwatched"), Watched("Watched"), Watchlist("Watchlist") }

enum class BrowseSort(val label: String) {
    Curated("Curated Order"),
    MostRecent("Most Recent"),
    Oldest("Oldest First"),
    HighestRated("Highest Rated"),
    MostPopular("Most Popular"),
    TitleAZ("Title A–Z"),
    ShortestRuntime("Shortest Runtime"),
    LongestRuntime("Longest Runtime"),

    /** A franchise in release order (the same as Oldest First, named the way a saga is read). */
    Release("Release Order"),

    /** A franchise in its curated in-story order, only where the catalog has one. */
    Story("Story Order"),

    /** An award collection by the year of the ceremony (newest first), not the year the title came out. */
    CeremonyYear("Ceremony Year"),
    ;

    /** Needs each title's runtime, which a list does not carry. */
    val needsRuntime: Boolean get() = this == ShortestRuntime || this == LongestRuntime
}

/** Runtime windows for the filter sheet. The boundaries are exact: "Under 2 hours" is strictly below 120 minutes. */
enum class RuntimeBand(val label: String, private val atLeast: Int, private val below: Int) {
    UpTo90("90 min or less", 0, 91),
    Under120("Under 2 hours", 0, 120),
    From120To150("2 to 2½ hours", 120, 151),
    Over150("Over 2½ hours", 151, Int.MAX_VALUE),
    ;

    fun contains(minutes: Int): Boolean = minutes >= atLeast && minutes < below
}

data class BrowseFilters(
    val media: BrowseMedia = BrowseMedia.All,
    val watch: WatchFilter = WatchFilter.All,
    val genres: Set<String> = emptySet(),
    /** Decade starts: 1990 for the 1990s. */
    val decades: Set<Int> = emptySet(),
    val runtime: RuntimeBand? = null,
    /** TMDB's 0..10 score, at least. */
    val minRating: Double? = null,
    val languages: Set<String> = emptySet(),
    /** An award collection's category ("Outstanding Drama Series"), when one is chosen. */
    val awardCategory: String? = null,
) {
    /** The filters inside the advanced sheet that are set (the chips above the grid are counted apart). */
    val advancedCount: Int get() = listOf(genres.isNotEmpty(), decades.isNotEmpty(), runtime != null, minRating != null, languages.isNotEmpty(), awardCategory != null).count { it }
    val isDefault: Boolean get() = this == BrowseFilters()
    val needsRuntime: Boolean get() = runtime != null
}

/** What the filters and sorts need to know about the profile and about each title beyond its list entry. */
class BrowseContext(
    val isWatched: (MetaPreview) -> Boolean = { false },
    val isSaved: (MetaPreview) -> Boolean = { false },
    /** Minutes by title id, for the titles whose runtime has been looked up. A title missing here has an unknown runtime. */
    val runtimes: Map<String, Int> = emptyMap(),
    /** TMDB score by title id. */
    val ratings: Map<String, Double> = emptyMap(),
    val story: List<TitleRef>? = null,
    /** Award wins by title key, for an award collection. */
    val awards: Map<String, List<AwardEntry>> = emptyMap(),
)

object CollectionBrowse {
    fun key(item: MetaPreview): String = (if (item.type == "series") "tv:" else "movie:") + (item.id.removePrefix("tmdb:"))

    fun year(item: MetaPreview): Int? = (item.rawReleaseDate ?: item.releaseInfo)?.take(4)?.toIntOrNull()

    /** The newest ceremony a title won at, when the collection carries award data for it. */
    fun ceremonyYear(item: MetaPreview, awards: Map<String, List<AwardEntry>>): Int? = awards[key(item)]?.maxOfOrNull { it.ceremonyYear }

    /** The year a decade filter reads: the ceremony's in an award collection (the Oscars of the 1990s), else the release year. */
    fun filterYear(item: MetaPreview, awards: Map<String, List<AwardEntry>>): Int? = ceremonyYear(item, awards) ?: year(item)

    fun decadeOf(year: Int): Int = year / 10 * 10

    fun decadeLabel(decade: Int): String = "${decade}s"

    /** True when [item] passes every filter. A value a filter needs but the title doesn't have is a miss, never a guess. */
    fun passes(item: MetaPreview, f: BrowseFilters, ctx: BrowseContext): Boolean {
        when (f.media) {
            BrowseMedia.All -> Unit
            BrowseMedia.Movies -> if (item.type != "movie") return false
            BrowseMedia.Series -> if (item.type != "series") return false
        }
        when (f.watch) {
            WatchFilter.All -> Unit
            WatchFilter.Unwatched -> if (ctx.isWatched(item)) return false
            WatchFilter.Watched -> if (!ctx.isWatched(item)) return false
            WatchFilter.Watchlist -> if (!ctx.isSaved(item)) return false
        }
        if (f.genres.isNotEmpty() && item.genres.none { it in f.genres }) return false
        if (f.decades.isNotEmpty()) {
            val y = filterYear(item, ctx.awards) ?: return false
            if (decadeOf(y) !in f.decades) return false
        }
        f.runtime?.let { band ->
            val minutes = ctx.runtimes[item.id] ?: return false
            if (!band.contains(minutes)) return false
        }
        f.minRating?.let { min ->
            val rating = ctx.ratings[item.id] ?: return false
            if (rating < min) return false
        }
        if (f.languages.isNotEmpty() && item.language !in f.languages) return false
        f.awardCategory?.let { category ->
            if (ctx.awards[key(item)].orEmpty().none { it.category == category }) return false
        }
        return true
    }

    fun filter(items: List<MetaPreview>, f: BrowseFilters, ctx: BrowseContext): List<MetaPreview> =
        if (f.isDefault) items else items.filter { passes(it, f, ctx) }

    /** [items] in the chosen order. A title missing the value a sort uses goes to the end, in its curated place. */
    fun sort(items: List<MetaPreview>, sort: BrowseSort, ctx: BrowseContext): List<MetaPreview> {
        val indexed = items.withIndex()
        fun <T : Comparable<T>> byDesc(value: (MetaPreview) -> T?) =
            indexed.sortedWith(compareBy<IndexedValue<MetaPreview>> { value(it.value) == null }.thenByDescending { value(it.value) }.thenBy { it.index }).map { it.value }
        fun <T : Comparable<T>> byAsc(value: (MetaPreview) -> T?) =
            indexed.sortedWith(compareBy<IndexedValue<MetaPreview>> { value(it.value) == null }.thenBy { value(it.value) }.thenBy { it.index }).map { it.value }
        return when (sort) {
            BrowseSort.Curated -> items
            BrowseSort.MostRecent -> byDesc { it.rawReleaseDate?.takeIf { d -> d.isNotBlank() } }
            BrowseSort.Oldest, BrowseSort.Release -> byAsc { it.rawReleaseDate?.takeIf { d -> d.isNotBlank() } }
            BrowseSort.HighestRated -> byDesc { ctx.ratings[it.id] }
            BrowseSort.MostPopular -> byDesc { it.popularity }
            BrowseSort.TitleAZ -> items.sortedWith(compareBy<MetaPreview> { sortableTitle(it.name) }.thenBy { it.name })
            BrowseSort.ShortestRuntime -> byAsc { ctx.runtimes[it.id] }
            BrowseSort.LongestRuntime -> byDesc { ctx.runtimes[it.id] }
            BrowseSort.CeremonyYear -> byDesc { ceremonyYear(it, ctx.awards) }
            BrowseSort.Story -> {
                val position = ctx.story.orEmpty().mapIndexed { i, ref -> ref.key to i }.toMap()
                indexed.sortedWith(compareBy<IndexedValue<MetaPreview>> { position[key(it.value)] ?: Int.MAX_VALUE }.thenBy { it.value.rawReleaseDate ?: "9999" }.thenBy { it.index }).map { it.value }
            }
        }
    }

    /** A title as a list sorts it: no leading article, case and punctuation ignored. */
    fun sortableTitle(name: String): String {
        val lower = name.lowercase().trim()
        val articles = listOf("the ", "a ", "an ")
        val stripped = articles.firstOrNull { lower.startsWith(it) }?.let { lower.removePrefix(it) } ?: lower
        return stripped.filter { it.isLetterOrDigit() || it == ' ' }.trim()
    }

    /** The sorts a collection offers, in menu order. Story only with a curated story order; Release only for a saga. */
    fun sortsFor(collection: ExploreCollection): List<BrowseSort> = buildList {
        add(BrowseSort.Curated)
        if (ExploreAwards.has(collection.id)) add(BrowseSort.CeremonyYear)
        add(BrowseSort.MostRecent)
        add(BrowseSort.Oldest)
        add(BrowseSort.HighestRated)
        add(BrowseSort.MostPopular)
        add(BrowseSort.TitleAZ)
        add(BrowseSort.ShortestRuntime)
        add(BrowseSort.LongestRuntime)
        if (collection.kind == CollectionKind.Franchise) add(BrowseSort.Release)
        if (collection.storyOrder != null) add(BrowseSort.Story)
    }

    // ------------------------------------------------------------------------------------------------ Facets

    /** The values the advanced sheet can offer for [items]: only what actually occurs, most common first. */
    data class Facets(
        val genres: List<Pair<String, Int>>,
        val decades: List<Int>,
        val languages: List<Pair<String, Int>>,
    ) {
        val isEmpty: Boolean get() = genres.isEmpty() && decades.isEmpty() && languages.isEmpty()
    }

    fun facets(items: List<MetaPreview>, awards: Map<String, List<AwardEntry>> = emptyMap()): Facets {
        fun counted(values: List<String>) = values.groupingBy { it }.eachCount().entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key }).map { it.key to it.value }
        val genres = counted(items.flatMap { it.genres })
        val languages = counted(items.mapNotNull { it.language?.takeIf { l -> l.isNotBlank() } })
        val perDecade = items.mapNotNull { filterYear(it, awards)?.let(::decadeOf) }.groupingBy { it }.eachCount()
        // A facet that every title shares filters nothing, so it is not offered: it must be able to leave some title out.
        fun splits(counts: Collection<Int>) = counts.any { it < items.size }
        return Facets(
            genres = if (splits(genres.map { it.second })) genres else emptyList(),
            decades = if (splits(perDecade.values)) perDecade.keys.sorted() else emptyList(),
            languages = if (splits(languages.map { it.second })) languages else emptyList(),
        )
    }

    // ------------------------------------------------------------------------------------------------ Layout

    /** How many titles a collection has decides how it is laid out, so a small one looks intended and a large one scrolls. */
    enum class Density { Empty, Sparse, Standard, Full }

    fun density(count: Int): Density = when {
        count <= 0 -> Density.Empty
        count <= 3 -> Density.Sparse
        count <= 9 -> Density.Standard
        else -> Density.Full
    }

    /**
     * Grid columns from the width the grid really has: two on a phone, then as many as fit at a comfortable poster width.
     * Large text takes a column away on a narrow screen so labels have room. Never decided by device model.
     */
    fun columns(widthDp: Float, fontScale: Float = 1f): Int {
        val columns = when {
            widthDp < 600f -> 2
            else -> ((widthDp - 32f) / 170f).toInt().coerceIn(3, 6)
        }
        return if (fontScale >= 2f && widthDp < 600f) 1 else columns
    }

    /** The widest the page's content grows, so an iPad doesn't stretch a phone layout across the whole screen. */
    const val MAX_CONTENT_WIDTH_DP = 1100f

    /** Compact heights for the hero: roughly 40% of the width on a phone, never taller than 60% of the window. */
    fun heroHeightDp(widthDp: Float, heightDp: Float): Float =
        (widthDp * 0.78f).coerceIn(240f, 420f).coerceAtMost(heightDp * 0.6f).coerceAtLeast(200f)

    // ------------------------------------------------------------------------------------------------ Chapters

    /** One chapter of a long collection: a saga, a phase, a decade. Only sections that hold titles are chapters. */
    data class Chapter(val title: String, val count: Int)

    fun chapters(sections: List<ResolvedSection>): List<Chapter> =
        sections.filter { it.items.isNotEmpty() }.map { Chapter(it.title, it.items.size) }
}
