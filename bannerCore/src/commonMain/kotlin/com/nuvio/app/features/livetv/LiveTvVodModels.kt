package com.nuvio.app.features.livetv

enum class LiveTvVodKind { Movies, Series }

data class LiveTvVodCategory(
    val id: String,
    val name: String,
)

data class LiveTvVodItem(
    val id: String,
    val remoteId: String,
    val kind: LiveTvVodKind,
    val name: String,
    val posterUrl: String? = null,
    val categoryId: String? = null,
    val rating: Double? = null,
    val plot: String? = null,
    val year: String? = null,
    val extension: String? = null,
    val addedSeconds: Long? = null,
)

data class LiveTvVodEpisode(
    val id: String,
    val season: Int,
    val episodeNumber: Int,
    val title: String,
    val plot: String? = null,
    val imageUrl: String? = null,
    val durationText: String? = null,
    val streamUrl: String,
    val extension: String,
)

data class LiveTvVodCatalog(
    val categories: List<LiveTvVodCategory> = emptyList(),
    val items: List<LiveTvVodItem> = emptyList(),
)

/** What the app shell needs to open an On Demand title in the regular (seekable) player. */
data class LiveTvVodPlayback(
    val id: String,
    val title: String,
    val streamUrl: String,
    val headers: Map<String, String>,
    val streamType: String?,
    val posterUrl: String?,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val episodeTitle: String? = null,
    val episodeThumbnail: String? = null,
)

data class LiveTvVodCatalogState(
    val isLoading: Boolean = false,
    val hasLoaded: Boolean = false,
    val errorMessage: String? = null,
    val catalog: LiveTvVodCatalog = LiveTvVodCatalog(),
)
