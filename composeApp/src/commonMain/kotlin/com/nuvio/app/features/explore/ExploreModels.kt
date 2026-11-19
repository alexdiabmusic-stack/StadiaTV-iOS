package com.nuvio.app.features.explore

/**
 * The Explore collections: editorial, metadata-driven, franchise and personal collections, all described as data
 * (see [ExploreCatalog]) and filled at runtime by [ExploreResolver]. Every title is identified by its TMDB id, the same
 * id the rest of the app opens titles by ("tmdb:<id>"), so there is no second movie or series database.
 */

/** How a collection is put together. */
enum class CollectionKind {
    /** Hand-picked titles (Comfort TV, Masterpieces); the picks are BannerTV's editorial choice, not a ranking. */
    Editorial,

    /** Filled from provider metadata: runtime, genres, keywords, release dates, studios, networks, languages. */
    Metadata,

    /** Films and series linked by TMDB collection ids or a hand-checked list of TMDB ids. */
    Franchise,

    /** Built for the active profile from what it has watched. */
    Personalized,
}

enum class CollectionMedia { Movies, Series, Mixed }

enum class CollectionCategory(val title: String) {
    Featured("Featured"),
    Universes("Movie & TV Universes"),
    Genres("Genres & Subgenres"),
    Moods("Moods"),
    Situations("Viewing Situations"),
    Decades("Decades & Nostalgia"),
    Awards("Awards & Prestige"),
    Directors("Directors & Filmmakers"),
    International("International"),
    Animation("Animation, Anime & Family"),
    Seasonal("Seasonal & Holiday"),
    Documentaries("Documentaries & Real Life"),
    Sports("Sports on Screen"),
    Studios("Studios & Networks"),
}

/** A film or series by its TMDB id. */
data class TitleRef(val tmdbId: Int, val tv: Boolean = false) {
    val key: String get() = (if (tv) "tv:" else "movie:") + tmdbId
}

/** Where one shelf of a collection page gets its titles. */
sealed interface SectionSource {
    /** A TMDB discover (or list) query; [tv] picks the series side. */
    data class Discover(val endpoint: String, val query: Map<String, String>, val tv: Boolean = false) : SectionSource

    /** Hand-picked titles, shown in the given order. */
    data class Titles(val refs: List<TitleRef>) : SectionSource

    /** A TMDB movie collection (the provider's own franchise grouping), in release order. */
    data class MovieCollection(val tmdbCollectionId: Int) : SectionSource

    /** Films a person directed, newest first (from their TMDB crew credits, job "Director"). */
    data class Directed(val personId: Int) : SectionSource

    /** Films arriving to stream, rent or buy soon, and series premiering soon. */
    data object ComingSoon : SectionSource

    /** Films that came out to stream, rent or buy in the last weeks. */
    data object NewOnDigital : SectionSource

    /** Personal picks for the active profile (see [com.nuvio.app.features.recommendations.RecommendationEngine]). */
    data object ForYou : SectionSource
}

data class CollectionSection(val title: String, val source: SectionSource)

/**
 * One collection. [sections] are the shelves on its page; [children] are nested collections shown as cards on the
 * page (the Infinity Saga inside the MCU). [storyOrder] is a curated, established in-story order and exists only
 * where there is one; everything else is in release order.
 */
data class ExploreCollection(
    val id: String,
    val title: String,
    val description: String,
    val category: CollectionCategory,
    val kind: CollectionKind,
    val media: CollectionMedia,
    val sections: List<CollectionSection> = emptyList(),
    val subtitle: String? = null,
    val children: List<String> = emptyList(),
    val storyOrder: List<TitleRef>? = null,
    /** The title whose backdrop is the card and page artwork, chosen by hand so the art suits the collection. */
    val art: TitleRef? = null,
    /** The title whose logo is the franchise wordmark (only where that logo is the franchise's own name). */
    val logo: TitleRef? = null,
    /** Months (1-12) when the collection is in season; empty means all year. */
    val months: Set<Int> = emptySet(),
    /** Editorial weight for the Home rail: higher is shown sooner. */
    val priority: Int = 0,
    /** One of the 24 featured collections. */
    val featured: Boolean = false,
    /** TMDB genre ids the collection suits; matched against a profile's taste when picking the Home rail. */
    val affinity: Set<Int> = emptySet(),
    /** Unpublished collections stay in the catalog but are not shown. */
    val published: Boolean = true,
    /** For an episode collection (Christmas Episodes): its key in the verified episode catalog; opens the episode page. */
    val episodes: String? = null,
)

/** A collection with its titles found: shelves in order, each title appearing once. */
data class ResolvedCollection(
    val id: String,
    val sections: List<ResolvedSection>,
    /** Announced titles without a release yet (a franchise's next film), kept apart from the rest. */
    val upcoming: List<com.nuvio.app.features.home.MetaPreview> = emptyList(),
    /** TMDB's average score per title id, for the "Top Rated" sort. */
    val ratings: Map<String, Double> = emptyMap(),
)

data class ResolvedSection(val title: String, val items: List<com.nuvio.app.features.home.MetaPreview>)
