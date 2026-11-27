package com.nuvio.app.features.tmdb

/** What the TMDB-backed code needs from the host app: the API key and the metadata language. */
object TmdbRuntime {
    var apiKey: () -> String = { "" }
    var language: () -> String = { "en-US" }
}

/** Today's date and the clock, so shared code does not depend on a platform date provider. */
object CoreClock {
    /** Today's local date as yyyy-MM-dd. The host app replaces this with its local-date provider. */
    var todayProvider: () -> String = { kotlin.time.Clock.System.now().toString().take(10) }

    fun todayIsoDate(): String = todayProvider()
    fun nowMs(): Long = kotlin.time.Clock.System.now().toEpochMilliseconds()
}

/** A tiny persistent string store for caches (name + key). The host app supplies the backend. */
object CoreKeyValue {
    interface Backend {
        fun getString(store: String, key: String): String?
        fun putString(store: String, key: String, value: String)
    }

    var backend: Backend? = null

    fun getString(store: String, key: String): String? = backend?.getString(store, key)
    fun putString(store: String, key: String, value: String) { backend?.putString(store, key, value) }
}
