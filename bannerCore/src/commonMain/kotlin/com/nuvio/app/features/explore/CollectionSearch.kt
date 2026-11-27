package com.nuvio.app.features.explore

/**
 * Finds collections for a typed query, for Search. It matches a collection's title, subtitle, family ("Awards & Prestige"),
 * description and a short list of other names people use (MCU, Avengers, HP, Xmas), so "marvel" finds the Marvel universe and
 * "christmas" finds every holiday collection. It never touches the network, so it can run on every keystroke.
 */
object CollectionSearch {
    /** Other names for a collection, keyed by what a person might type. Every target must be a real collection (tested). */
    internal val ALIASES: Map<String, List<String>> = mapOf(
        "marvel" to listOf("mcu", "infinity-saga", "multiverse-saga", "studio-marvel"),
        "mcu" to listOf("mcu"),
        "avengers" to listOf("infinity-saga", "mcu"),
        "dc" to listOf("dceu", "dc-elseworlds", "dc-animated", "batman", "superman"),
        "star wars" to listOf("star-wars-skywalker", "star-wars-clone-wars", "star-wars-new-republic", "studio-lucasfilm"),
        "skywalker" to listOf("star-wars-skywalker"),
        "hp" to listOf("harry-potter", "fantastic-beasts"),
        "hogwarts" to listOf("harry-potter"),
        "wizarding world" to listOf("harry-potter", "fantastic-beasts"),
        "lotr" to listOf("lord-of-the-rings", "the-hobbit"),
        "tolkien" to listOf("lord-of-the-rings", "the-hobbit"),
        "middle earth" to listOf("lord-of-the-rings", "the-hobbit"),
        "007" to listOf("james-bond"),
        "bond" to listOf("james-bond"),
        "xmas" to listOf("christmas-classics", "christmas-romance", "holiday-rom-coms", "animated-christmas", "christmas-episodes"),
        "holiday" to listOf("christmas-classics", "holiday-rom-coms", "christmas-romance", "new-years"),
        "hallmark" to listOf("christmas-romance", "holiday-rom-coms"),
        "oscars" to listOf("oscar-best-picture"),
        "oscar" to listOf("oscar-best-picture"),
        "academy award" to listOf("oscar-best-picture"),
        "best picture" to listOf("oscar-best-picture"),
        "emmys" to listOf("emmy-series"),
        "emmy" to listOf("emmy-series"),
        "cannes" to listOf("palme-dor"),
        "short films" to listOf("under-90", "under-2-hours"),
        "quick" to listOf("under-90", "under-2-hours", "quick-episodes"),
        "kdrama" to listOf("korean-dramas"),
        "k-drama" to listOf("korean-dramas"),
        "ghibli" to listOf("ghibli"),
        "pixar" to listOf("pixar", "studio-pixar"),
        "fast and furious" to listOf("fast-furious"),
        "mi" to listOf("mission-impossible"),
    )

    private fun norm(text: String): String =
        text.lowercase().map { if (it.isLetterOrDigit()) it else ' ' }.joinToString("").split(' ').filter { it.isNotBlank() }.joinToString(" ")

    /** Collections that match [query], best first. A query under two characters finds nothing. */
    fun search(query: String, limit: Int = 8): List<ExploreCollection> {
        val q = norm(query)
        if (q.length < 2) return emptyList()
        val words = q.split(' ')
        val aliasHits = ALIASES.filterKeys { alias -> alias == q || (q.length >= 3 && alias.startsWith(q)) || (alias.length >= 3 && q.startsWith(alias)) }.values.flatten()
        val scored = ExploreCatalog.all.filter { it.published }.mapNotNull { c ->
            val title = norm(c.title)
            val rest = norm(listOfNotNull(c.subtitle, c.category.title, c.description).joinToString(" "))
            val titleWords = title.split(' ')
            val score = when {
                title == q -> 100
                title.startsWith(q) -> 85
                c.id in aliasHits -> 75
                words.all { w -> titleWords.any { it.startsWith(w) } } -> 65
                words.all { w -> w in title || w in rest } && (words.any { it in title }) -> 45
                words.all { w -> w in title || w in rest } -> 25
                else -> 0
            }
            if (score == 0) null else Triple(c, score, if (c.featured) 1 else 0)
        }
        return scored.sortedWith(compareByDescending<Triple<ExploreCollection, Int, Int>> { it.second }.thenByDescending { it.third }.thenByDescending { it.first.priority })
            .map { it.first }.take(limit)
    }
}
