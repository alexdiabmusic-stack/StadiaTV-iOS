package com.nuvio.app.core.sync

import platform.Foundation.NSUserDefaults

object PlatformSyncClientIdentityStorage : SyncClientIdentityStorage.Backend {
    private const val clientIdKey = "client_instance_id"

    override fun loadClientId(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(clientIdKey)

    override fun saveClientId(clientId: String) {
        NSUserDefaults.standardUserDefaults.setObject(clientId, forKey = clientIdKey)
    }
}
