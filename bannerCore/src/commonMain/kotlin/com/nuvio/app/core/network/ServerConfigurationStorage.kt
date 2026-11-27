package com.nuvio.app.core.network

/** Where a custom server configuration is kept. The platform supplies the [Backend]. */
object ServerConfigurationStorage {
    interface Backend {
        fun loadCustom(): ServerConfiguration?
        fun saveCustom(configuration: ServerConfiguration): Boolean
        fun useOfficial(): Boolean
    }

    var backend: Backend? = null

    fun loadCustom(): ServerConfiguration? = backend?.loadCustom()
    fun saveCustom(configuration: ServerConfiguration): Boolean = backend?.saveCustom(configuration) ?: false
    fun useOfficial(): Boolean = backend?.useOfficial() ?: true
}
