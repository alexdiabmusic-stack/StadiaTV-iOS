package com.nuvio.app.core.network

import android.content.Context
import android.content.SharedPreferences

internal object PlatformDnsPlatform : DnsPlatform.Backend {
    private const val preferencesName = "nuvio_network"
    private const val providerKey = "dns_provider"
    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.applicationContext.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        NuvioDns.provider = DnsProvider.fromStorage(load())
    }

    override val isSupported: Boolean = true

    override fun load(): String? = preferences?.getString(providerKey, null)

    override fun save(storageId: String) {
        preferences?.edit()?.putString(providerKey, storageId)?.apply()
    }

    override fun apply(provider: DnsProvider) {
        NuvioDns.provider = provider
    }
}

internal fun platformHttpEngineImpl(): io.ktor.client.engine.HttpClientEngine? =
    io.ktor.client.engine.okhttp.OkHttp.create { preconfigured = SharedOkHttpClient.base }
