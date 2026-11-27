package com.nuvio.app.core.sync

import android.content.Context
import android.content.SharedPreferences

object PlatformSyncClientIdentityStorage : SyncClientIdentityStorage.Backend {
    private const val preferencesName = "nuvio_sync_client_identity"
    private const val clientIdKey = "client_instance_id"

    private var preferences: SharedPreferences? = null

    fun initialize(context: Context) {
        preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    }

    override fun loadClientId(): String? =
        preferences?.getString(clientIdKey, null)

    override fun saveClientId(clientId: String) {
        preferences
            ?.edit()
            ?.putString(clientIdKey, clientId)
            ?.apply()
    }
}
