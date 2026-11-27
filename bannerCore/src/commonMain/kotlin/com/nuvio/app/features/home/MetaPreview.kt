package com.nuvio.app.features.home

import com.nuvio.app.features.details.MetaExternalRating

data class MetaPreview(
    val id: String,
    val type: String,
    val name: String,
    val poster: String? = null,
    val banner: String? = null,
    val logo: String? = null,
    val posterShape: PosterShape = PosterShape.Poster,
    val description: String? = null,
    val releaseInfo: String? = null,
    val rawReleaseDate: String? = null,
    val popularity: Double? = null,
    val voteCount: Int? = null,
    val imdbRating: String? = null,
    val genres: List<String> = emptyList(),
    val rawPosterUrl: String? = null,
    val landscapePoster: String? = null,
    val rawLandscapePosterUrl: String? = null,
    val runtime: String? = null,
    val status: String? = null,
    val ageRating: String? = null,
    val language: String? = null,
    val externalRatings: List<MetaExternalRating> = emptyList(),
)

fun MetaPreview.stableKey(): String = "$type:$id"

enum class PosterShape {
    Poster,
    Square,
    Landscape,
}
