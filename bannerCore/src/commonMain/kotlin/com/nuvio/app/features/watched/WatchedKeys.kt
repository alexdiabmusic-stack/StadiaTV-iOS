package com.nuvio.app.features.watched

import com.nuvio.app.features.watching.domain.WatchingContentRef
import com.nuvio.app.features.watching.domain.watchedKey

fun watchedItemKey(
    type: String,
    id: String,
    season: Int? = null,
    episode: Int? = null,
): String = watchedKey(
    content = WatchingContentRef(type = type, id = id),
    seasonNumber = season,
    episodeNumber = episode,
)

fun watchedItemTypeAliases(type: String): Set<String> = when (type.trim().lowercase()) {
    "movie", "film" -> setOf("movie", "film")
    "series", "show", "tv", "tvshow", "anime" -> setOf("series", "show", "tv", "tvshow", "anime")
    else -> setOf(type.trim())
}

fun watchedItemKeys(
    type: String,
    id: String,
    season: Int? = null,
    episode: Int? = null,
): Set<String> = watchedItemTypeAliases(type).mapTo(linkedSetOf()) { alias ->
    watchedItemKey(
        type = alias,
        id = id,
        season = season,
        episode = episode,
    )
}
