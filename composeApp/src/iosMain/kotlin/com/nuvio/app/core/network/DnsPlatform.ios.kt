package com.nuvio.app.core.network

internal object PlatformDnsPlatform : DnsPlatform.Backend {
    override val isSupported: Boolean = false
    override fun load(): String? = null
    override fun save(storageId: String) = Unit
    override fun apply(provider: DnsProvider) = Unit
}

internal fun platformHttpEngineImpl(): io.ktor.client.engine.HttpClientEngine? = null
