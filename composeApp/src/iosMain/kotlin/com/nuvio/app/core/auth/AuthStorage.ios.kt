package com.nuvio.app.core.auth

import platform.Foundation.NSUserDefaults

object PlatformAuthStorage : AuthStorage.Backend {
    private const val KEY_ANONYMOUS_USER_ID = "anonymous_user_id"

    override fun loadAnonymousUserId(): String? =
        NSUserDefaults.standardUserDefaults.stringForKey(KEY_ANONYMOUS_USER_ID)

    override fun saveAnonymousUserId(userId: String) {
        NSUserDefaults.standardUserDefaults.setObject(userId, forKey = KEY_ANONYMOUS_USER_ID)
    }

    override fun clearAnonymousUserId() {
        NSUserDefaults.standardUserDefaults.removeObjectForKey(KEY_ANONYMOUS_USER_ID)
    }
}
