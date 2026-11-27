package com.nuvio.app.features.sports.compat

/** Small text files the Sports hub keeps on the device (saved feeds, tables, channel matches, what you follow). */
interface LiveTvFilesBackend {
    fun exists(dir: String, name: String): Boolean
    /** When the file was last written (epoch ms), or 0 when it doesn't exist. */
    fun lastModified(dir: String, name: String): Long
    fun readSmall(dir: String, name: String): String?
    fun writeSmall(dir: String, name: String, text: String)
}

object LiveTvFiles {
    var backend: LiveTvFilesBackend = object : LiveTvFilesBackend {
        private val memory = HashMap<String, Pair<String, Long>>()
        override fun exists(dir: String, name: String) = memory.containsKey("$dir/$name")
        override fun lastModified(dir: String, name: String) = memory["$dir/$name"]?.second ?: 0L
        override fun readSmall(dir: String, name: String): String? = memory["$dir/$name"]?.first
        override fun writeSmall(dir: String, name: String, text: String) { memory["$dir/$name"] = text to 0L }
    }

    fun exists(dir: String, name: String): Boolean = backend.exists(dir, name)
    fun lastModified(dir: String, name: String): Long = backend.lastModified(dir, name)
    fun readSmall(dir: String, name: String): String? = backend.readSmall(dir, name)
    fun writeSmall(dir: String, name: String, text: String) = backend.writeSmall(dir, name, text)
}

object LiveTvDirs {
    const val STATE = "state"
    /** The Sports hub's saved feeds, tables and channel matches. */
    const val SPORTS = "sports"
}
