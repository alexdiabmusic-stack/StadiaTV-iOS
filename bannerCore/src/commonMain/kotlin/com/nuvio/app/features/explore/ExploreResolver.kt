package com.nuvio.app.features.explore
import com.nuvio.app.features.tmdb.CoreClock

import com.nuvio.app.features.explore.ExploreTmdb.double
import com.nuvio.app.features.explore.ExploreTmdb.excluded
import com.nuvio.app.features.explore.ExploreTmdb.int
import com.nuvio.app.features.explore.ExploreTmdb.str
import com.nuvio.app.features.explore.ExploreTmdb.toPreview
import com.nuvio.app.features.home.HomeTrendingRepository
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.home.stableKey
import com.nuvio.app.features.recommendations.RecommendationEngine
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/** A collection's artwork: a backdrop and, for franchises with one, the franchise's own logo. */
data class CollectionArt(val backdrop: String?, val logo: String?)

/**
 * Fills a collection with titles. Shelves are resolved in order and reported as each one lands, so a page shows its
 * first shelf without waiting for the last; a title appears on one shelf only. Results are kept for a few hours, both
 * here (per collection) and in [ExploreTmdb] (per request), so going back to a page is instant.
 */
object ExploreResolver {
    private const val TTL_MS = 3L * 60 * 60 * 1000
    /** Titles fetched for a discover shelf: six TMDB pages (up to 120 titles). */
    private const val DISCOVER_PAGES = 6

    private val lock = Mutex()
    private val resolved = HashMap<String, Pair<Long, ResolvedCollection>>()
    private val arts = HashMap<String, CollectionArt>()
    private val titles = HashMap<String, Pair<MetaPreview, Double?>?>()

    /**
     * Asks TMDB again for a collection, for a pull to refresh. The page keeps showing what it has until the new answer
     * arrives; an answer with nothing in it (no connection) leaves the earlier one in place.
     */
    suspend fun refresh(collection: ExploreCollection, onProgress: (ResolvedCollection) -> Unit = {}): ResolvedCollection {
        val before = lock.withLock { resolved[collection.id]?.second }
        lock.withLock { resolved.remove(collection.id) }
        ExploreTmdb.dropCache()
        val fresh = resolve(collection, onProgress)
        if (fresh.sections.isEmpty() && fresh.upcoming.isEmpty() && before != null) {
            lock.withLock { resolved[collection.id] = CoreClock.nowMs() to before }
            onProgress(before)
            return before
        }
        return fresh
    }

    suspend fun cached(collectionId: String): ResolvedCollection? =
        lock.withLock { resolved[collectionId]?.takeIf { CoreClock.nowMs() - it.first < TTL_MS }?.second }

    suspend fun resolve(collection: ExploreCollection, onProgress: (ResolvedCollection) -> Unit = {}): ResolvedCollection {
        cached(collection.id)?.let { onProgress(it); return it }
        val seen = HashSet<String>()
        val sections = ArrayList<ResolvedSection>()
        val upcoming = ArrayList<MetaPreview>()
        val ratings = HashMap<String, Double>()
        for (section in collection.sections) {
            val found = runCatching { fetch(section.source) }.getOrNull() ?: Found(emptyList())
            // Catalogue shelves of an overlapping collection may repeat titles; the others skip what is already shown.
            val repeats = collection.overlap && section.source is SectionSource.Curated
            val items = if (repeats) found.items.also { list -> list.forEach { seen.add(it.id) } } else found.items.filter { seen.add(it.id) }
            upcoming += found.upcoming.filter { seen.add(it.id) }
            ratings += found.ratings
            if (items.isNotEmpty()) sections += ResolvedSection(section.title, items)
            onProgress(ResolvedCollection(collection.id, sections.toList(), upcoming.toList(), ratings.toMap()))
        }
        val result = ResolvedCollection(collection.id, sections, upcoming, ratings)
        // Only a collection that found something is kept: an empty answer is usually a network problem.
        if (sections.isNotEmpty() || upcoming.isNotEmpty()) lock.withLock { resolved[collection.id] = CoreClock.nowMs() to result }
        return result
    }

    /** Every title in a collection, once, in shelf order (for watched progress and the "All" grid). */
    fun ResolvedCollection.allItems(): List<MetaPreview> = sections.flatMap { it.items }.distinctBy { it.id }

    private class Found(
        val items: List<MetaPreview>,
        val upcoming: List<MetaPreview> = emptyList(),
        val ratings: Map<String, Double> = emptyMap(),
    )

    private suspend fun fetch(source: SectionSource): Found = when (source) {
        is SectionSource.Discover -> discover(source)
        is SectionSource.Titles -> titlesWithRatings(source.refs)
        is SectionSource.Curated -> curated(source.shelf)
        is SectionSource.MovieCollection -> movieCollection(source.tmdbCollectionId)
        is SectionSource.Directed -> Found(directed(source.personId))
        SectionSource.NewOnDigital -> Found(newOnDigital())
        SectionSource.ComingSoon -> Found(comingSoon())
        SectionSource.ForYou -> Found(RecommendationEngine.state.value.items)
    }

    private suspend fun discover(source: SectionSource.Discover): Found = coroutineScope {
        val today = CoreClock.todayIsoDate()
        val rows = (1..DISCOVER_PAGES).map { page -> async { ExploreTmdb.results(source.endpoint, source.query, page) } }
            .awaitAll().flatten()
            .filterNot { it.excluded(source.tv) }
            // Metadata collections list what can be watched; titles not out yet belong to Coming Soon.
            .filter { o -> (o.str("release_date") ?: o.str("first_air_date"))?.let { it <= today } == true }
            .mapNotNull { o -> o.toPreview(source.tv)?.let { it to o.double("vote_average") } }
            .distinctBy { it.first.id }
        Found(rows.map { it.first }, ratings = rows.ratings())
    }

    private fun curated(shelf: String): Found {
        val rows = ChristmasRomanceCatalogue.shelf(shelf)
            .mapNotNull { o -> o.toPreview(false)?.let { it to o.double("vote_average") } }
            .distinctBy { it.first.id }
        return Found(rows.map { it.first }, ratings = rows.ratings())
    }

    private fun List<Pair<MetaPreview, Double?>>.ratings(): Map<String, Double> =
        mapNotNull { (p, r) -> r?.let { p.id to it } }.toMap()

    /** One title by id with its TMDB score; cached for the session (title metadata hardly changes). */
    private suspend fun titleWithRating(ref: TitleRef): Pair<MetaPreview, Double?>? {
        lock.withLock { if (titles.containsKey(ref.key)) return titles[ref.key] }
        val o = ExploreTmdb.get(if (ref.tv) "tv/${ref.tmdbId}" else "movie/${ref.tmdbId}") ?: return null
        val entry = if (o.excluded(ref.tv)) null else o.toPreview(ref.tv)?.let { it to o.double("vote_average") }
        lock.withLock { titles[ref.key] = entry }
        return entry
    }

    suspend fun title(ref: TitleRef): MetaPreview? = titleWithRating(ref)?.first

    // ------------------------------------------------------------------------------------------------ Runtimes

    /** Runtime in minutes by preview id; null is cached too ("TMDB has none"), so a title is only asked about once. */
    private val runtimeCache = HashMap<String, Int?>()

    /** Runtimes already looked up, for the titles in [items]. Nothing is fetched. */
    suspend fun knownRuntimes(items: List<MetaPreview>): Map<String, Int> =
        lock.withLock { items.mapNotNull { p -> runtimeCache[p.stableKey()]?.let { p.id to it } }.toMap() }

    /**
     * Looks up the runtime of the titles in [items] that have not been asked about yet, a few at a time, and reports the
     * growing result as each batch lands. A list carries no runtime, so this is only done when a runtime filter or sort
     * needs it; a title TMDB has no runtime for stays unknown (and is left out of any runtime match).
     */
    suspend fun loadRuntimes(items: List<MetaPreview>, onProgress: (Map<String, Int>) -> Unit) {
        val todo = lock.withLock { items.filter { !runtimeCache.containsKey(it.stableKey()) } }
        onProgress(knownRuntimes(items))
        todo.chunked(24).forEach { batch ->
            coroutineScope {
                batch.map { p -> async { p to runtimeOf(p) } }.awaitAll()
            }.let { found -> lock.withLock { found.forEach { (p, minutes) -> runtimeCache[p.stableKey()] = minutes } } }
            onProgress(knownRuntimes(items))
        }
    }

    private suspend fun runtimeOf(p: MetaPreview): Int? {
        val tv = p.type == "series"
        val id = ExploreTmdb.tmdbId(p.id) ?: return null
        val o = ExploreTmdb.get(if (tv) "tv/$id" else "movie/$id") ?: return null
        val minutes = if (tv) {
            (o["episode_run_time"] as? JsonArray)?.firstNotNullOfOrNull { (it as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull()?.takeIf { m -> m > 0 } }
        } else {
            o.int("runtime")
        }
        return minutes?.takeIf { it > 0 }
    }

    /** Hand-picked titles in their given order; any not released yet (an announced sequel) go to "upcoming". */
    private suspend fun titlesWithRatings(refs: List<TitleRef>): Found = coroutineScope {
        val rows = refs.map { async { titleWithRating(it) } }.awaitAll().filterNotNull().distinctBy { it.first.id }
        val today = CoreClock.todayIsoDate()
        val (released, announced) = rows.partition { (p, _) -> p.rawReleaseDate?.let { it <= today } == true }
        Found(released.map { it.first }, announced.map { it.first }, released.ratings())
    }

    /**
     * A TMDB movie collection in release order. Entries without a release date, or dated in the future, are announced
     * films; they go in "upcoming" rather than in the list of films you can watch.
     */
    private suspend fun movieCollection(id: Int): Found {
        val o = ExploreTmdb.get("collection/$id") ?: return Found(emptyList())
        val today = CoreClock.todayIsoDate()
        val parts = (o["parts"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.filterNot { it.excluded(tv = false) }
        val (released, announced) = parts.partition { p -> p.str("release_date")?.let { it <= today } == true }
        fun List<JsonObject>.previews() = sortedBy { it.str("release_date") ?: "9999" }
            .mapNotNull { p -> p.toPreview(tv = false)?.let { it to p.double("vote_average") } }
        val films = released.previews()
        return Found(films.map { it.first }, announced.previews().map { it.first }, films.ratings())
    }

    /** Films a person directed, newest first. Crew credits include producing and writing, so only "Director" counts. */
    private suspend fun directed(personId: Int): List<MetaPreview> {
        val o = ExploreTmdb.get("person/$personId/movie_credits") ?: return emptyList()
        val today = CoreClock.todayIsoDate()
        return (o["crew"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
            .filter { it.str("job") == "Director" }
            .filter { it.str("release_date")?.let { d -> d <= today } == true }
            .filterNot { it.excluded(tv = false) }
            .sortedByDescending { it.str("release_date") }
            .mapNotNull { it.toPreview(tv = false) }
            .distinctBy { it.id }
    }

    private suspend fun newOnDigital(): List<MetaPreview> {
        HomeTrendingRepository.ensureLoaded()
        val state = withTimeoutOrNull(15_000) { HomeTrendingRepository.state.first { s -> s.rows.any { it.key == "new-digital" } || s.loadedOnce } }
        return state?.rows?.firstOrNull { it.key == "new-digital" }?.items.orEmpty()
    }

    private suspend fun comingSoon(): List<MetaPreview> = coroutineScope {
        val films = async {
            HomeTrendingRepository.ensureLoaded()
            withTimeoutOrNull(15_000) { HomeTrendingRepository.state.first { it.comingSoon.isNotEmpty() || it.loadedOnce } }?.comingSoon.orEmpty()
        }
        val today = CoreClock.todayIsoDate()
        val shows = async {
            ExploreTmdb.results(
                "discover/tv",
                mapOf("first_air_date.gte" to tomorrow(today), "sort_by" to "popularity.desc", "include_adult" to "false", "without_genres" to "10767,10763,10764"),
            ).filterNot { it.excluded(tv = true) }.mapNotNull { it.toPreview(tv = true) }.take(20)
        }
        (films.await() + shows.await()).sortedBy { it.rawReleaseDate ?: "9999" }
    }

    private fun tomorrow(today: String): String {
        val (y, m, d) = today.split("-").map { it.toIntOrNull() ?: return today }
        val days = when (m) { 2 -> if (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) 29 else 28; 4, 6, 9, 11 -> 30; else -> 31 }
        val (ny, nm, nd) = if (d < days) Triple(y, m, d + 1) else if (m < 12) Triple(y, m + 1, 1) else Triple(y + 1, 1, 1)
        return "${ny.toString().padStart(4, '0')}-${nm.toString().padStart(2, '0')}-${nd.toString().padStart(2, '0')}"
    }

    // ------------------------------------------------------------------------------------------------ Artwork

    /**
     * The card and page artwork. The backdrop is the hand-picked title's, or, for collections without one, the first
     * title the collection resolves to (always the same for the same data, so cards don't flicker between visits).
     * The logo is only used where the catalog names a title whose logo is the franchise's own name.
     */
    suspend fun art(collection: ExploreCollection, size: String = "w780"): CollectionArt {
        val key = "${collection.id}|$size"
        lock.withLock { arts[key]?.let { return it } }
        val backdrop = collection.art?.let { backdrop(it, size) }
            ?: collection.episodes?.let { id -> HolidayEpisodes.featured(HolidayEpisodes.of(id), 0).firstNotNullOfOrNull { it.still?.let { _ -> it.artwork(size) } } }
            ?: fallbackBackdrop(collection)?.replace("/w780/", "/$size/")
        val logo = collection.logo?.let { logo(it) }
        val art = CollectionArt(backdrop, logo)
        if (backdrop != null) lock.withLock { arts[key] = art }
        return art
    }

    private suspend fun backdrop(ref: TitleRef, size: String): String? =
        ExploreTmdb.get(if (ref.tv) "tv/${ref.tmdbId}" else "movie/${ref.tmdbId}")?.str("backdrop_path")?.let { "https://image.tmdb.org/t/p/$size$it" }

    private suspend fun logo(ref: TitleRef): String? {
        val o = ExploreTmdb.get(
            if (ref.tv) "tv/${ref.tmdbId}/images" else "movie/${ref.tmdbId}/images",
            mapOf("include_image_language" to "en,null", "language" to ""),
        ) ?: return null
        val logos = (o["logos"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
        val best = logos.filter { it.str("iso_639_1") == "en" }.ifEmpty { logos }
            .maxByOrNull { it.double("vote_average") ?: 0.0 } ?: return null
        return best.str("file_path")?.let { "https://image.tmdb.org/t/p/w500$it" }
    }

    /** For a collection with no art title: the backdrop of the first title it lists, or of its first child collection's. */
    private suspend fun fallbackBackdrop(collection: ExploreCollection): String? {
        cached(collection.id)?.allItems()?.firstNotNullOfOrNull { it.banner }?.let { return it }
        val first = collection.sections.firstOrNull()?.source
        if (first != null) {
            val items = runCatching { fetch(first).items }.getOrDefault(emptyList())
            items.firstNotNullOfOrNull { it.banner }?.let { return it }
        }
        return ExploreCatalog.children(collection).firstOrNull()?.let { art(it).backdrop }
    }
}
