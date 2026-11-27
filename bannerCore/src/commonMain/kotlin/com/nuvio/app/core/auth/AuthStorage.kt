package com.nuvio.app.core.auth

/** Where the anonymous-user id is kept. The platform (SharedPreferences, UserDefaults...) supplies the [Backend]. */
object AuthStorage {
    interface Backend {
        fun loadAnonymousUserId(): String?
        fun saveAnonymousUserId(userId: String)
        fun clearAnonymousUserId()
    }

    var backend: Backend? = null

    fun loadAnonymousUserId(): String? = backend?.loadAnonymousUserId()
    fun saveAnonymousUserId(userId: String) { backend?.saveAnonymousUserId(userId) }
    fun clearAnonymousUserId() { backend?.clearAnonymousUserId() }
}
