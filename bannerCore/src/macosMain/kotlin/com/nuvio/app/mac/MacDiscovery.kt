package com.nuvio.app.mac

import com.nuvio.app.features.explore.CollectionArt
import com.nuvio.app.features.explore.ExploreCatalog
import com.nuvio.app.features.explore.ExploreCollection
import com.nuvio.app.features.explore.ExploreResolver
import com.nuvio.app.features.explore.ExploreSelection
import com.nuvio.app.features.explore.ResolvedCollection
import com.nuvio.app.features.home.HomeRowIds
import com.nuvio.app.features.home.HomeTrendingRepository
import com.nuvio.app.features.home.MetaPreview
import com.nuvio.app.features.recommendations.ProgressEvidence
import com.nuvio.app.features.recommendations.RecommendationEngine
import com.nuvio.app.features.recommendations.RecommendationInputs
import com.nuvio.app.features.recommendations.SavedEvidence
import com.nuvio.app.features.recommendations.TmdbRecommendationData
import com.nuvio.app.features.recommendations.WatchedEvidence
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.launch

/** What the discovery rows on Home hold: Recommended For You, the personal rows, Top 10 Today and the curated lists. */
class MacDiscoveryState(
    val recommended: List<MetaPreview>,
    val reasons: Map<String, String>,
    val rows: List<MacHomeRow>,
    val top10: List<MetaPreview>,
    val curated: List<MacHomeRow>,
    val isPersonal: Boolean,
    val explore: List<ExploreCollection>,
)

/**
 * Recommendations, Top 10 and Explore, from the shared engine. The engine is fed the active profile's history; Top 10
 * and the curated lists are the same for everyone.
 */
@OptIn(FlowPreview::class)
object MacDiscovery {
    private val scope = macScope()
    private var started = false

    fun start() {
        if (started) return
        started = true
        if (RecommendationEngine.data !== TmdbRecommendationData) RecommendationEngine.install(TmdbRecommendationData)
        HomeTrendingRepository.ensureLoaded()
        scope.launch {
            combine(MacAccountData.progress, MacAccountData.library, MacAccountData.watched) { p, l, w -> Triple(p, l, w) }
                .debounce(1_500)
                .collect { (progress, library, watched) ->
                    RecommendationEngine.refresh(
                        RecommendationInputs(
                            profileId = MacAccountData.activeProfileIndex,
                            watched = watched.map { WatchedEvidence(it.contentType, it.contentId, it.title, it.season, it.episode, it.watchedAt) },
                            fullyWatchedSeriesKeys = emptySet(),
                            progress = progress.map {
                                ProgressEvidence(
                                    parentMetaType = it.contentType, parentMetaId = it.contentId, title = it.contentId,
                                    isCompleted = it.isComplete, progressPercent = (it.fraction * 100).toFloat(),
                                    durationMs = it.duration, lastPositionMs = it.position, seasonNumber = it.season,
                                    episodeNumber = it.episode, lastUpdatedEpochMs = it.lastWatched,
                                )
                            },
                            saved = library.map { SavedEvidence(it.contentType, it.contentId, it.name, it.addedAt) },
                        ),
                    )
                }
        }
    }

    fun watch(onChange: (MacDiscoveryState) -> Unit): MacWatch = MacWatch(scope.launch {
        combine(RecommendationEngine.state, HomeTrendingRepository.state) { rec, trending -> rec to trending }.collect { (rec, trending) ->
            onChange(
                MacDiscoveryState(
                    recommended = if (rec.isPersonal) rec.items else emptyList(),
                    reasons = rec.reasons,
                    rows = rec.rows.map { MacHomeRow(HomeRowIds.personal(it.kind.name), HomeRowIds.personal(it.kind.name), it.title, "For you", it.items) },
                    top10 = trending.top10,
                    curated = trending.rows.map { MacHomeRow(it.key, HomeRowIds.curated(it.key), it.title, "BannerTV", it.items) },
                    isPersonal = rec.isPersonal,
                    explore = ExploreSelection.forHomeToday(rec.taste, com.nuvio.app.features.tmdb.CoreClock.todayIsoDate()),
                ),
            )
        }
    })

    val allCollections: List<ExploreCollection> get() = ExploreCatalog.all
    val featuredCollections: List<ExploreCollection> get() = ExploreCatalog.featured

    /** Fills a collection's page, reporting the shelves found so far as each arrives. */
    fun resolveCollection(id: String, onProgress: (ResolvedCollection) -> Unit, done: () -> Unit) {
        val collection = ExploreCatalog.all.firstOrNull { it.id == id } ?: run { done(); return }
        scope.launch {
            ExploreResolver.resolve(collection, onProgress = onProgress)
            done()
        }
    }

    fun collectionArt(id: String, done: (CollectionArt?) -> Unit) {
        val collection = ExploreCatalog.all.firstOrNull { it.id == id } ?: run { done(null); return }
        scope.launch { done(runCatching { ExploreResolver.art(collection) }.getOrNull()) }
    }
}
