package com.nuvio.app.core.network

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class DnsProvider(val storageId: String, val displayName: String) {
    SYSTEM("system", "System"),
    CLOUDFLARE("cloudflare", "Cloudflare"),
    GOOGLE("google", "Google"),
    ADGUARD("adguard", "AdGuard"),
    QUAD9("quad9", "Quad9"),
    ;

    companion object {
        fun fromStorage(id: String?): DnsProvider = entries.firstOrNull { it.storageId == id } ?: SYSTEM
    }
}

/** Custom DNS is a platform capability. The platform supplies the [Backend]; without one it is unsupported. */
object DnsPlatform {
    interface Backend {
        val isSupported: Boolean
        fun load(): String?
        fun save(storageId: String)
        fun apply(provider: DnsProvider)
    }

    var backend: Backend? = null

    val isSupported: Boolean get() = backend?.isSupported ?: false
    fun load(): String? = backend?.load()
    fun save(storageId: String) { backend?.save(storageId) }
    fun apply(provider: DnsProvider) { backend?.apply(provider) }
}

object DnsSettingsRepository {
    val isSupported: Boolean get() = DnsPlatform.isSupported

    private val _provider = MutableStateFlow(DnsProvider.SYSTEM)
    val provider: StateFlow<DnsProvider> = _provider.asStateFlow()
    private var loaded = false

    fun ensureLoaded() {
        if (loaded) return
        loaded = true
        _provider.value = DnsProvider.fromStorage(DnsPlatform.load())
    }

    fun setProvider(provider: DnsProvider) {
        ensureLoaded()
        if (_provider.value == provider) return
        _provider.value = provider
        DnsPlatform.save(provider.storageId)
        DnsPlatform.apply(provider)
    }
}

/** The HTTP engine the platform wants Ktor to use, or null for the default one. */
object PlatformHttpEngine {
    var factory: (() -> io.ktor.client.engine.HttpClientEngine?)? = null
}

fun platformHttpEngine(): io.ktor.client.engine.HttpClientEngine? = PlatformHttpEngine.factory?.invoke()
