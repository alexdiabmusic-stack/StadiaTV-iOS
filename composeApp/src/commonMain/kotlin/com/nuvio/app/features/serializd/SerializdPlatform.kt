package com.nuvio.app.features.serializd

import io.ktor.client.HttpClient

/**
 * Protected storage for each profile's Serializd sign-in: the email, the password (Serializd has no refresh token, so signing in
 * again needs it) and the current token. The Keychain on iOS, Keystore-encrypted storage on Android; never plain preferences, never
 * backed up, never shared between profiles.
 */
internal expect object PlatformSerializdSecrets : SerializdSecretStore {
    override fun read(profileId: Int): String?
    override fun write(profileId: Int, value: String?)
}

/**
 * An HTTP client with no cookie jar, no redirects and a request timeout longer than the one the transport enforces (Serializd's
 * host cold-starts after idling, so a reply can take close to a minute). The transport decides what a timeout means for a write.
 */
internal expect fun createSerializdHttpClient(): HttpClient
