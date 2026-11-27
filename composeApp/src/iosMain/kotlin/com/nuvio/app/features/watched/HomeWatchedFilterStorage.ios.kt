package com.nuvio.app.features.watched

import platform.Foundation.NSUserDefaults

internal actual object HomeWatchedFilterStorage {
    private const val key = "home_hide_watched_rows"

    actual fun load(): Boolean? {
        val defaults = NSUserDefaults.standardUserDefaults
        return if (defaults.objectForKey(key) != null) defaults.boolForKey(key) else null
    }

    actual fun save(hide: Boolean) {
        NSUserDefaults.standardUserDefaults.setBool(hide, forKey = key)
    }
}
