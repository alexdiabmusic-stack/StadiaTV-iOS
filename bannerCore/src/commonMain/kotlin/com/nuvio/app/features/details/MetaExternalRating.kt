package com.nuvio.app.features.details

data class MetaExternalRating(
    val source: String,
    val value: Double,
    val isCertified: Boolean = false,
)
