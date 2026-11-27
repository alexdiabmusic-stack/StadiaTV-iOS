package com.nuvio.app.features.explore

/**
 * The shape of the Collections landing page: which collection is the hero, how the featured ones are laid out, and the order
 * of the families below. It is fixed by the catalog (never random), so the page looks the same on every visit and refresh.
 */
object CollectionLanding {
    /** The collection that opens the page when it is published (a franchise with strong artwork), else the first featured. */
    private const val HERO_ID = "mcu"

    fun hero(): ExploreCollection? = ExploreCatalog[HERO_ID]?.takeIf { it.published } ?: ExploreCatalog.featured.firstOrNull()

    /** A row of the mosaic: one wide card across the page, or two side by side. */
    data class Block(val wide: Boolean, val items: List<ExploreCollection>)

    /**
     * Cards in a repeating, editorial rhythm: one wide, then two pairs, then one wide again. A final partial pair stays a pair
     * (the page never stretches one card to fill a row it shares with nobody, except as the intended wide card).
     */
    fun mosaic(collections: List<ExploreCollection>): List<Block> {
        val out = ArrayList<Block>()
        var i = 0
        var step = 0
        while (i < collections.size) {
            val wide = step % 3 == 0
            val take = if (wide) 1 else 2
            out += Block(wide, collections.subList(i, minOf(collections.size, i + take)))
            i += take
            step++
        }
        return out
    }

    /** The order the families appear below the featured cards: universes first, then what people browse by. */
    val CATEGORY_ORDER: List<CollectionCategory> = listOf(
        CollectionCategory.Universes, CollectionCategory.Genres, CollectionCategory.Awards, CollectionCategory.Seasonal,
        CollectionCategory.Decades, CollectionCategory.Situations, CollectionCategory.Moods, CollectionCategory.Animation,
        CollectionCategory.International, CollectionCategory.Directors, CollectionCategory.Documentaries, CollectionCategory.Sports,
        CollectionCategory.Studios,
    )

    /** A family and how it is introduced. Featured is shown on its own above; an empty family is never shown. */
    data class Family(val category: CollectionCategory, val title: String, val collections: List<ExploreCollection>)

    private fun familyTitle(category: CollectionCategory) = when (category) {
        CollectionCategory.Universes -> "Movie & TV Universes"
        CollectionCategory.Situations -> "Quick Picks"
        else -> category.title
    }

    fun families(): List<Family> {
        val byCategory = ExploreCatalog.byCategory().toMap()
        return CATEGORY_ORDER.mapNotNull { c -> byCategory[c]?.takeIf { it.isNotEmpty() }?.let { Family(c, familyTitle(c), it) } }
    }

    /** What the featured mosaic shows: the featured collections, without the hero that already opens the page. */
    fun featured(): List<ExploreCollection> = ExploreCatalog.featured.filter { it.id != hero()?.id }

    /** How many a family shows before "See all". */
    const val PREVIEW = 4
}
