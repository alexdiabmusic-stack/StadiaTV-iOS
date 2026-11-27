package com.nuvio.app.features.watching.domain

data class WatchingContentRef(
    val type: String,
    val id: String,
)

fun watchedKey(
    content: WatchingContentRef,
    seasonNumber: Int? = null,
    episodeNumber: Int? = null,
): String = "${content.type.trim()}:${content.id.trim()}:${seasonNumber ?: -1}:${episodeNumber ?: -1}"
