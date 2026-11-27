package com.nuvio.app.features.letterboxd

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.UIKitView
import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.alloc
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.readValue
import kotlinx.cinterop.refTo
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.value
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.CoreFoundation.*
import platform.CoreGraphics.CGRectZero
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSURL
import platform.Foundation.NSURLRequest
import platform.Security.*
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebsiteDataStore
import kotlin.coroutines.resume

@OptIn(ExperimentalForeignApi::class)
internal actual object PlatformLetterboxdSecrets : LetterboxdSecretStore {
    actual override fun read(profileId: Int): String? = query(profileId) { query ->
        CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue)
        CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne)
        memScoped {
            val result = alloc<CFTypeRefVar>()
            val status = SecItemCopyMatching(query, result.ptr)
            if (status == errSecItemNotFound) return@memScoped null
            check(status == errSecSuccess) { "Unable to read the Letterboxd session (OSStatus $status)" }
            val data: CFDataRef = result.value?.reinterpret() ?: return@memScoped null
            try {
                val bytes = CFDataGetBytePtr(data) ?: return@memScoped null
                ByteArray(CFDataGetLength(data).toInt()) { bytes[it].toByte() }.decodeToString()
            } finally {
                CFRelease(data)
            }
        }
    }

    actual override fun write(profileId: Int, value: String?) = query(profileId) { query ->
        if (value == null) {
            val status = SecItemDelete(query)
            check(status == errSecSuccess || status == errSecItemNotFound) { "Unable to remove the Letterboxd session (OSStatus $status)" }
        } else {
            val bytes = value.encodeToByteArray().toUByteArray()
            require(bytes.isNotEmpty())
            val data = CFDataCreate(null, bytes.refTo(0), bytes.size.toLong()) ?: error("Unable to encode the Letterboxd session")
            val attributes = dictionary()
            try {
                CFDictionarySetValue(attributes, kSecValueData, data)
                val update = SecItemUpdate(query, attributes)
                if (update == errSecItemNotFound) {
                    CFDictionarySetValue(query, kSecValueData, data)
                    // Stays on this device: never part of a backup or another device's Keychain.
                    CFDictionarySetValue(query, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
                    val added = SecItemAdd(query, null)
                    check(added == errSecSuccess) { "Unable to save the Letterboxd session (OSStatus $added)" }
                } else {
                    check(update == errSecSuccess) { "Unable to update the Letterboxd session (OSStatus $update)" }
                }
            } finally {
                CFRelease(attributes)
                CFRelease(data)
            }
        }
    }

    private fun dictionary(): CFMutableDictionaryRef =
        CFDictionaryCreateMutable(null, 0L, kCFTypeDictionaryKeyCallBacks.ptr, kCFTypeDictionaryValueCallBacks.ptr) ?: error("Unable to create the Keychain query")

    private inline fun <T> query(profileId: Int, block: (CFMutableDictionaryRef) -> T): T {
        val service = CFStringCreateWithCString(null, "com.nuvio.media.letterboxd", kCFStringEncodingUTF8) ?: error("Unable to encode the Keychain service")
        val account = CFStringCreateWithCString(null, "profile.$profileId", kCFStringEncodingUTF8) ?: error("Unable to encode the Keychain account")
        val query = dictionary()
        try {
            CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword)
            CFDictionarySetValue(query, kSecAttrService, service)
            CFDictionarySetValue(query, kSecAttrAccount, account)
            return block(query)
        } finally {
            CFRelease(query); CFRelease(account); CFRelease(service)
        }
    }
}

internal actual fun createLetterboxdHttpClient(): HttpClient = HttpClient(Darwin) {
    followRedirects = false
    expectSuccess = false
    install(HttpTimeout) {
        requestTimeoutMillis = 30_000
        connectTimeoutMillis = 15_000
        socketTimeoutMillis = 30_000
    }
    engine {
        configureSession {
            // The session's cookies are added by hand and read from Set-Cookie: nothing is kept by the system.
            HTTPShouldSetCookies = false
            HTTPCookieStorage = null
        }
    }
}

private const val SETTINGS_URL = "https://letterboxd.com/settings/"
private const val READ_USERNAME_SCRIPT =
    "(function(){try{var i=document.querySelector('input[name=username]');return i&&i.value?i.value:'';}catch(e){return '';}})()"

@OptIn(ExperimentalForeignApi::class)
@Composable
internal actual fun LetterboxdSignInWebView(
    modifier: Modifier,
    onSignedIn: (cookies: Map<String, String>, userAgent: String, username: String?) -> Unit,
) {
    val current = rememberUpdatedState(onSignedIn)
    val webView = remember {
        WKWebView(
            frame = CGRectZero.readValue(),
            // Nothing from this sign-in is kept by the web view: the session lives in the Keychain, one per profile.
            configuration = WKWebViewConfiguration().apply { websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore() },
        ).apply {
            NSURL.URLWithString(LetterboxdSignInSupport.SIGN_IN_URL)?.let { loadRequest(NSURLRequest.requestWithURL(it)) }
        }
    }

    LaunchedEffect(webView) {
        var sentToSettings = false
        while (true) {
            delay(1_000)
            val host = webView.URL?.host.orEmpty()
            if (!host.endsWith(LetterboxdSignInSupport.HOST)) continue
            val cookies = webView.cookies().filter { it.domain.trimStart('.').endsWith(LetterboxdSignInSupport.HOST) }.associate { it.name to it.value }
            if (!LetterboxdSignInSupport.isSignedIn(cookies.keys)) continue
            if (!sentToSettings) {
                // Signed in: the account page names the member, and is read inside the browser, which the site trusts.
                sentToSettings = true
                NSURL.URLWithString(SETTINGS_URL)?.let { webView.loadRequest(NSURLRequest.requestWithURL(it)) }
                continue
            }
            if (webView.URL?.path?.startsWith("/settings") != true || webView.loading) continue
            val username = webView.javaScript(READ_USERNAME_SCRIPT)?.trim()?.takeIf { it.isNotEmpty() }
            val agent = webView.javaScript("navigator.userAgent").orEmpty().ifBlank { "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" }
            webView.setHidden(true)
            current.value(cookies, agent, username)
            break
        }
    }

    DisposableEffect(webView) { onDispose { webView.stopLoading() } }

    UIKitView(factory = { webView }, modifier = modifier)
}

@OptIn(ExperimentalForeignApi::class)
private suspend fun WKWebView.cookies(): List<NSHTTPCookie> = suspendCancellableCoroutine { cont ->
    configuration.websiteDataStore.httpCookieStore.getAllCookies { list -> cont.resume(list.orEmpty().filterIsInstance<NSHTTPCookie>()) }
}

@OptIn(ExperimentalForeignApi::class)
private suspend fun WKWebView.javaScript(script: String): String? = suspendCancellableCoroutine { cont ->
    evaluateJavaScript(script) { result, _ -> cont.resume(result as? String) }
}
