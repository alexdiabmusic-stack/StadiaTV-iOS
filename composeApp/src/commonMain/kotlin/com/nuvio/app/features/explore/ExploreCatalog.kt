package com.nuvio.app.features.explore

import com.nuvio.app.features.explore.CollectionCategory.Animation
import com.nuvio.app.features.explore.CollectionCategory.Awards
import com.nuvio.app.features.explore.CollectionCategory.Decades
import com.nuvio.app.features.explore.CollectionCategory.Directors
import com.nuvio.app.features.explore.CollectionCategory.Documentaries
import com.nuvio.app.features.explore.CollectionCategory.Featured
import com.nuvio.app.features.explore.CollectionCategory.Genres
import com.nuvio.app.features.explore.CollectionCategory.International
import com.nuvio.app.features.explore.CollectionCategory.Moods
import com.nuvio.app.features.explore.CollectionCategory.Seasonal
import com.nuvio.app.features.explore.CollectionCategory.Situations
import com.nuvio.app.features.explore.CollectionCategory.Sports
import com.nuvio.app.features.explore.CollectionCategory.Studios
import com.nuvio.app.features.explore.CollectionCategory.Universes
import com.nuvio.app.features.explore.CollectionKind.Editorial
import com.nuvio.app.features.explore.CollectionKind.Franchise
import com.nuvio.app.features.explore.CollectionKind.Metadata
import com.nuvio.app.features.explore.CollectionMedia.Mixed
import com.nuvio.app.features.explore.CollectionMedia.Movies
import com.nuvio.app.features.explore.CollectionMedia.Series

/*
 * Every TMDB id below (titles, movie collections, keywords, companies, networks and people) was looked up on TMDB and
 * checked by title and year when this catalog was written. Franchise membership comes from TMDB's own collections
 * or from these checked lists, never from similar names. Award lists are the official winners through the 2025
 * ceremonies. Editorial picks (Masterpieces, Comfort TV, Visually Stunning, ...) are BannerTV's choices and are shown as
 * such, not as rankings.
 */

// ---------------------------------------------------------------------------------------------------- Building blocks

private fun m(id: Int) = TitleRef(id)
private fun t(id: Int) = TitleRef(id, tv = true)
private fun ms(vararg ids: Int) = ids.map { TitleRef(it) }
private fun ts(vararg ids: Int) = ids.map { TitleRef(it, tv = true) }

/** Explicit-content keywords TMDB's adult flag misses (softcore, erotic, explicit sex, nudity, ...). */
internal const val EXPLICIT_KEYWORDS = "155477|190370|347060|256466|155691|281741"

private fun movieBase(votes: Int, rated: Boolean): Map<String, String> = buildMap {
    put("include_adult", "false")
    put("sort_by", "popularity.desc")
    put("vote_count.gte", votes.toString())
    put("without_keywords", EXPLICIT_KEYWORDS)
    // US ratings capped at R; left off for international and older films, which often have no US rating at all.
    if (rated) { put("certification_country", "US"); put("certification.lte", "R") }
}

private fun seriesBase(votes: Int): Map<String, String> = mapOf(
    "include_adult" to "false",
    "sort_by" to "popularity.desc",
    "vote_count.gte" to votes.toString(),
    "without_keywords" to EXPLICIT_KEYWORDS,
    // Talk shows and news chart constantly and are never what a collection is about.
    "without_genres" to "10767,10763",
)

private fun movies(title: String, vararg q: Pair<String, String>, votes: Int = 150, rated: Boolean = true) =
    CollectionSection(title, SectionSource.Discover("discover/movie", movieBase(votes, rated) + q, tv = false))

private fun series(title: String, vararg q: Pair<String, String>, votes: Int = 80) =
    CollectionSection(title, SectionSource.Discover("discover/tv", seriesBase(votes) + q, tv = true))

private fun titles(title: String, refs: List<TitleRef>) = CollectionSection(title, SectionSource.Titles(refs))
private fun coll(title: String, collectionId: Int) = CollectionSection(title, SectionSource.MovieCollection(collectionId))
private fun directed(title: String, personId: Int) = CollectionSection(title, SectionSource.Directed(personId))

private fun decade(from: Int, to: Int) = arrayOf("primary_release_date.gte" to "$from-01-01", "primary_release_date.lte" to "$to-12-31")
private fun decadeTv(from: Int, to: Int) = arrayOf("first_air_date.gte" to "$from-01-01", "first_air_date.lte" to "$to-12-31")

private fun col(
    id: String,
    title: String,
    description: String,
    category: CollectionCategory,
    kind: CollectionKind,
    media: CollectionMedia,
    sections: List<CollectionSection> = emptyList(),
    art: TitleRef? = null,
    logo: TitleRef? = null,
    children: List<String> = emptyList(),
    storyOrder: List<TitleRef>? = null,
    months: Set<Int> = emptySet(),
    priority: Int = 0,
    featured: Boolean = false,
    affinity: Set<Int> = emptySet(),
    subtitle: String? = null,
    published: Boolean = true,
    episodes: String? = null,
) = ExploreCollection(
    id = id, title = title, description = description, category = category, kind = kind, media = media,
    sections = sections, subtitle = subtitle, children = children, storyOrder = storyOrder, art = art, logo = logo,
    months = months, priority = priority, featured = featured, affinity = affinity, published = published,
    episodes = episodes,
)

// TMDB genre ids used for taste matching (movie and series ids where they differ).
private object G {
    const val ACTION = 28; const val ADVENTURE = 12; const val ANIMATION = 16; const val COMEDY = 35; const val CRIME = 80
    const val DOCUMENTARY = 99; const val DRAMA = 18; const val FAMILY = 10751; const val FANTASY = 14; const val HISTORY = 36
    const val HORROR = 27; const val MUSIC = 10402; const val MYSTERY = 9648; const val ROMANCE = 10749; const val SCIFI = 878
    const val THRILLER = 53; const val WAR = 10752; const val TV_ACTION = 10759; const val TV_SCIFI = 10765; const val KIDS = 10762
}

// ---------------------------------------------------------------------------------------------------- Shared lists

private val MCU_PHASE_1 = ms(1726, 1724, 10138, 10195, 1771, 24428)
private val MCU_PHASE_2 = ms(68721, 76338, 100402, 118340, 99861, 102899)
private val MCU_PHASE_3 = ms(271110, 284052, 283995, 315635, 284053, 284054, 299536, 363088, 299537, 299534, 429617)
private val MCU_PHASE_4 = ms(497698, 566525, 524434, 634649, 453395, 616037, 505642)
private val MCU_PHASE_5 = ms(640146, 447365, 609681, 533535, 822119, 986056)
private val MCU_PHASE_6 = ms(617126, 969681, 1003596)
private val MCU_SERIES = ts(85271, 88396, 84958, 91363, 88329, 92749, 92782, 92783, 114472, 122226, 138501, 202555, 114471)

/** The MCU films in in-story order, as Marvel has published it. */
private val MCU_STORY = ms(
    1771, 299537, 1726, 10138, 1724, 10195, 24428, 76338, 68721, 100402, 118340, 283995, 99861, 102899, 271110, 497698,
    284054, 315635, 284052, 284053, 363088, 299536, 299534, 429617, 566525, 524434, 634649, 453395, 505642, 616037,
    640146, 447365, 609681, 533535, 822119, 986056, 617126, 969681, 1003596,
)

private val DCEU = ms(49521, 209112, 297761, 297762, 141052, 297802, 287947, 495764, 464052, 436969, 436270, 594767, 298618, 565770, 572802)
private val STAR_WARS_STORY = ms(1893, 1894, 1895, 348350, 330459, 11, 1891, 1892, 140607, 181808, 181812)

private val OSCAR_BEST_PICTURE = ms(
    1064213, 872585, 545611, 776503, 581734, 496243, 490132, 399055, 376867, 314365, 194662, 76203, 68734, 74643, 45269,
    12162, 12405, 6977, 1422, 1640, 70, 122, 1574, 453, 98, 14, 1934, 597, 409, 197, 13, 424, 33, 274, 581, 380, 792,
    279, 11778, 703, 1366, 510, 240, 238, 15121, 947, 665, 289, 770,
)
private val PALME_DOR = ms(1456349, 1064213, 915935, 497828, 630240, 496243, 505192, 401246, 374473, 314402, 265169, 86837, 8967, 37903, 2009, 1116, 1777, 1807, 423, 680)
private val BAFTA_BEST_FILM = ms(974576, 872585, 49046, 600583, 581734, 530915, 426426, 359940, 313369, 281957, 85350)
private val GOLDEN_GLOBE_DRAMA = ms(549509, 872585, 804095, 600583, 581734, 530915, 424694, 359940, 376867, 281957, 85350)
private val CRITICS_CHOICE = ms(1064213, 872585, 545611, 600583, 581734, 466272, 426426, 399055, 313369, 314365, 85350)
private val EMMY_SERIES = ts(250307, 126308, 76331, 65494, 1399, 69478, 1396, 1407, 1104, 247767, 124101, 136315, 97546, 61662, 67070, 70796, 2947, 1421)

// ---------------------------------------------------------------------------------------------------- The 24 featured

private val FEATURED_COLLECTIONS = listOf(
    col(
        "under-90", "90 Minutes or Less", "Quick films for a relaxed evening. Every one runs between an hour and an hour and a half.",
        Featured, Metadata, Movies, featured = true, priority = 8, art = m(862),
        sections = listOf(
            movies("Most Popular", "with_runtime.gte" to "60", "with_runtime.lte" to "90", votes = 400),
            movies("Comedies", "with_runtime.gte" to "60", "with_runtime.lte" to "90", "with_genres" to "35", votes = 300),
            movies("Thrillers", "with_runtime.gte" to "60", "with_runtime.lte" to "90", "with_genres" to "53", votes = 300),
            movies("Horror", "with_runtime.gte" to "60", "with_runtime.lte" to "90", "with_genres" to "27", votes = 300),
            movies("Animation", "with_runtime.gte" to "60", "with_runtime.lte" to "90", "with_genres" to "16", votes = 300),
        ),
    ),
    col(
        "hidden-gems", "Hidden Gems", "Highly rated films and series that never had blockbuster attention: strong scores from a few thousand viewers rather than millions.",
        Featured, Editorial, Mixed, featured = true, priority = 6,
        sections = listOf(
            movies(
                "Films", "vote_average.gte" to "7.4", "vote_count.lte" to "6500", "sort_by" to "vote_average.desc",
                "without_genres" to "99,10770,16", "primary_release_date.lte" to "{TWO_YEARS_AGO}", votes = 1500,
            ),
            series("Series", "vote_average.gte" to "8.0", "vote_count.lte" to "1500", "sort_by" to "vote_average.desc", "without_genres" to "10767,10763,16,99,10764", votes = 300),
        ),
    ),
    col(
        "movie-universes", "Movie Universes", "Whole franchises and connected universes, from the MCU and Star Wars to the Conjuring.",
        Featured, Franchise, Mixed, featured = true, priority = 9, art = m(299534),
        children = listOf(
            "mcu", "star-wars", "wizarding-world", "middle-earth", "dceu", "x-men", "spider-man", "batman", "star-trek",
            "jurassic", "fast-furious", "mission-impossible", "james-bond", "john-wick", "conjuring", "alien", "dune", "avatar",
        ),
        affinity = setOf(G.ACTION, G.SCIFI, G.FANTASY, G.ADVENTURE),
    ),
    col(
        "nostalgia-night", "Nostalgia Night", "Childhood favourites from the 80s, 90s and early 2000s.",
        Featured, Editorial, Movies, featured = true, priority = 6, art = m(9340),
        sections = listOf(titles("Childhood Favourites", ms(771, 8587, 8844, 9340, 601, 105, 862, 812, 879, 788, 11528, 2300, 10830, 9820, 808, 10054, 12, 671, 9354, 620, 11806, 1634, 9598, 10414, 10439))),
        affinity = setOf(G.FAMILY, G.ADVENTURE, G.COMEDY),
    ),
    col(
        "twists", "Twists You Won't See Coming", "Mysteries and thrillers whose endings change everything you saw.",
        Featured, Editorial, Movies, featured = true, priority = 5, art = m(11324),
        sections = listOf(titles("Hand-Picked Twists", ms(745, 550, 629, 11324, 77, 1124, 210577, 670, 807, 1933, 1592, 176, 419430, 146233, 489999, 411088, 2832, 206487, 2649, 329865, 21208, 568091))),
        affinity = setOf(G.THRILLER, G.MYSTERY, G.CRIME),
    ),
    col(
        "comfort-tv", "Comfort TV", "Familiar, easygoing series to put on after a long day.",
        Featured, Editorial, Series, featured = true, priority = 7, art = t(2316),
        sections = listOf(titles("Comfort Favourites", ts(1668, 2316, 8592, 48891, 4586, 97546, 61662, 1420, 1421, 1100, 1400, 3452, 34549, 32726, 125935, 18347, 62649, 66573, 68106, 2004, 4556, 52))),
        affinity = setOf(G.COMEDY),
    ),
    col(
        "masterpieces", "Masterpieces", "Essential cinema: films critics and filmmakers keep returning to.",
        Featured, Editorial, Movies, featured = true, priority = 5, art = m(238),
        sections = listOf(titles("The Essentials", ms(238, 240, 289, 15, 62, 346, 424, 680, 769, 278, 947, 426, 496243, 129, 28, 103, 7345, 6977, 155, 843, 872, 389, 539, 1578))),
        affinity = setOf(G.DRAMA, G.CRIME),
    ),
    col(
        "game-to-screen", "Game to Screen", "Films and series adapted from video games.",
        Featured, Metadata, Mixed, featured = true, priority = 5, art = t(100088),
        sections = listOf(
            titles("Series", ts(100088, 94605, 106379, 71024, 52814, 133748, 105248, 108296, 115577, 158300)),
            movies("Films", "with_keywords" to "41645", votes = 200),
        ),
        affinity = setOf(G.ACTION, G.SCIFI, G.TV_SCIFI),
    ),
    col(
        "true-events", "Based on True Events", "Extraordinary real-life stories.",
        Featured, Metadata, Mixed, featured = true, priority = 5, art = m(424),
        sections = listOf(
            movies("Films", "with_keywords" to "9672", votes = 500),
            series("Series", "with_keywords" to "9672", votes = 100),
        ),
        affinity = setOf(G.DRAMA, G.HISTORY),
    ),
    col(
        "one-more-episode", "One More Episode", "Series that are very hard to stop watching.",
        Featured, Editorial, Series, featured = true, priority = 7, art = t(66732),
        sections = listOf(
            titles("Binge Favourites", ts(1396, 66732, 93405, 76331, 136315, 95396, 1399, 71446, 69740, 70523, 76479, 60574, 67744, 117488, 126308, 100088, 63351, 4607, 1973, 2288, 19885, 42009, 60622, 46648)),
            series("Highly Rated", "vote_average.gte" to "8.2", votes = 1500),
        ),
        affinity = setOf(G.DRAMA, G.CRIME, G.MYSTERY),
    ),
    col(
        "time-travel", "Time Travel", "Stories about the past, the future and timelines that split.",
        Featured, Metadata, Mixed, featured = true, priority = 4, art = m(105),
        sections = listOf(
            movies("Films", "with_keywords" to "4379", votes = 400),
            series("Series", "with_keywords" to "4379", votes = 100),
        ),
        affinity = setOf(G.SCIFI, G.TV_SCIFI, G.ADVENTURE),
    ),
    col(
        "visually-stunning", "Visually Stunning", "Films remembered for their images: cinematography, design and visual effects.",
        Featured, Editorial, Movies, featured = true, priority = 5, art = m(335984),
        sections = listOf(titles("Picked for Their Images", ms(335984, 76341, 438631, 693134, 947, 62, 87827, 19995, 76600, 281957, 79, 843, 129, 120467, 530915, 49047, 157336, 569094, 426426, 329865, 1417, 3175, 16642, 8967))),
        affinity = setOf(G.SCIFI, G.ADVENTURE, G.DRAMA),
    ),
    col(
        "complete-saga", "The Complete Saga", "Finished franchises to watch from the first film to the last, in release or story order.",
        Featured, Franchise, Movies, featured = true, priority = 4, art = m(122),
        children = listOf("lord-of-the-rings", "harry-potter", "star-wars-skywalker", "back-to-the-future", "hunger-games", "toy-story", "matrix", "indiana-jones", "the-hobbit", "dark-knight"),
        affinity = setOf(G.FANTASY, G.ADVENTURE, G.SCIFI),
    ),
    col(
        "short-and-sweet", "Short & Sweet", "Series with episodes of 25 minutes or less.",
        Featured, Metadata, Series, featured = true, priority = 3, art = t(136315),
        sections = listOf(
            series("Most Popular", "with_runtime.lte" to "25", "with_runtime.gte" to "10", votes = 300),
            series("Comedies", "with_runtime.lte" to "25", "with_runtime.gte" to "10", "with_genres" to "35", votes = 200),
            series("Animation", "with_runtime.lte" to "25", "with_runtime.gte" to "10", "with_genres" to "16", votes = 200),
        ),
        affinity = setOf(G.COMEDY, G.ANIMATION),
    ),
    col(
        "acclaimed-series", "Critically Acclaimed Series", "Prestige television: the most highly rated series by those who have watched them.",
        Featured, Metadata, Series, featured = true, priority = 4, art = t(76331),
        sections = listOf(
            series("Highest Rated", "vote_average.gte" to "8.3", "sort_by" to "vote_average.desc", "without_genres" to "10767,10763,16,10764", votes = 2000),
            titles("Emmy Winners", EMMY_SERIES),
        ),
        affinity = setOf(G.DRAMA, G.CRIME),
    ),
    col(
        "plot-twist", "What a Plot Twist!", "Films and series built around a revelation.",
        Featured, Metadata, Mixed, featured = true, priority = 3, art = m(1124),
        sections = listOf(
            movies("Films", "with_keywords" to "326438|275311", votes = 400),
            series("Series", "with_keywords" to "326438|275311", votes = 80),
        ),
        affinity = setOf(G.THRILLER, G.MYSTERY),
    ),
    col(
        "book-to-screen", "From Book to Screen", "Literary adaptations, from classics to bestsellers.",
        Featured, Metadata, Mixed, featured = true, priority = 4, art = m(4348),
        sections = listOf(
            movies("Films", "with_keywords" to "818", votes = 800),
            series("Series", "with_keywords" to "818", votes = 200),
        ),
        affinity = setOf(G.DRAMA, G.FANTASY, G.ROMANCE),
    ),
    col(
        "2000s-rewind", "The 2000s Rewind", "Films and series from 2000 to 2009.",
        Featured, Metadata, Mixed, featured = true, priority = 3, art = m(671),
        sections = listOf(movies("Films", *decade(2000, 2009), votes = 1000), series("Series", *decadeTv(2000, 2009), votes = 200)),
    ),
    col(
        "laugh-out-loud", "Laugh Out Loud", "Sitcoms and comedy favourites.",
        Featured, Metadata, Mixed, featured = true, priority = 5, art = t(48891),
        sections = listOf(
            series("Sitcoms", "with_keywords" to "193171", votes = 200),
            movies("Comedy Films", "with_genres" to "35", "without_genres" to "18,27,53", votes = 1000),
        ),
        affinity = setOf(G.COMEDY),
    ),
    col(
        "movie-night-for-two", "Movie Night for Two", "Date-night films: romance, comedy and a little mystery.",
        Featured, Editorial, Movies, featured = true, priority = 4, art = m(313369),
        sections = listOf(titles("Date Night Picks", ms(76, 313369, 50646, 122906, 639, 4348, 11036, 509, 19913, 82693, 18240, 666277, 1072790, 787, 546554, 194, 587792, 1581, 152601, 38, 4951, 384677, 508, 597))),
        affinity = setOf(G.ROMANCE, G.COMEDY),
    ),
    col(
        "award-winners", "Award Winners", "Oscar Best Picture, Emmy best series and Palme d'Or winners.",
        Featured, Metadata, Mixed, featured = true, priority = 5, art = m(872585),
        subtitle = "Winners through the 2025 ceremonies",
        sections = listOf(
            titles("Oscar Best Picture", OSCAR_BEST_PICTURE.take(20)),
            titles("Emmy Best Series", EMMY_SERIES),
            titles("Palme d'Or", PALME_DOR.take(12)),
        ),
        children = listOf("oscar-best-picture", "emmy-series", "palme-dor", "bafta", "golden-globes", "critics-choice"),
        affinity = setOf(G.DRAMA),
    ),
    col(
        "around-the-world", "Around the World", "International films and series, from Seoul to Paris to Mumbai.",
        Featured, Metadata, Mixed, featured = true, priority = 4, art = m(496243),
        children = listOf("korean-dramas", "japanese-cinema", "french-cinema", "bollywood", "spanish-crime", "nordic-noir", "italian-cinema", "latin-american-cinema", "turkish-dramas", "quebec-cinema"),
        sections = listOf(
            movies("Popular International Films", "without_original_language" to "en", votes = 500, rated = false),
            series("Popular International Series", "without_original_language" to "en", votes = 200),
        ),
    ),
    col(
        "just-added", "Just Added", "Films that came out to stream, rent or buy in the last few weeks.",
        Featured, Metadata, Movies, featured = true, priority = 6, art = null,
        sections = listOf(CollectionSection("New to Watch at Home", SectionSource.NewOnDigital)),
    ),
    col(
        "coming-soon", "Coming Soon", "Films arriving to stream, rent or buy soon, and series premiering in the coming months.",
        Featured, Metadata, Mixed, featured = true, priority = 5, art = null,
        sections = listOf(CollectionSection("Coming Soon", SectionSource.ComingSoon)),
    ),
)

// ---------------------------------------------------------------------------------------------------- Universes

private val UNIVERSES = listOf(
    // Superheroes and comics
    col(
        "mcu", "Marvel Cinematic Universe", "Every MCU film and Disney+ series, in release or in-story order.",
        Universes, Franchise, Mixed, art = m(299534), priority = 9, storyOrder = MCU_STORY,
        children = listOf("infinity-saga", "multiverse-saga", "spider-man", "deadpool"),
        sections = listOf(
            titles("Phase One", MCU_PHASE_1), titles("Phase Two", MCU_PHASE_2), titles("Phase Three", MCU_PHASE_3),
            titles("Phase Four", MCU_PHASE_4), titles("Phase Five", MCU_PHASE_5), titles("Phase Six", MCU_PHASE_6),
            titles("Series", MCU_SERIES),
        ),
        affinity = setOf(G.ACTION, G.SCIFI, G.ADVENTURE),
    ),
    col("infinity-saga", "The Infinity Saga", "Phases One to Three, from Iron Man to Far From Home.", Universes, Franchise, Movies, art = m(299536),
        sections = listOf(titles("Phase One", MCU_PHASE_1), titles("Phase Two", MCU_PHASE_2), titles("Phase Three", MCU_PHASE_3)),
        storyOrder = MCU_STORY.filter { it in MCU_PHASE_1 + MCU_PHASE_2 + MCU_PHASE_3 }),
    col("multiverse-saga", "The Multiverse Saga", "Phases Four to Six and the Disney+ series.", Universes, Franchise, Mixed, art = m(634649),
        sections = listOf(titles("Phase Four", MCU_PHASE_4), titles("Phase Five", MCU_PHASE_5), titles("Phase Six", MCU_PHASE_6), titles("Series", MCU_SERIES))),
    col("x-men", "X-Men", "The X-Men films, Wolverine's solo outings and the animated revival.", Universes, Franchise, Mixed,
        sections = listOf(coll("X-Men", 748), coll("Wolverine", 453993), coll("Deadpool", 448150), titles("Animated Series", ts(138502)))),
    col("spider-man", "Spider-Man", "Every live-action Spider-Man and the Spider-Verse.", Universes, Franchise, Mixed, art = m(634649),
        sections = listOf(coll("Sam Raimi Trilogy", 556), coll("The Amazing Spider-Man", 125574), coll("Marvel Cinematic Universe", 531241), coll("Spider-Verse", 573436), titles("Series", ts(138503)))),
    col("batman", "Batman", "The Dark Knight across four decades of film and animation. Each era is its own continuity.", Universes, Franchise, Mixed, art = m(414906),
        children = listOf("dark-knight", "the-batman-epic", "dc-animated"),
        sections = listOf(coll("1989 to 1997", 120794), coll("The Dark Knight Trilogy", 263), titles("The Batman", ms(414906) + ts(194764)), titles("Animated", ts(2098)))),
    col("dceu", "DC Extended Universe", "The connected DC films from Man of Steel to Aquaman and the Lost Kingdom.", Universes, Franchise, Movies, art = m(141052),
        sections = listOf(titles("Release Order", DCEU))),
    col("the-batman-epic", "The Batman Epic Crime Saga", "Matt Reeves' Gotham: The Batman and The Penguin.", Universes, Franchise, Mixed, art = m(414906),
        sections = listOf(titles("Films and Series", ms(414906) + ts(194764)))),
    col("dark-knight", "The Dark Knight Trilogy", "Christopher Nolan's Batman.", Universes, Franchise, Movies, art = m(155), sections = listOf(coll("The Trilogy", 263))),
    col("dc-elseworlds", "DC Elseworlds", "DC stories outside the shared universe.", Universes, Franchise, Mixed, art = m(475557),
        sections = listOf(titles("Films and Series", ms(475557, 889737, 414906) + ts(194764)))),
    col("superman", "Superman", "The Man of Steel from Christopher Reeve to David Corenswet.", Universes, Franchise, Mixed, art = m(1061474),
        sections = listOf(coll("Christopher Reeve Era", 8537), titles("Man of Steel", ms(49521)), titles("Superman (2025)", ms(1061474)), titles("Animated", ts(4303)))),
    col("dc-animated", "DC Animated Universe", "Batman: The Animated Series and the shows that grew from it.", Universes, Franchise, Series, art = t(2098),
        sections = listOf(titles("Series", ts(2098, 4303, 1618, 84200)))),
    col("fantastic-four", "Fantastic Four", "Marvel's first family on screen.", Universes, Franchise, Movies, art = m(617126),
        sections = listOf(coll("2005 to 2007", 9744), titles("The Fantastic Four: First Steps", ms(617126)))),
    col("deadpool", "Deadpool", "The Merc with a Mouth.", Universes, Franchise, Movies, art = m(533535), sections = listOf(coll("Deadpool", 448150))),

    // Fantasy and science fiction
    col(
        "star-wars", "Star Wars", "The Skywalker Saga, the standalone stories and the Disney+ series.",
        Universes, Franchise, Mixed, art = m(181812), logo = m(11), priority = 9, storyOrder = STAR_WARS_STORY,
        children = listOf("star-wars-skywalker", "star-wars-clone-wars", "star-wars-new-republic"),
        sections = listOf(
            coll("The Skywalker Saga", 10),
            titles("A Star Wars Story", ms(330459, 348350)),
            titles("Series", ts(82856, 83867, 4194, 105971, 115036, 114461, 92830, 114479, 202879)),
        ),
        affinity = setOf(G.SCIFI, G.ADVENTURE, G.ACTION),
    ),
    col("star-wars-skywalker", "The Skywalker Saga", "Episodes I to IX.", Universes, Franchise, Movies, art = m(11), logo = m(11),
        sections = listOf(coll("Episodes I to IX", 10)), storyOrder = ms(1893, 1894, 1895, 11, 1891, 1892, 140607, 181808, 181812)),
    col("star-wars-clone-wars", "The Clone Wars Era", "The war between the Republic and the Separatists, and what came after.", Universes, Franchise, Mixed, art = t(4194),
        sections = listOf(titles("Films", ms(1894, 12180, 1895)), titles("Series", ts(4194, 105971)))),
    col("star-wars-new-republic", "New Republic Stories", "After Return of the Jedi: the Mandalorian, Boba Fett and Ahsoka.", Universes, Franchise, Series, art = t(82856),
        sections = listOf(titles("Series", ts(82856, 115036, 114461, 202879)))),
    col(
        "star-trek", "Star Trek", "Every crew of the Enterprise and beyond, on film and television.",
        Universes, Franchise, Mixed, art = t(103516), logo = t(253),
        sections = listOf(
            coll("The Original Series Films", 151), coll("The Next Generation Films", 115570), coll("The Kelvin Timeline", 115575),
            titles("Series", ts(253, 655, 580, 1855, 314, 67198, 85949, 85948, 103516, 106393)),
        ),
        affinity = setOf(G.SCIFI, G.TV_SCIFI),
    ),
    col(
        "wizarding-world", "Wizarding World", "Harry Potter and Fantastic Beasts.",
        Universes, Franchise, Movies, art = m(12445), priority = 7,
        children = listOf("harry-potter", "fantastic-beasts"),
        storyOrder = ms(259316, 338952, 338953, 671, 672, 673, 674, 675, 767, 12444, 12445),
        sections = listOf(coll("Harry Potter", 1241), coll("Fantastic Beasts", 435259)),
        affinity = setOf(G.FANTASY, G.FAMILY, G.ADVENTURE),
    ),
    col("harry-potter", "Harry Potter", "All eight films.", Universes, Franchise, Movies, art = m(671), sections = listOf(coll("The Films", 1241))),
    col("fantastic-beasts", "Fantastic Beasts", "Newt Scamander's adventures, decades before Harry.", Universes, Franchise, Movies, art = m(259316), sections = listOf(coll("The Films", 435259))),
    col(
        "middle-earth", "Middle-earth", "The Lord of the Rings, The Hobbit and the stories around them.",
        Universes, Franchise, Mixed, art = m(122), priority = 7,
        children = listOf("lord-of-the-rings", "the-hobbit"),
        storyOrder = listOf(t(84773), m(839033), m(49051), m(57158), m(122917), m(120), m(121), m(122)),
        sections = listOf(coll("The Lord of the Rings", 119), coll("The Hobbit", 121938), titles("More from Middle-earth", ms(839033) + ts(84773))),
        affinity = setOf(G.FANTASY, G.ADVENTURE),
    ),
    col("lord-of-the-rings", "The Lord of the Rings", "The trilogy.", Universes, Franchise, Movies, art = m(120), sections = listOf(coll("The Trilogy", 119))),
    col("the-hobbit", "The Hobbit", "The trilogy.", Universes, Franchise, Movies, art = m(49051), sections = listOf(coll("The Trilogy", 121938))),
    col("dune", "Dune", "Denis Villeneuve's Dune and the series set ten thousand years before it.", Universes, Franchise, Mixed, art = m(693134),
        sections = listOf(coll("Films", 726871), titles("Series", ts(90228)))),
    col("matrix", "The Matrix", "All four films.", Universes, Franchise, Movies, art = m(603), sections = listOf(coll("The Films", 2344))),
    col("avatar", "Avatar", "James Cameron's Pandora.", Universes, Franchise, Movies, art = m(76600), sections = listOf(coll("The Films", 87096))),
    col("planet-of-the-apes", "Planet of the Apes", "The original series and the reboot.", Universes, Franchise, Movies, art = m(653346),
        sections = listOf(coll("Original Series", 1709), coll("Reboot", 173710))),
    col("alien", "Alien", "The Alien films, the prequels and the crossovers.", Universes, Franchise, Movies, art = m(945961),
        storyOrder = ms(70981, 126889, 348, 945961, 679, 8077, 8078),
        sections = listOf(coll("Alien", 8091), titles("Prequels and Romulus", ms(70981, 126889, 945961)), coll("Alien vs. Predator", 115762))),
    col("predator", "Predator", "The hunters from another world.", Universes, Franchise, Movies, 
        sections = listOf(coll("Predator", 399), coll("Alien vs. Predator", 115762))),
    col("terminator", "Terminator", "Skynet, Sarah Connor and the machines.", Universes, Franchise, Movies, art = m(280), sections = listOf(coll("The Films", 528))),
    col("jurassic", "Jurassic Park & Jurassic World", "Dinosaurs, from Isla Nublar to the world.", Universes, Franchise, Movies, art = m(329), logo = m(329), priority = 6,
        sections = listOf(coll("The Films", 328)), affinity = setOf(G.ADVENTURE, G.SCIFI)),
    col("back-to-the-future", "Back to the Future", "The trilogy.", Universes, Franchise, Movies, art = m(105), sections = listOf(coll("The Trilogy", 264))),
    col("hunger-games", "The Hunger Games", "The Hunger Games films.", Universes, Franchise, Movies, art = m(70160), sections = listOf(coll("The Films", 131635))),

    // Action and adventure
    col("mission-impossible", "Mission: Impossible", "Ethan Hunt and the IMF.", Universes, Franchise, Movies, art = m(353081), priority = 5, sections = listOf(coll("The Films", 87359)), affinity = setOf(G.ACTION, G.THRILLER)),
    col("fast-furious", "Fast & Furious", "Family, cars and physics-defying action.", Universes, Franchise, Movies, art = m(168259), priority = 5, sections = listOf(coll("The Films", 9485)), affinity = setOf(G.ACTION)),
    col("james-bond", "James Bond", "007, from Dr. No to No Time to Die.", Universes, Franchise, Movies, priority = 5, sections = listOf(coll("The Films", 645)), affinity = setOf(G.ACTION, G.THRILLER)),
    col("john-wick", "John Wick", "The world of the High Table.", Universes, Franchise, Movies, art = m(603692), logo = m(245891), priority = 5, sections = listOf(coll("The Films", 404609)), affinity = setOf(G.ACTION, G.THRILLER)),
    col("indiana-jones", "Indiana Jones", "Archaeologist, adventurer.", Universes, Franchise, Movies, art = m(85), sections = listOf(coll("The Films", 84))),
    col("rocky-creed", "Rocky & Creed", "Rocky Balboa and Adonis Creed.", Universes, Franchise, Movies, art = m(1366), logo = m(1366), sections = listOf(coll("Rocky", 1575), coll("Creed", 553717))),
    col("rambo", "Rambo", "John Rambo's war.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 5039))),
    col("bourne", "Bourne", "Jason Bourne and the agency.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 31562))),
    col("karate-kid", "The Karate Kid & Cobra Kai", "Miyagi-Do, Cobra Kai and the next generation.", Universes, Franchise, Mixed, art = t(77169),
        sections = listOf(coll("Films", 8580), titles("Cobra Kai", ts(77169)))),
    col("transformers", "Transformers", "Autobots and Decepticons.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 8650))),
    col("pirates", "Pirates of the Caribbean", "Captain Jack Sparrow's voyages.", Universes, Franchise, Movies, art = m(22), sections = listOf(coll("The Films", 295))),
    col("top-gun", "Top Gun", "Maverick and the Navy's best.", Universes, Franchise, Movies, art = m(361743), sections = listOf(coll("The Films", 531330))),
    col("bad-boys", "Bad Boys", "Mike Lowrey and Marcus Burnett.", Universes, Franchise, Movies, art = m(573435), sections = listOf(coll("The Films", 14890))),
    col("oceans", "Ocean's", "Danny Ocean's crew and the heists.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 304))),
    col("kingsman", "Kingsman", "The independent secret service.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 391860))),
    col("expendables", "The Expendables", "The mercenaries.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 126125))),
    col("transporter", "The Transporter", "Frank Martin's deliveries.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 9518))),

    // Animation and family
    col("toy-story", "Toy Story", "Woody, Buzz and the gang.", Universes, Franchise, Movies, art = m(862), logo = m(862), priority = 5, sections = listOf(coll("The Films", 10194)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("shrek", "Shrek & Puss in Boots", "Far Far Away.", Universes, Franchise, Movies, art = m(808), logo = m(808), sections = listOf(coll("Shrek", 2150), coll("Puss in Boots", 94602)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("despicable-me", "Despicable Me & Minions", "Gru and his Minions.", Universes, Franchise, Movies, sections = listOf(coll("Despicable Me", 86066), coll("Minions", 544669)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("how-to-train-your-dragon", "How to Train Your Dragon", "Hiccup and Toothless.", Universes, Franchise, Movies, sections = listOf(coll("Animated Films", 89137), coll("Live-Action", 1458864)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("kung-fu-panda", "Kung Fu Panda", "Po, the Dragon Warrior.", Universes, Franchise, Mixed, sections = listOf(coll("Films", 77816), titles("Series", ts(39898))), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("ice-age", "Ice Age", "Manny, Sid and Diego.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 8354)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("madagascar", "Madagascar", "From the Central Park Zoo to the wild.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 14740)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("incredibles", "The Incredibles", "The Parr family.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 468222)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("finding-nemo", "Finding Nemo & Finding Dory", "Under the sea with Marlin and Dory.", Universes, Franchise, Movies, art = m(12), sections = listOf(coll("The Films", 137697)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("cars", "Cars", "Lightning McQueen and Radiator Springs.", Universes, Franchise, Mixed, sections = listOf(coll("Films", 87118), titles("Series", ts(114502))), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("monsters-inc", "Monsters, Inc.", "Mike and Sulley.", Universes, Franchise, Mixed, sections = listOf(coll("Films", 137696), titles("Series", ts(90461))), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("hotel-transylvania", "Hotel Transylvania", "Drac's monster resort.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 185103)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("lego", "The LEGO Movies", "Everything is awesome.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 325470)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("croods", "The Croods", "A prehistoric family.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 464577)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("trolls", "Trolls", "Poppy and Branch.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 489724)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("sonic", "Sonic the Hedgehog", "Sonic on film and in his series.", Universes, Franchise, Mixed, art = m(939243), sections = listOf(coll("Films", 720879), titles("Series", ts(115577, 158300))), affinity = setOf(G.FAMILY, G.ACTION)),
    col("pokemon", "Pokémon", "Ash, Pikachu and the films.", Universes, Franchise, Mixed, sections = listOf(titles("Series", ts(60572)), coll("Films", 34055)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("dragon-ball", "Dragon Ball", "Goku from Dragon Ball to Dragon Ball Super.", Universes, Franchise, Mixed, sections = listOf(titles("Series", ts(12609, 12971, 62715)), coll("Dragon Ball Z Films", 425164)), affinity = setOf(G.ANIMATION, G.TV_ACTION)),

    // Horror
    col(
        "conjuring", "The Conjuring Universe", "Ed and Lorraine Warren's cases, Annabelle and the Nun.",
        Universes, Franchise, Movies, art = m(138843), priority = 5,
        sections = listOf(coll("The Conjuring", 313086), coll("Annabelle", 402074), coll("The Nun", 968052), titles("Also in the Universe", ms(480414))),
        affinity = setOf(G.HORROR),
    ),
    col("halloween", "Halloween", "Michael Myers and Haddonfield.", Universes, Franchise, Movies, art = m(948), months = setOf(10), sections = listOf(coll("The Films", 91361)), affinity = setOf(G.HORROR)),
    col("scream", "Scream", "Ghostface's Woodsboro.", Universes, Franchise, Movies, art = m(4232), sections = listOf(coll("The Films", 2602)), affinity = setOf(G.HORROR)),
    col("friday-13th", "Friday the 13th", "Camp Crystal Lake.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 9735)), affinity = setOf(G.HORROR)),
    col("elm-street", "A Nightmare on Elm Street", "Freddy Krueger's dreams.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 8581)), affinity = setOf(G.HORROR)),
    col("saw", "Saw", "Jigsaw's games.", Universes, Franchise, Movies, art = m(176), sections = listOf(coll("The Films", 656)), affinity = setOf(G.HORROR)),
    col("final-destination", "Final Destination", "Death has a design.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 8864)), affinity = setOf(G.HORROR)),
    col("purge", "The Purge", "One night a year.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 256322)), affinity = setOf(G.HORROR, G.THRILLER)),
    col("insidious", "Insidious", "The Further.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 228446)), affinity = setOf(G.HORROR)),
    col("paranormal-activity", "Paranormal Activity", "Found-footage hauntings.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 41437)), affinity = setOf(G.HORROR)),
    col("evil-dead", "Evil Dead", "The Necronomicon.", Universes, Franchise, Movies, sections = listOf(coll("The Films", 1960), coll("Reboot", 1826734)), affinity = setOf(G.HORROR)),
    col("chucky", "Chucky", "Child's Play and the series.", Universes, Franchise, Mixed, sections = listOf(coll("Films", 10455), titles("Series", ts(90462))), affinity = setOf(G.HORROR)),
    col("it", "IT", "Pennywise and Derry.", Universes, Franchise, Mixed, art = m(346364), sections = listOf(coll("Films", 477962), titles("Series", ts(200875))), affinity = setOf(G.HORROR)),
    col("resident-evil", "Resident Evil", "Umbrella Corporation on screen.", Universes, Franchise, Mixed, sections = listOf(coll("Films", 17255), coll("Animated Films", 133352), titles("Series", ts(108296))), affinity = setOf(G.HORROR, G.ACTION)),

    // Television universes
    col("breaking-bad", "Breaking Bad & Better Call Saul", "Albuquerque, from Saul Goodman's start to Jesse Pinkman's escape.", Universes, Franchise, Mixed, art = t(1396), logo = t(1396), priority = 6,
        storyOrder = listOf(t(60059), t(1396), m(559969)),
        sections = listOf(titles("Series", ts(1396, 60059)), titles("Film", ms(559969))), affinity = setOf(G.CRIME, G.DRAMA)),
    col("game-of-thrones", "Game of Thrones", "Westeros, from the Targaryens to the Starks.", Universes, Franchise, Series, art = t(1399), logo = t(1399), priority = 6,
        storyOrder = ts(94997, 224372, 1399), sections = listOf(titles("Series", ts(1399, 94997, 224372))), affinity = setOf(G.DRAMA, G.TV_SCIFI)),
    col("walking-dead", "The Walking Dead", "The main series and every spin-off.", Universes, Franchise, Series, art = t(1402), logo = t(1402),
        sections = listOf(titles("Series", ts(1402, 62286, 94305, 136248, 194583, 211684, 206586))), affinity = setOf(G.DRAMA, G.HORROR)),
    col("yellowstone", "Yellowstone", "The Duttons, across a century and a half.", Universes, Franchise, Series, art = t(73586), logo = t(73586),
        storyOrder = ts(118357, 157744, 73586), sections = listOf(titles("Series", ts(73586, 118357, 157744))), affinity = setOf(G.DRAMA)),
    col("dexter", "Dexter", "Dexter Morgan, from Miami to New York.", Universes, Franchise, Series, art = t(1405), logo = t(1405),
        storyOrder = ts(219937, 1405, 131927, 259909), sections = listOf(titles("Series", ts(1405, 131927, 219937, 259909))), affinity = setOf(G.CRIME, G.DRAMA)),
    col("ncis", "NCIS", "The NCIS series and spin-offs.", Universes, Franchise, Series, art = t(4614), logo = t(4614),
        sections = listOf(titles("Series", ts(4614, 17610, 61387, 124271, 157950, 243006, 247732))), affinity = setOf(G.CRIME)),
    col("csi", "CSI", "Crime Scene Investigation and its spin-offs.", Universes, Franchise, Series, art = t(1431),
        sections = listOf(titles("Series", ts(1431, 1620, 2458, 61811, 122194))), affinity = setOf(G.CRIME)),
    col("law-and-order", "Law & Order", "The police and the prosecutors.", Universes, Franchise, Series, art = t(549), logo = t(549),
        sections = listOf(titles("Series", ts(549, 2734, 4601, 106158))), affinity = setOf(G.CRIME, G.DRAMA)),
    col("fbi", "FBI", "Dick Wolf's FBI series.", Universes, Franchise, Series, art = t(80748), sections = listOf(titles("Series", ts(80748, 94372, 121658))), affinity = setOf(G.CRIME)),
    col("one-chicago", "One Chicago", "Chicago Fire, Chicago P.D. and Chicago Med.", Universes, Franchise, Series, art = t(44006),
        sections = listOf(titles("Series", ts(44006, 58841, 62650))), affinity = setOf(G.DRAMA)),
    col("the-boys", "The Boys", "Vought's supes and the people fighting them.", Universes, Franchise, Series, art = t(76479), logo = t(76479),
        sections = listOf(titles("Series", ts(76479, 205715))), affinity = setOf(G.TV_ACTION, G.TV_SCIFI)),
    col("vampire-diaries", "The Vampire Diaries", "Mystic Falls, the Originals and Legacies.", Universes, Franchise, Series, art = t(18165), logo = t(18165),
        sections = listOf(titles("Series", ts(18165, 46896, 79460))), affinity = setOf(G.DRAMA, G.TV_SCIFI)),
    col("power", "Power", "Ghost and the Power universe.", Universes, Franchise, Series, art = t(54650), logo = t(54650),
        sections = listOf(titles("Series", ts(54650, 97890, 124394, 119845))), affinity = setOf(G.CRIME, G.DRAMA)),
    col("doctor-who", "Doctor Who", "The Doctor, from 1963 to today, and Torchwood.", Universes, Franchise, Series, art = t(57243), logo = t(57243),
        sections = listOf(titles("Series", ts(121, 57243, 239770, 424))), affinity = setOf(G.TV_SCIFI)),
    col("avatar-tla", "Avatar: The Last Airbender", "Aang, Korra and the four nations.", Universes, Franchise, Series, art = t(246), logo = t(246),
        sections = listOf(titles("Series", ts(246, 33880, 82452))), affinity = setOf(G.ANIMATION, G.TV_SCIFI)),
    col("bridgerton", "Bridgerton", "The ton of Regency London.", Universes, Franchise, Series, art = t(91239), logo = t(91239),
        sections = listOf(titles("Series", ts(91239, 196454))), affinity = setOf(G.DRAMA, G.ROMANCE)),
    col("big-bang-theory", "The Big Bang Theory", "Sheldon, Leonard and the Coopers.", Universes, Franchise, Series, art = t(1418), logo = t(1418),
        sections = listOf(titles("Series", ts(1418, 71728, 243875))), affinity = setOf(G.COMEDY)),
    col("the-office", "The Office", "Dunder Mifflin, Scranton.", Universes, Franchise, Series, art = t(2316), logo = t(2316), sections = listOf(titles("Series", ts(2316))), affinity = setOf(G.COMEDY)),
    col("friends", "Friends", "Central Perk and Joey's spin-off.", Universes, Franchise, Series, art = t(1668), logo = t(1668), sections = listOf(titles("Series", ts(1668, 1466))), affinity = setOf(G.COMEDY)),
    col("911", "9-1-1", "The first responders of Los Angeles, Austin and Nashville.", Universes, Franchise, Series, art = t(75219), logo = t(75219),
        sections = listOf(titles("Series", ts(75219, 89393, 284838))), affinity = setOf(G.DRAMA)),
    col("drag-race", "RuPaul's Drag Race", "The main competition and All Stars.", Universes, Franchise, Series, art = t(8514), sections = listOf(titles("Series", ts(8514, 67482)))),
    col("bachelor", "The Bachelor", "The Bachelor, The Bachelorette and Bachelor in Paradise.", Universes, Franchise, Series, art = t(355), sections = listOf(titles("Series", ts(355, 1562, 61190)))),
)

// ---------------------------------------------------------------------------------------------------- Metadata families

private val GENRE_COLLECTIONS = listOf(
    col("action-classics", "Action Classics", "Action films that have held up for decades.", Genres, Metadata, Movies, sections = listOf(movies("Action Classics", "with_genres" to "28", "primary_release_date.lte" to "2005-12-31", "sort_by" to "vote_average.desc", votes = 2000)), affinity = setOf(G.ACTION)),
    col("martial-arts", "Martial Arts", "Fights choreographed like dance.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "779", votes = 300, rated = false), series("Series", "with_keywords" to "779")), affinity = setOf(G.ACTION)),
    col("spy-thrillers", "Spy Thrillers", "Agents, assets and double crosses.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "470", votes = 400), series("Series", "with_keywords" to "470")), affinity = setOf(G.THRILLER, G.ACTION)),
    col("sitcoms", "Sitcoms", "Situation comedies.", Genres, Metadata, Series, sections = listOf(series("Sitcoms", "with_keywords" to "193171", votes = 150)), affinity = setOf(G.COMEDY)),
    col("dark-comedies", "Dark Comedies", "Laughing at what you shouldn't.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "10123", votes = 400), series("Series", "with_keywords" to "10123")), affinity = setOf(G.COMEDY, G.CRIME)),
    col("rom-coms", "Romantic Comedies", "Love, with jokes.", Genres, Metadata, Movies, sections = listOf(movies("Romantic Comedies", "with_genres" to "10749,35", votes = 500)), affinity = setOf(G.ROMANCE, G.COMEDY)),
    col("mockumentaries", "Mockumentaries", "Fiction filmed as if it were real.", Genres, Metadata, Mixed, sections = listOf(series("Series", "with_keywords" to "11800"), movies("Films", "with_keywords" to "11800", votes = 100)), affinity = setOf(G.COMEDY)),
    col("legal-dramas", "Legal Dramas", "Courtrooms, trials and the lawyers who win them.", Genres, Metadata, Mixed, sections = listOf(series("Series", "with_keywords" to "222517|33519"), movies("Films", "with_keywords" to "33519", votes = 300)), affinity = setOf(G.DRAMA, G.CRIME)),
    col("medical-dramas", "Medical Dramas", "Hospitals, surgeons and long shifts.", Genres, Metadata, Series, sections = listOf(series("Medical Dramas", "with_keywords" to "208788|11612", "with_genres" to "18")), affinity = setOf(G.DRAMA)),
    col("detective-stories", "Detective Stories", "Investigators and the cases they crack.", Genres, Metadata, Mixed, sections = listOf(series("Series", "with_keywords" to "703"), movies("Films", "with_keywords" to "703", votes = 400)), affinity = setOf(G.CRIME, G.MYSTERY)),
    col("heists", "Heists", "The plan, the crew and the vault.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "10051", votes = 300), series("Series", "with_keywords" to "10051")), affinity = setOf(G.CRIME, G.THRILLER)),
    col("organized-crime", "Organized Crime", "Families, cartels and syndicates.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "10291|10391", votes = 500), series("Series", "with_keywords" to "10291|10391")), affinity = setOf(G.CRIME)),
    col("psychological-thrillers", "Psychological Thrillers", "Minds under pressure.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "12565", votes = 400), series("Series", "with_keywords" to "12565")), affinity = setOf(G.THRILLER)),
    col("survival-thrillers", "Survival Thrillers", "Stranded, hunted and running out of time.", Genres, Metadata, Movies, sections = listOf(movies("Survival", "with_keywords" to "10349", "with_genres" to "53", votes = 300)), affinity = setOf(G.THRILLER, G.ADVENTURE)),
    col("supernatural-horror", "Supernatural Horror", "Ghosts, demons and possessions.", Genres, Metadata, Movies, sections = listOf(movies("Supernatural Horror", "with_keywords" to "6152|162846|9712|15001", "with_genres" to "27", votes = 300)), affinity = setOf(G.HORROR)),
    col("found-footage", "Found Footage", "Horror shot as if from a recovered camera.", Genres, Metadata, Movies, sections = listOf(movies("Found Footage", "with_keywords" to "163053", votes = 150)), affinity = setOf(G.HORROR)),
    col("space-exploration", "Space Exploration", "Missions to the stars.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "3801|191132", "with_genres" to "878", votes = 400), series("Series", "with_keywords" to "3801|191132")), affinity = setOf(G.SCIFI, G.TV_SCIFI)),
    col("dystopian-futures", "Dystopian Futures", "Tomorrow gone wrong.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "4565", votes = 400), series("Series", "with_keywords" to "4565")), affinity = setOf(G.SCIFI, G.TV_SCIFI)),
    col("cyberpunk", "Cyberpunk", "High tech, low life.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "12190", votes = 200, rated = false), series("Series", "with_keywords" to "12190")), affinity = setOf(G.SCIFI, G.TV_SCIFI)),
    col("epic-fantasy", "Epic Fantasy", "Kingdoms, quests and magic.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "211227|234213", votes = 300), series("Series", "with_keywords" to "211227|234213")), affinity = setOf(G.FANTASY, G.TV_SCIFI)),
    col("romantic-dramas", "Romantic Dramas", "Love stories with something at stake.", Genres, Metadata, Movies, sections = listOf(movies("Romantic Dramas", "with_genres" to "10749,18", "without_genres" to "35", votes = 600)), affinity = setOf(G.ROMANCE, G.DRAMA)),
    col("murder-mysteries", "Murder Mysteries", "Whodunits.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "207046|12570", votes = 300), series("Series", "with_keywords" to "207046|12570")), affinity = setOf(G.MYSTERY, G.CRIME)),
    col("period-pieces", "Period Pieces", "Costume dramas from other centuries.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "15060", votes = 300), series("Series", "with_keywords" to "15060")), affinity = setOf(G.DRAMA, G.HISTORY)),
    col("adult-animation", "Adult Animation", "Animation made for grown-ups.", Genres, Metadata, Series, sections = listOf(series("Adult Animation", "with_keywords" to "161919")), affinity = setOf(G.ANIMATION, G.COMEDY)),
    col("documentary-essentials", "Documentary Essentials", "The most highly rated documentaries.", Genres, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "99", "sort_by" to "vote_average.desc", votes = 500, rated = false), series("Series", "with_genres" to "99", "sort_by" to "vote_average.desc", votes = 200)), affinity = setOf(G.DOCUMENTARY)),
)

private val MOOD_COLLECTIONS = listOf(
    col("feel-good", "Feel-Good Favourites", "Warm, upbeat and well liked.", Moods, Metadata, Movies, sections = listOf(movies("Feel-Good", "with_keywords" to "383896|319357", "vote_average.gte" to "6.8", votes = 300)), affinity = setOf(G.COMEDY, G.FAMILY)),
    col("mind-bending", "Mind-Bending Movies", "Films that fold reality.", Moods, Metadata, Movies, sections = listOf(movies("Mind-Bending", "with_keywords" to "362567|157171|9887", "vote_average.gte" to "6.8", votes = 500)), affinity = setOf(G.SCIFI, G.THRILLER, G.MYSTERY)),
    col("edge-of-your-seat", "Edge of Your Seat", "Tension from start to finish.", Moods, Metadata, Movies, sections = listOf(movies("Thrillers", "with_genres" to "53", "vote_average.gte" to "7", votes = 1500)), affinity = setOf(G.THRILLER)),
    col("prepare-to-cry", "Prepare to Cry", "Films known for making audiences weep.", Moods, Metadata, Movies, sections = listOf(movies("Tearjerkers", "with_keywords" to "156924", votes = 300)), affinity = setOf(G.DRAMA, G.ROMANCE)),
    col("love-is-in-the-air", "Love Is in the Air", "Romance in every form.", Moods, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "10749", votes = 800), series("Series", "with_keywords" to "9840")), affinity = setOf(G.ROMANCE)),
    col("dark-and-twisted", "Dark & Twisted", "Disturbing, unsettling and very well made.", Moods, Metadata, Movies, sections = listOf(movies("Dark & Twisted", "with_keywords" to "12565|295907", "vote_average.gte" to "7", votes = 800)), affinity = setOf(G.THRILLER, G.HORROR)),
    col("pure-adrenaline", "Pure Adrenaline", "Non-stop action.", Moods, Metadata, Movies, sections = listOf(movies("Action", "with_genres" to "28", "vote_average.gte" to "6.8", votes = 2000)), affinity = setOf(G.ACTION)),
    col("escape-reality", "Escape Reality", "Fantasy worlds to disappear into.", Moods, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "14", "vote_average.gte" to "6.8", votes = 1000), series("Series", "with_genres" to "10765", "vote_average.gte" to "7.5", votes = 300)), affinity = setOf(G.FANTASY, G.TV_SCIFI)),
    col("beautifully-weird", "Beautifully Weird", "Surreal and absurd, on purpose.", Moods, Metadata, Movies, sections = listOf(movies("Weird and Wonderful", "with_keywords" to "9887|214655", "vote_average.gte" to "6.8", votes = 300, rated = false)), affinity = setOf(G.COMEDY, G.FANTASY)),
    col("revenge-is-sweet", "Revenge Is Sweet", "Payback stories.", Moods, Metadata, Movies, sections = listOf(movies("Revenge", "with_keywords" to "9748", votes = 500)), affinity = setOf(G.ACTION, G.THRILLER)),
    col("against-all-odds", "Against All Odds", "Underdogs who refuse to give up.", Moods, Metadata, Movies, sections = listOf(movies("Underdogs", "with_keywords" to "240|281585", votes = 300)), affinity = setOf(G.DRAMA)),
    col("trust-no-one", "Trust No One", "Betrayal, conspiracy and secrets.", Moods, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "10085|10410", "with_genres" to "53", votes = 400), series("Series", "with_keywords" to "10410")), affinity = setOf(G.THRILLER, G.MYSTERY)),
    col("dark-humour", "Dark Humour", "Comedy with a bite.", Moods, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "10123|8201", votes = 500), series("Series", "with_keywords" to "10123|8201")), affinity = setOf(G.COMEDY)),
    col("chills-without-gore", "Chills Without Gore", "Scary without the gore: PG-13 and under.", Moods, Metadata, Movies, sections = listOf(movies("Spooky", "with_genres" to "27", "without_keywords" to "10292|$EXPLICIT_KEYWORDS", "certification.lte" to "PG-13", votes = 400)), affinity = setOf(G.HORROR)),
)

private val SITUATION_COLLECTIONS = listOf(
    col("under-2-hours", "Under 2 Hours", "Films that fit a weeknight.", Situations, Metadata, Movies, sections = listOf(movies("Under 2 Hours", "with_runtime.gte" to "80", "with_runtime.lte" to "119", votes = 1500))),
    col("epic-over-3-hours", "Epic Movies Over 3 Hours", "Clear the evening.", Situations, Metadata, Movies, sections = listOf(movies("Over 3 Hours", "with_runtime.gte" to "180", votes = 500, rated = false))),
    col("quick-episodes", "Quick 20-Minute Episodes", "Episodes of about 20 minutes.", Situations, Metadata, Series, sections = listOf(series("Quick Episodes", "with_runtime.gte" to "15", "with_runtime.lte" to "25", votes = 300))),
    col("30-minute-comfort", "30-Minute Comfort Shows", "Half-hour comedies.", Situations, Metadata, Series, sections = listOf(series("Half-Hour Comedies", "with_genres" to "35", "with_runtime.gte" to "18", "with_runtime.lte" to "32", votes = 300)), affinity = setOf(G.COMEDY)),
    col("limited-series", "Limited Series Worth Watching", "Complete stories in one season.", Situations, Metadata, Series, sections = listOf(series("Miniseries", "with_type" to "2", "vote_average.gte" to "7.5", votes = 300))),
    col("complete-series", "Complete Series, No Waiting", "Finished series, every season available.", Situations, Metadata, Series, sections = listOf(series("Ended Series", "with_status" to "3", "vote_average.gte" to "7.8", votes = 1000))),
    col("weekend-binges", "Perfect Weekend Binges", "Ended series that are highly rated.", Situations, Metadata, Series, sections = listOf(series("Weekend Binges", "with_status" to "3", "vote_average.gte" to "8", votes = 500))),
    col("family-movie-night", "Family Movie Night", "Films for every age.", Situations, Metadata, Movies, sections = listOf(movies("Family Films", "with_genres" to "10751", "certification.lte" to "PG", votes = 800)), affinity = setOf(G.FAMILY)),
    col("movies-with-friends", "Movies With Friends", "Crowd-pleasers: comedies and action.", Situations, Metadata, Movies, sections = listOf(movies("Crowd-Pleasers", "with_genres" to "35|28", "vote_average.gte" to "6.8", votes = 3000))),
    col("late-night", "Late-Night Viewing", "Horror and thrillers for after dark.", Situations, Metadata, Movies, sections = listOf(movies("After Dark", "with_genres" to "27|53", "vote_average.gte" to "6.8", votes = 1000)), affinity = setOf(G.HORROR, G.THRILLER)),
    col("background-tv", "Background-Friendly TV", "Reality and competition shows easy to drop in and out of.", Situations, Metadata, Series, sections = listOf(series("Reality & Competition", "with_genres" to "10764", votes = 50))),
    col("watch-with-parents", "Watch With Your Parents", "Films rated PG-13 and under that all ages enjoy.", Situations, Metadata, Movies, sections = listOf(movies("All Ages", "certification.lte" to "PG-13", "vote_average.gte" to "7.2", "without_genres" to "27", votes = 3000))),
)

private val DECADE_COLLECTIONS = listOf(
    col("golden-age", "Golden Age of Hollywood", "1930 to 1959.", Decades, Metadata, Movies, sections = listOf(movies("Golden Age", *decade(1930, 1959), votes = 300, rated = false))),
    col("silent-classics", "Silent Film Classics", "Before the talkies.", Decades, Metadata, Movies, sections = listOf(movies("Silent Era", *decade(1900, 1929), votes = 100, rated = false))),
    col("1950s", "1950s Classics", "Films from the 1950s.", Decades, Metadata, Movies, sections = listOf(movies("1950s", *decade(1950, 1959), votes = 200, rated = false))),
    col("1960s", "1960s Cinema", "Films from the 1960s.", Decades, Metadata, Movies, sections = listOf(movies("1960s", *decade(1960, 1969), votes = 200, rated = false))),
    col("1970s", "1970s Cinema", "Films from the 1970s.", Decades, Metadata, Movies, sections = listOf(movies("1970s", *decade(1970, 1979), votes = 300, rated = false))),
    col("80s-classics", "80s Classics", "Films and series from the 1980s.", Decades, Metadata, Mixed, sections = listOf(movies("Films", *decade(1980, 1989), votes = 800), series("Series", *decadeTv(1980, 1989), votes = 100))),
    col("90s-nostalgia", "90s Nostalgia", "Films and series from the 1990s.", Decades, Metadata, Mixed, sections = listOf(movies("Films", *decade(1990, 1999), votes = 1000), series("Series", *decadeTv(1990, 1999), votes = 150))),
    col("2010s-essentials", "2010s Essentials", "Films and series from the 2010s.", Decades, Metadata, Mixed, sections = listOf(movies("Films", *decade(2010, 2019), votes = 3000), series("Series", *decadeTv(2010, 2019), votes = 800))),
    col("2020s-essentials", "2020s Essentials", "The decade so far.", Decades, Metadata, Mixed, sections = listOf(movies("Films", "primary_release_date.gte" to "2020-01-01", votes = 1500), series("Series", "first_air_date.gte" to "2020-01-01", votes = 400))),
    col("saturday-morning-cartoons", "Saturday Morning Cartoons", "Animated series from the 80s and 90s.", Decades, Metadata, Series, sections = listOf(series("Cartoons", "with_genres" to "16", *decadeTv(1980, 1999), votes = 50)), affinity = setOf(G.ANIMATION)),
    col("classic-nickelodeon", "Classic Nickelodeon", "Nickelodeon series from before 2005.", Decades, Metadata, Series, sections = listOf(series("Nickelodeon", "with_networks" to "13", "first_air_date.lte" to "2004-12-31", votes = 30))),
    col("classic-cartoon-network", "Classic Cartoon Network", "Cartoon Network series from before 2005.", Decades, Metadata, Series, sections = listOf(series("Cartoon Network", "with_networks" to "56", "first_air_date.lte" to "2004-12-31", votes = 30))),
    col("cult-classics", "Cult Classics", "Films with devoted followings.", Decades, Metadata, Movies, sections = listOf(movies("Cult Films", "with_keywords" to "374649", votes = 300, rated = false))),
    col("retro-sci-fi", "Retro Sci-Fi", "Science fiction from before 1990.", Decades, Metadata, Movies, sections = listOf(movies("Retro Sci-Fi", "with_genres" to "878", "primary_release_date.lte" to "1989-12-31", votes = 500, rated = false)), affinity = setOf(G.SCIFI)),
    col("classic-action-heroes", "Classic Action Heroes", "Action from the 80s and 90s.", Decades, Metadata, Movies, sections = listOf(movies("80s and 90s Action", "with_genres" to "28", *decade(1980, 1999), votes = 1000)), affinity = setOf(G.ACTION)),
)

private val AWARD_COLLECTIONS = listOf(
    col("oscar-best-picture", "Oscar Best Picture Winners", "Every Best Picture winner from 1990 to the 2025 ceremony, plus earlier landmarks.", Awards, Editorial, Movies, art = m(872585), subtitle = "Through the 2025 ceremony",
        sections = listOf(titles("Best Picture", OSCAR_BEST_PICTURE))),
    col("emmy-series", "Emmy-Winning Series", "Outstanding Drama and Outstanding Comedy Series winners since 2010.", Awards, Editorial, Series, art = t(126308), subtitle = "Through the 2025 ceremony",
        sections = listOf(titles("Emmy Winners", EMMY_SERIES))),
    col("palme-dor", "Cannes Palme d'Or Winners", "The top prize at Cannes.", Awards, Editorial, Movies, art = m(496243), subtitle = "Selected winners through 2025", sections = listOf(titles("Palme d'Or", PALME_DOR))),
    col("bafta", "BAFTA Best Film Winners", "BAFTA's Best Film since 2015.", Awards, Editorial, Movies, art = m(974576), subtitle = "Through the 2025 ceremony", sections = listOf(titles("Best Film", BAFTA_BEST_FILM))),
    col("golden-globes", "Golden Globe Winners", "Best Motion Picture – Drama since 2015.", Awards, Editorial, Movies, art = m(549509), subtitle = "Through the 2025 ceremony", sections = listOf(titles("Best Drama", GOLDEN_GLOBE_DRAMA))),
    col("critics-choice", "Critics' Choice Winners", "Critics' Choice Best Picture since 2015.", Awards, Editorial, Movies, art = m(466272), subtitle = "Through the 2025 ceremony", sections = listOf(titles("Best Picture", CRITICS_CHOICE))),
    col("acclaimed-films", "Critically Acclaimed Films", "The highest-rated films by the people who have seen them.", Awards, Metadata, Movies, sections = listOf(movies("Highest Rated", "sort_by" to "vote_average.desc", votes = 5000))),
    col("indie-masterpieces", "Independent Film Masterpieces", "Independent films, highly rated.", Awards, Metadata, Movies, sections = listOf(movies("Independent", "with_keywords" to "281237", "vote_average.gte" to "7", votes = 300))),
    col("a24", "A24 Films", "From the studio behind Moonlight and Everything Everywhere All at Once.", Awards, Metadata, Movies, art = m(545611), sections = listOf(movies("A24", "with_companies" to "41077", votes = 200))),
    col("modern-essentials", "Modern Cinema Essentials", "The best-rated films since 2015.", Awards, Metadata, Movies, sections = listOf(movies("Since 2015", "primary_release_date.gte" to "2015-01-01", "sort_by" to "vote_average.desc", votes = 4000))),
    col("essential-docs", "Essential Documentaries", "Highly rated documentaries.", Awards, Metadata, Movies, sections = listOf(movies("Documentaries", "with_genres" to "99", "sort_by" to "vote_average.desc", votes = 800, rated = false))),
)

private val DIRECTOR_COLLECTIONS = listOf(
    col("dir-nolan", "Christopher Nolan", "From Following to Oppenheimer.", Directors, Metadata, Movies, art = m(157336), sections = listOf(directed("Directed by Christopher Nolan", 525))),
    col("dir-spielberg", "Steven Spielberg", "Five decades of blockbusters and dramas.", Directors, Metadata, Movies, art = m(329), sections = listOf(directed("Directed by Steven Spielberg", 488))),
    col("dir-tarantino", "Quentin Tarantino", "Every Tarantino film.", Directors, Metadata, Movies, art = m(680), sections = listOf(directed("Directed by Quentin Tarantino", 138))),
    col("dir-scorsese", "Martin Scorsese", "From Mean Streets to Killers of the Flower Moon.", Directors, Metadata, Movies, art = m(769), sections = listOf(directed("Directed by Martin Scorsese", 1032))),
    col("dir-gerwig", "Greta Gerwig", "Lady Bird, Little Women and Barbie.", Directors, Metadata, Movies, art = m(346698), sections = listOf(directed("Directed by Greta Gerwig", 45400))),
    col("dir-anderson", "Wes Anderson", "Symmetry and pastel.", Directors, Metadata, Movies, art = m(120467), sections = listOf(directed("Directed by Wes Anderson", 5655))),
    col("dir-villeneuve", "Denis Villeneuve", "From Incendies to Dune.", Directors, Metadata, Movies, art = m(438631), sections = listOf(directed("Directed by Denis Villeneuve", 137427))),
    col("dir-hitchcock", "Alfred Hitchcock", "The Master of Suspense.", Directors, Metadata, Movies, art = m(426), sections = listOf(directed("Directed by Alfred Hitchcock", 2636))),
    col("dir-miyazaki", "Hayao Miyazaki", "Studio Ghibli's founder.", Directors, Metadata, Movies, art = m(129), sections = listOf(directed("Directed by Hayao Miyazaki", 608))),
    col("dir-del-toro", "Guillermo del Toro", "Monsters, fairy tales and gothic romance.", Directors, Metadata, Movies, art = m(1417), sections = listOf(directed("Directed by Guillermo del Toro", 10828))),
)

private val INTERNATIONAL_COLLECTIONS = listOf(
    col("korean-dramas", "Korean Dramas", "K-dramas.", International, Metadata, Series, art = t(93405), sections = listOf(series("Korean Dramas", "with_original_language" to "ko", "with_genres" to "18", votes = 50))),
    col("korean-thrillers", "Korean Thrillers", "Crime and suspense from South Korea.", International, Metadata, Movies, sections = listOf(movies("Korean Thrillers", "with_original_language" to "ko", "with_genres" to "53|80", votes = 150, rated = false))),
    col("japanese-cinema", "Japanese Cinema", "Films from Japan.", International, Metadata, Movies, art = m(346), sections = listOf(movies("Japanese Films", "with_original_language" to "ja", "without_genres" to "16", votes = 200, rated = false), movies("Japanese Animation", "with_original_language" to "ja", "with_genres" to "16", votes = 200, rated = false))),
    col("japanese-tv", "Japanese Television", "Live-action series from Japan.", International, Metadata, Series, sections = listOf(series("Japanese Series", "with_original_language" to "ja", "without_genres" to "16,10767,10763", votes = 20))),
    col("bollywood", "Bollywood", "Hindi cinema.", International, Metadata, Movies, sections = listOf(movies("Hindi Films", "with_original_language" to "hi", votes = 100, rated = false))),
    col("indian-crime-thrillers", "Indian Crime Thrillers", "Crime and suspense from India.", International, Metadata, Movies, sections = listOf(movies("Indian Thrillers", "with_origin_country" to "IN", "with_genres" to "80|53", votes = 100, rated = false))),
    col("french-cinema", "French Cinema", "Films in French.", International, Metadata, Movies, art = m(194), sections = listOf(movies("French Films", "with_original_language" to "fr", votes = 300, rated = false))),
    col("french-tv", "French-Language Television", "Series in French.", International, Metadata, Series, sections = listOf(series("French Series", "with_original_language" to "fr", votes = 30))),
    col("spanish-crime", "Spanish Crime Dramas", "Crime series from Spain.", International, Metadata, Series, art = t(71446), sections = listOf(series("Spanish Crime", "with_origin_country" to "ES", "with_genres" to "80", votes = 30))),
    col("italian-cinema", "Italian Cinema", "Films in Italian.", International, Metadata, Movies, sections = listOf(movies("Italian Films", "with_original_language" to "it", votes = 200, rated = false))),
    col("british-crime", "British Crime Dramas", "Crime series from the UK.", International, Metadata, Series, sections = listOf(series("British Crime", "with_origin_country" to "GB", "with_genres" to "80", votes = 80))),
    col("british-comedies", "British Comedies", "Comedy from the UK.", International, Metadata, Mixed, sections = listOf(series("Series", "with_origin_country" to "GB", "with_genres" to "35", votes = 80), movies("Films", "with_origin_country" to "GB", "with_genres" to "35", votes = 300))),
    col("nordic-noir", "Nordic Noir", "Crime from Scandinavia and the Nordics.", International, Metadata, Series, sections = listOf(series("Nordic Noir", "with_origin_country" to "SE|DK|NO|IS|FI", "with_genres" to "80|9648", votes = 20))),
    col("turkish-dramas", "Turkish Dramas", "Series from Turkey.", International, Metadata, Series, sections = listOf(series("Turkish Dramas", "with_original_language" to "tr", "with_genres" to "18", votes = 20))),
    col("latin-american-cinema", "Latin American Cinema", "Films from Mexico, Argentina, Brazil, Colombia and Chile.", International, Metadata, Movies, sections = listOf(movies("Latin American Films", "with_origin_country" to "MX|AR|BR|CO|CL", votes = 150, rated = false))),
    col("european-arthouse", "European Arthouse", "Highly rated European dramas.", International, Metadata, Movies, sections = listOf(movies("Arthouse", "with_origin_country" to "FR|DE|IT|ES|SE|DK|BE|PL|AT|RO", "with_genres" to "18", "vote_average.gte" to "7.2", "vote_count.lte" to "3000", votes = 150, rated = false))),
    col("canadian-cinema", "Canadian Cinema", "Films from Canada.", International, Metadata, Movies, sections = listOf(movies("Canadian Films", "with_origin_country" to "CA", votes = 200, rated = false))),
    col("canadian-tv", "Canadian Television", "Series from Canada.", International, Metadata, Series, art = t(61662), sections = listOf(series("Canadian Series", "with_origin_country" to "CA", votes = 50))),
    col("quebec-cinema", "Québec Cinema", "French-language films from Canada.", International, Metadata, Movies, sections = listOf(movies("Québec Films", "with_origin_country" to "CA", "with_original_language" to "fr", votes = 20, rated = false))),
)

private val ANIMATION_COLLECTIONS = listOf(
    col("disney-classics", "Disney Animated Classics", "Walt Disney Animation Studios before 2000.", Animation, Metadata, Movies, art = m(8587), sections = listOf(movies("Classics", "with_companies" to "6125", "primary_release_date.lte" to "1999-12-31", votes = 300, rated = false)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("pixar", "Pixar", "Every Pixar feature.", Animation, Metadata, Movies, art = m(862), sections = listOf(movies("Pixar", "with_companies" to "3", "with_genres" to "16", votes = 300)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("dreamworks", "DreamWorks Animation", "From Shrek to Kung Fu Panda.", Animation, Metadata, Movies, art = m(808), sections = listOf(movies("DreamWorks", "with_companies" to "521", votes = 300)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("ghibli", "Studio Ghibli", "Miyazaki, Takahata and the Ghibli films.", Animation, Metadata, Movies, art = m(129), sections = listOf(movies("Studio Ghibli", "with_companies" to "10342", votes = 100, rated = false)), affinity = setOf(G.ANIMATION, G.FANTASY)),
    col("illumination", "Illumination", "Minions and more.", Animation, Metadata, Movies, sections = listOf(movies("Illumination", "with_companies" to "6704", votes = 200)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("aardman", "Aardman", "Wallace & Gromit and Chicken Run.", Animation, Metadata, Movies, sections = listOf(movies("Aardman", "with_companies" to "297", votes = 50, rated = false)), affinity = setOf(G.ANIMATION, G.FAMILY)),
    col("stop-motion", "Stop-Motion Animation", "Animated frame by frame.", Animation, Metadata, Movies, sections = listOf(movies("Stop-Motion", "with_keywords" to "10121", votes = 100, rated = false)), affinity = setOf(G.ANIMATION)),
    col("anime-beginners", "Anime for Beginners", "The most widely loved anime series.", Animation, Metadata, Series, sections = listOf(series("Popular Anime", "with_original_language" to "ja", "with_genres" to "16", "vote_average.gte" to "8", votes = 1000)), affinity = setOf(G.ANIMATION)),
    col("shonen-anime", "Shonen Anime", "Battles, rivals and power-ups.", Animation, Metadata, Series, sections = listOf(series("Shonen", "with_keywords" to "207826", "with_genres" to "16", votes = 100)), affinity = setOf(G.ANIMATION, G.TV_ACTION)),
    col("dark-fantasy-anime", "Dark Fantasy Anime", "Grim worlds and hard choices.", Animation, Metadata, Series, sections = listOf(series("Dark Fantasy", "with_keywords" to "177895", "with_genres" to "16", "with_original_language" to "ja", votes = 50)), affinity = setOf(G.ANIMATION, G.TV_SCIFI)),
    col("slice-of-life-anime", "Slice-of-Life Anime", "Everyday life, beautifully drawn.", Animation, Metadata, Series, sections = listOf(series("Slice of Life", "with_keywords" to "9914", "with_genres" to "16", "with_original_language" to "ja", votes = 30)), affinity = setOf(G.ANIMATION)),
    col("romantic-anime", "Romantic Anime", "Love stories in anime.", Animation, Metadata, Series, sections = listOf(series("Romance", "with_keywords" to "9840", "with_genres" to "16", "with_original_language" to "ja", votes = 30)), affinity = setOf(G.ANIMATION, G.ROMANCE)),
    col("mecha-anime", "Mecha Anime", "Giant robots.", Animation, Metadata, Series, sections = listOf(series("Mecha", "with_keywords" to "10046", "with_genres" to "16", votes = 30)), affinity = setOf(G.ANIMATION, G.TV_SCIFI)),
    col("sports-anime", "Sports Anime", "Competition, drawn.", Animation, Metadata, Series, sections = listOf(series("Sports Anime", "with_keywords" to "6075", "with_genres" to "16", "with_original_language" to "ja", votes = 30)), affinity = setOf(G.ANIMATION)),
    col("preschool", "Preschool Favourites", "For the youngest viewers.", Animation, Metadata, Series, sections = listOf(series("Kids", "with_genres" to "10762", votes = 30)), affinity = setOf(G.KIDS)),
    col("magical-adventures", "Magical Adventures", "Family films full of magic.", Animation, Metadata, Movies, sections = listOf(movies("Magical", "with_genres" to "14,10751", votes = 500)), affinity = setOf(G.FAMILY, G.FANTASY)),
    col("animal-adventures", "Animal Adventures", "Talking animals and the people who love them.", Animation, Metadata, Movies, sections = listOf(movies("Animals", "with_keywords" to "267848|361118", "with_genres" to "10751", votes = 300)), affinity = setOf(G.FAMILY)),
    col("family-laughs", "Family-Friendly Laughs", "Comedies for the whole family.", Animation, Metadata, Movies, sections = listOf(movies("Family Comedies", "with_genres" to "10751,35", "certification.lte" to "PG", votes = 500)), affinity = setOf(G.FAMILY, G.COMEDY)),
)

private val SEASONAL_COLLECTIONS = listOf(
    col("christmas-classics", "Christmas Classics", "Holiday films for December.", Seasonal, Metadata, Movies, art = m(771), months = setOf(11, 12), priority = 7, sections = listOf(movies("Christmas", "with_keywords" to "207317", votes = 300))),
    col("holiday-rom-coms", "Holiday Rom-Coms", "Christmas romances.", Seasonal, Metadata, Movies, art = m(1581), months = setOf(11, 12), priority = 5, sections = listOf(movies("Holiday Romance", "with_keywords" to "207317", "with_genres" to "10749", votes = 100))),
    col("animated-christmas", "Animated Christmas", "Christmas cartoons for the family.", Seasonal, Metadata, Movies, months = setOf(11, 12), priority = 4, sections = listOf(movies("Animated Christmas", "with_keywords" to "207317", "with_genres" to "16", votes = 100))),
    col("halloween-essentials", "Halloween Essentials", "Scary films for October.", Seasonal, Metadata, Movies, art = m(948), months = setOf(10), priority = 7, sections = listOf(movies("Halloween", "with_keywords" to "3335", votes = 200))),
    col("family-frights", "Family-Friendly Frights", "Spooky, not scary.", Seasonal, Metadata, Movies, art = m(10439), months = setOf(10), priority = 5, sections = listOf(movies("Family Frights", "with_keywords" to "3335|616|162846", "with_genres" to "10751", votes = 200))),
    col("paranormal-nights", "Paranormal Nights", "Ghosts and haunted houses.", Seasonal, Metadata, Movies, months = setOf(10), priority = 4, sections = listOf(movies("Paranormal", "with_keywords" to "162846|3358", "with_genres" to "27", votes = 300))),
    col("valentines", "Valentine's Movie Night", "Romance for February.", Seasonal, Metadata, Movies, months = setOf(2), priority = 6, sections = listOf(movies("Romance", "with_genres" to "10749", "vote_average.gte" to "7", votes = 1000))),
    col("romantic-classics", "Romantic Classics", "Love stories from before 1980.", Seasonal, Metadata, Movies, months = setOf(2), sections = listOf(movies("Romantic Classics", "with_genres" to "10749", "primary_release_date.lte" to "1979-12-31", votes = 300, rated = false))),
    col("summer-blockbusters", "Summer Blockbusters", "Big action and adventure.", Seasonal, Metadata, Movies, months = setOf(6, 7, 8), priority = 5, sections = listOf(movies("Blockbusters", "with_genres" to "28|12", votes = 5000))),
    col("summer-adventures", "Summer Adventures", "Summer holidays and beaches.", Seasonal, Metadata, Movies, months = setOf(6, 7, 8), sections = listOf(movies("Summer", "with_keywords" to "13088|14714|966", votes = 200))),
    col("road-trips", "Road Trips", "Journeys by car.", Seasonal, Metadata, Movies, months = setOf(5, 6, 7, 8), sections = listOf(movies("Road Trips", "with_keywords" to "7312|167043", votes = 300))),
    col("cozy-winter", "Cozy Winter Nights", "Snowy, wintry films.", Seasonal, Metadata, Movies, months = setOf(1, 2, 12), sections = listOf(movies("Winter", "with_keywords" to "1442|10794", votes = 300))),
    col("new-years", "New Year's Favourites", "Films set at New Year.", Seasonal, Metadata, Movies, months = setOf(12, 1), sections = listOf(movies("New Year's Eve", "with_keywords" to "613", votes = 100))),
    col("fresh-starts", "Fresh Starts", "Stories about new beginnings.", Seasonal, Metadata, Movies, months = setOf(1), sections = listOf(movies("New Beginnings", "with_keywords" to "253309", votes = 100))),
    // Episode collections: hand-curated episode lists, each verified against TMDB (see HolidayEpisodes). Browsable all
    // year; featured on Home in season.
    col("christmas-episodes", "Christmas Episodes", "The Christmas episodes of favourite series, from Friends to The Simpsons.",
        Seasonal, Editorial, Series, months = setOf(11, 12), priority = 7, episodes = "christmas-episodes", affinity = setOf(G.COMEDY)),
    col("halloween-episodes", "Halloween Episodes", "Treehouses of Horror, Halloween heists and costume contests.",
        Seasonal, Editorial, Series, months = setOf(10), priority = 7, episodes = "halloween-episodes", affinity = setOf(G.COMEDY)),
)

private val DOCUMENTARY_COLLECTIONS = listOf(
    col("true-crime", "True Crime", "Real crimes, investigated.", Documentaries, Metadata, Mixed, sections = listOf(series("Series", "with_genres" to "99", "with_keywords" to "33722|10714", votes = 30), movies("Films", "with_genres" to "99", "with_keywords" to "33722|10714", votes = 50, rated = false)), affinity = setOf(G.DOCUMENTARY, G.CRIME)),
    col("unsolved-mysteries", "Unsolved Mysteries", "Cases still open.", Documentaries, Metadata, Mixed, sections = listOf(series("Series", "with_genres" to "99", "with_keywords" to "172225|210662", votes = 10), movies("Films", "with_genres" to "99", "with_keywords" to "172225|210662", votes = 20, rated = false))),
    col("historical-events", "Historical Events", "History as it happened.", Documentaries, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "99,36", votes = 100, rated = false), series("Series", "with_genres" to "99", "with_keywords" to "1956", votes = 20))),
    col("nature", "Nature", "Wildlife and the natural world.", Documentaries, Metadata, Mixed, sections = listOf(series("Series", "with_genres" to "99", "with_keywords" to "221355|9902", votes = 30), movies("Films", "with_genres" to "99", "with_keywords" to "221355|9902", votes = 50, rated = false))),
    col("space-docs", "Space", "Documentaries about space.", Documentaries, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "99", "with_keywords" to "9882|252634|191132", votes = 30, rated = false), series("Series", "with_genres" to "99", "with_keywords" to "9882|252634", votes = 10))),
    col("science-tech", "Science & Technology", "How things work.", Documentaries, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "99", "with_keywords" to "287067|1576", votes = 30, rated = false), series("Series", "with_genres" to "99", "with_keywords" to "287067|1576", votes = 10))),
    col("music-docs", "Music Documentaries", "Artists, bands and concerts.", Documentaries, Metadata, Movies, sections = listOf(movies("Music Documentaries", "with_genres" to "99", "with_keywords" to "246377", votes = 30, rated = false))),
    col("extraordinary-lives", "Extraordinary Lives", "Biographical documentaries.", Documentaries, Metadata, Movies, sections = listOf(movies("Lives", "with_genres" to "99", "with_keywords" to "5565", votes = 50, rated = false))),
    col("food-travel", "Food & Travel", "Cooking, eating and the places in between.", Documentaries, Metadata, Series, sections = listOf(series("Food & Travel", "with_genres" to "99", "with_keywords" to "10637|1918|9935", votes = 10))),
    col("investigative", "Investigative Journalism", "Reporters uncovering the story.", Documentaries, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "99", "with_keywords" to "917", votes = 30, rated = false), series("Series", "with_genres" to "99", "with_keywords" to "917", votes = 10))),
    col("scandals", "Scandals", "When it all came out.", Documentaries, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "99", "with_keywords" to "3692", votes = 20, rated = false), series("Series", "with_genres" to "99", "with_keywords" to "3692", votes = 10))),
)

private val SPORTS_COLLECTIONS = listOf(
    col("inspirational-sports", "Inspirational Sports Movies", "Underdogs and comebacks.", Sports, Metadata, Movies, sections = listOf(movies("Sports Movies", "with_keywords" to "6075", "with_genres" to "18", votes = 300))),
    col("legendary-athletes", "Legendary Athletes", "Documentaries about the greats.", Sports, Metadata, Mixed, sections = listOf(movies("Films", "with_genres" to "99", "with_keywords" to "6075", votes = 50, rated = false), series("Series", "with_genres" to "99", "with_keywords" to "6075", votes = 20))),
    col("hockey", "Hockey Movies & Documentaries", "On the ice.", Sports, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "6483|289584", votes = 30, rated = false), series("Series", "with_keywords" to "6483|289584", votes = 5))),
    col("basketball", "Basketball on Screen", "Courtside stories.", Sports, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "6496", votes = 100, rated = false), series("Series", "with_keywords" to "6496", votes = 10))),
    col("football", "Football Movies", "Gridiron stories.", Sports, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "579", votes = 100), series("Series", "with_keywords" to "579", votes = 10))),
    col("motorsport", "Racing & Motorsport", "Speed on four wheels.", Sports, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "9571|298953|233981", votes = 100, rated = false), series("Series", "with_keywords" to "9571|233981", votes = 10))),
    col("soccer", "Soccer Stories", "The beautiful game.", Sports, Metadata, Mixed, sections = listOf(movies("Films", "with_keywords" to "13042", votes = 50, rated = false), series("Series", "with_keywords" to "13042", votes = 10))),
    col("combat-sports", "Boxing & Combat Sports", "In the ring and the cage.", Sports, Metadata, Movies, sections = listOf(movies("Combat Sports", "with_keywords" to "209476|156159", votes = 200))),
    col("rivalries", "Greatest Sports Rivalries", "Competitors who defined each other.", Sports, Metadata, Movies, sections = listOf(movies("Rivalries", "with_keywords" to "9823", "with_genres" to "18|99", votes = 100, rated = false))),
    col("sports-docuseries", "Sports Docuseries", "Behind the scenes, season by season.", Sports, Metadata, Series, sections = listOf(series("Docuseries", "with_genres" to "99", "with_keywords" to "6075", votes = 10))),
)

private val STUDIO_COLLECTIONS = listOf(
    col("studio-disney", "Disney", "Walt Disney Pictures.", Studios, Metadata, Movies, sections = listOf(movies("Disney", "with_companies" to "2", votes = 500))),
    col("studio-pixar", "Pixar Animation Studios", "Every Pixar film.", Studios, Metadata, Movies, art = m(12), sections = listOf(movies("Pixar", "with_companies" to "3", votes = 300))),
    col("studio-marvel", "Marvel Studios", "Films produced by Marvel Studios.", Studios, Metadata, Movies, art = m(24428), sections = listOf(movies("Marvel Studios", "with_companies" to "420", votes = 500))),
    col("studio-lucasfilm", "Lucasfilm", "Star Wars, Indiana Jones and more.", Studios, Metadata, Movies, art = m(11), sections = listOf(movies("Lucasfilm", "with_companies" to "1", votes = 300))),
    col("studio-warner", "Warner Bros.", "Warner Bros. Pictures.", Studios, Metadata, Movies, sections = listOf(movies("Warner Bros.", "with_companies" to "174", votes = 1000))),
    col("studio-universal", "Universal", "Universal Pictures.", Studios, Metadata, Movies, sections = listOf(movies("Universal", "with_companies" to "33", votes = 1000))),
    col("studio-paramount", "Paramount", "Paramount Pictures.", Studios, Metadata, Movies, sections = listOf(movies("Paramount", "with_companies" to "4", votes = 1000))),
    col("studio-sony", "Sony Pictures", "Columbia Pictures and Sony Pictures.", Studios, Metadata, Movies, sections = listOf(movies("Sony Pictures", "with_companies" to "5|34", votes = 1000))),
    col("studio-20th", "20th Century Studios", "20th Century Fox and 20th Century Studios.", Studios, Metadata, Movies, sections = listOf(movies("20th Century", "with_companies" to "25|127928", votes = 1000))),
    col("studio-dreamworks", "DreamWorks", "DreamWorks Animation.", Studios, Metadata, Movies, sections = listOf(movies("DreamWorks", "with_companies" to "521", votes = 300))),
    col("studio-a24", "A24", "A24 films.", Studios, Metadata, Movies, sections = listOf(movies("A24", "with_companies" to "41077", votes = 200))),
    // Networks: these are series a network commissioned (TMDB's original network), not what it streams today.
    col("network-hbo", "HBO", "Series that premiered on HBO.", Studios, Metadata, Series, art = t(1399), sections = listOf(series("HBO Originals", "with_networks" to "49", votes = 200))),
    col("network-fx", "FX", "Series that premiered on FX.", Studios, Metadata, Series, art = t(136315), sections = listOf(series("FX Originals", "with_networks" to "88", votes = 100))),
    col("network-bbc", "BBC", "Series that premiered on BBC One and BBC Two.", Studios, Metadata, Series, art = t(19885), sections = listOf(series("BBC Originals", "with_networks" to "4|332", votes = 100))),
    col("network-apple", "Apple Originals", "Series made for Apple TV.", Studios, Metadata, Series, art = t(95396), sections = listOf(series("Apple Originals", "with_networks" to "2552", votes = 100))),
    col("network-netflix", "Netflix Originals", "Series made for Netflix.", Studios, Metadata, Series, art = t(66732), sections = listOf(series("Netflix Originals", "with_networks" to "213", votes = 300))),
    col("network-prime", "Prime Video Originals", "Series made for Prime Video.", Studios, Metadata, Series, art = t(76479), sections = listOf(series("Prime Video Originals", "with_networks" to "1024", votes = 200))),
)

// ---------------------------------------------------------------------------------------------------- Catalog

object ExploreCatalog {
    val all: List<ExploreCollection> = FEATURED_COLLECTIONS + UNIVERSES + GENRE_COLLECTIONS + MOOD_COLLECTIONS +
        SITUATION_COLLECTIONS + DECADE_COLLECTIONS + AWARD_COLLECTIONS + DIRECTOR_COLLECTIONS + INTERNATIONAL_COLLECTIONS +
        ANIMATION_COLLECTIONS + SEASONAL_COLLECTIONS + DOCUMENTARY_COLLECTIONS + SPORTS_COLLECTIONS + STUDIO_COLLECTIONS

    private val byId: Map<String, ExploreCollection> = all.associateBy { it.id }

    operator fun get(id: String): ExploreCollection? = byId[id]

    /**
     * Universes whose titles all share one fictional continuity, used by Continue Your Universe. Collections that mix
     * continuities (Batman across eras, Star Trek with the Kelvin films, live-action remakes) are deliberately absent.
     */
    val continuityIds: List<String> = listOf(
        "mcu", "star-wars", "wizarding-world", "middle-earth", "dune", "dceu", "dc-animated", "the-batman-epic",
        "conjuring", "breaking-bad", "game-of-thrones", "walking-dead", "yellowstone", "dexter", "ncis", "csi",
        "law-and-order", "fbi", "one-chicago", "the-boys", "vampire-diaries", "power", "doctor-who", "bridgerton",
        "big-bang-theory", "friends", "911", "chucky", "it", "cars", "monsters-inc", "kung-fu-panda",
    )

    /** The 24 featured collections, in catalog order. */
    val featured: List<ExploreCollection> get() = all.filter { it.featured && it.published }

    /** Published collections grouped by category, in category order. */
    fun byCategory(): List<Pair<CollectionCategory, List<ExploreCollection>>> =
        CollectionCategory.entries.mapNotNull { category ->
            all.filter { it.category == category && it.published }.takeIf { it.isNotEmpty() }?.let { category to it }
        }

    fun children(collection: ExploreCollection): List<ExploreCollection> =
        collection.children.mapNotNull { byId[it] }.filter { it.published }
}
