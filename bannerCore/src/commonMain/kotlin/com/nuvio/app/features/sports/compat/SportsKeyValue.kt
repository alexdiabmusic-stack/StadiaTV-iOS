package com.nuvio.app.features.sports.compat

/** A few remembered flags and strings for the Sports hub (for example "the alerts offer was shown"). */
interface SportsKeyValueBackend {
    fun getString(key: String): String?
    fun putString(key: String, value: String?)
}

object SportsKeyValue {
    var backend: SportsKeyValueBackend = object : SportsKeyValueBackend {
        private val memory = HashMap<String, String>()
        override fun getString(key: String): String? = memory[key]
        override fun putString(key: String, value: String?) { if (value == null) memory.remove(key) else memory[key] = value }
    }

    fun getString(key: String): String? = backend.getString(key)
    fun putString(key: String, value: String?) = backend.putString(key, value)
}
