package com.nuvio.app.features.watched

import android.content.Context
import android.content.SharedPreferences

internal actual object HomeWatchedFilterStorage {
    private const val preferencesName = "nuvio_home_watched_filter"
    private const val key = "hide"
    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

    actual fun load(): Boolean? = preferences?.let { if (it.contains(key)) it.getBoolean(key, true) else null }

    actual fun save(hide: Boolean) {
        preferences?.edit()?.putBoolean(key, hide)?.apply()
    }
}
