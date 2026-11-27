package com.nuvio.app.features.letterboxd

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import io.ktor.client.HttpClient

/** Protected storage for each profile's Letterboxd session (the Keychain on iOS, Keystore-encrypted storage on Android). */
internal expect object PlatformLetterboxdSecrets : LetterboxdSecretStore {
    override fun read(profileId: Int): String?
    override fun write(profileId: Int, value: String?)
}

/** An HTTP client that never keeps or sends cookies of its own: the session adds the Cookie header and reads Set-Cookie. */
internal expect fun createLetterboxdHttpClient(): HttpClient

/**
 * The member's own Letterboxd sign-in, in a web view that keeps nothing afterwards. When the site reports them signed in, the
 * web view is read once for the session cookies, the browser identity (user agent) and, when its account page shows it, the
 * username, then reports them. BannerTV never sees the password.
 */
@Composable
internal expect fun LetterboxdSignInWebView(
    modifier: Modifier,
    onSignedIn: (cookies: Map<String, String>, userAgent: String, username: String?) -> Unit,
)
