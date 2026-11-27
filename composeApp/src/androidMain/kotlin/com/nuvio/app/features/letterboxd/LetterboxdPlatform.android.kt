package com.nuvio.app.features.letterboxd

import android.annotation.SuppressLint
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.nuvio.app.core.network.createApiHttpClient
import io.ktor.client.HttpClient
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal actual object PlatformLetterboxdSecrets : LetterboxdSecretStore {
    private const val keyAlias = "com.nuvio.media.letterboxd.session.v1"
    private lateinit var preferences: android.content.SharedPreferences
    private val lock = Any()

    fun initialize(context: Context) {
        preferences = context.applicationContext.getSharedPreferences("nuvio_letterboxd_auth", Context.MODE_PRIVATE)
    }

    actual override fun read(profileId: Int): String? = synchronized(lock) {
        if (!::preferences.isInitialized) return@synchronized null
        val key = "profile.$profileId"
        val value = preferences.getString(key, null) ?: return@synchronized null
        try {
            val parts = value.split('.', limit = 2)
            require(parts.size == 2)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, decode(parts[0])))
            cipher.updateAAD("$keyAlias:$key".toByteArray(Charsets.UTF_8))
            cipher.doFinal(decode(parts[1])).toString(Charsets.UTF_8)
        } catch (_: Exception) {
            if (!preferences.edit().remove(key).commit()) throw IOException("Unable to clear the Letterboxd session")
            null
        }
    }

    actual override fun write(profileId: Int, value: String?) = synchronized(lock) {
        val key = "profile.$profileId"
        val editor = preferences.edit()
        if (value == null) {
            editor.remove(key)
        } else {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, secretKey())
            cipher.updateAAD("$keyAlias:$key".toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            editor.putString(key, "${encode(cipher.iv)}.${encode(encrypted)}")
        }
        if (!editor.commit()) throw IOException("Unable to save the Letterboxd session")
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build(),
            )
            generateKey()
        }
    }

    private fun encode(value: ByteArray): String = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun decode(value: String): ByteArray = Base64.decode(value, Base64.NO_WRAP)
}

// The shared client has no cookie jar and does not follow redirects: the transport does both by hand.
internal actual fun createLetterboxdHttpClient(): HttpClient = createApiHttpClient()

private const val SETTINGS_URL = "https://letterboxd.com/settings/"
private const val READ_USERNAME_SCRIPT =
    "(function(){try{var i=document.querySelector('input[name=username]');return i&&i.value?i.value:'';}catch(e){return '';}})()"

@SuppressLint("SetJavaScriptEnabled")
@Composable
internal actual fun LetterboxdSignInWebView(
    modifier: Modifier,
    onSignedIn: (cookies: Map<String, String>, userAgent: String, username: String?) -> Unit,
) {
    val current = rememberUpdatedState(onSignedIn)
    val cookieManager = CookieManager.getInstance()
    var webViewRef: WebView? = null
    AndroidView(
        modifier = modifier,
        factory = { context ->
            // The system web view shares cookies between apps' sign-ins: start clean so no other session is picked up.
            cookieManager.removeAllCookies(null)
            WebView(context).apply {
                webViewRef = this
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                var sentToSettings = false
                var delivered = false
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String?) {
                        if (delivered || url == null || !url.contains(LetterboxdSignInSupport.HOST)) return
                        val cookies = parseCookies(cookieManager.getCookie("https://${LetterboxdSignInSupport.HOST}"))
                        if (!LetterboxdSignInSupport.isSignedIn(cookies.keys)) return
                        if (!sentToSettings) { sentToSettings = true; view.loadUrl(SETTINGS_URL); return }
                        if (!url.contains("/settings")) return
                        delivered = true
                        view.evaluateJavascript(READ_USERNAME_SCRIPT) { raw ->
                            val username = raw?.trim('"')?.takeIf { it.isNotEmpty() && it != "null" }
                            val agent = view.settings.userAgentString
                            cookieManager.removeAllCookies(null)
                            current.value(cookies, agent, username)
                        }
                    }
                }
                loadUrl(LetterboxdSignInSupport.SIGN_IN_URL)
            }
        },
    )
    DisposableEffect(Unit) { onDispose { webViewRef?.stopLoading(); webViewRef?.destroy() } }
}

private fun parseCookies(header: String?): Map<String, String> =
    header.orEmpty().split(';').map { it.trim() }.filter { it.contains('=') }.associate { it.substringBefore('=') to it.substringAfter('=') }
