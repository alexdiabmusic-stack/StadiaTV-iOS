package com.nuvio.app.features.sports.compat

import platform.Foundation.NSUserDefaults

object IosSportsKeyValue : SportsKeyValueBackend {
    private val defaults get() = NSUserDefaults.standardUserDefaults
    override fun getString(key: String): String? = defaults.stringForKey("sports_hub.$key")
    override fun putString(key: String, value: String?) { if (value == null) defaults.removeObjectForKey("sports_hub.$key") else defaults.setObject(value, "sports_hub.$key") }
}
