package com.nuvio.app.mac

import com.nuvio.app.core.auth.AuthStorage
import com.nuvio.app.core.build.AppFeaturePolicy
import com.nuvio.app.core.build.TrailerPlaybackMode
import com.nuvio.app.core.platform.CoreConfig
import com.nuvio.app.core.platform.CoreRuntime
import com.nuvio.app.core.platform.ProfileContext
import com.nuvio.app.core.sync.SyncClientIdentityStorage
import com.nuvio.app.core.text.CoreStrings
import com.nuvio.app.core.text.CoreText
import com.nuvio.app.features.addons.AddonHttp
import com.nuvio.app.features.addons.AddonStorage
import com.nuvio.app.features.addons.RawHttpResponse
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.accept
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.isSuccess
import platform.Foundation.NSDate
import platform.Foundation.NSDateFormatter
import platform.Foundation.NSLocale
import platform.Foundation.NSUserDefaults

/**
 * Hooks the shared core up to macOS: where account and add-on data are kept (UserDefaults), the HTTP client (URLSession
 * through Ktor's Darwin engine) and which optional features this build ships with. The Mac app calls [install] once at
 * launch, before it touches anything else from the core.
 */
object MacRuntime {
    fun install(supabaseUrl: String, supabaseAnonKey: String, supabaseFallbackUrl: String, appVersionName: String, tmdbApiKey: String) {
        CoreRuntime.config = CoreConfig(
            supabaseUrl = supabaseUrl,
            supabaseAnonKey = supabaseAnonKey,
            supabaseFallbackUrl = supabaseFallbackUrl,
            appVersionName = appVersionName,
        )
        CoreRuntime.profileContext = object : ProfileContext {
            override val activeProfileId: Int get() = MacAccountData.activeProfileIndex
            override val usesPrimaryAddonsFromSecondaryProfile: Boolean
                get() = MacAccountData.activeProfile?.let { it.profileIndex != 1 && it.usesPrimaryAddons } == true
        }
        com.nuvio.app.features.tmdb.TmdbRuntime.apiKey = { tmdbApiKey }
        com.nuvio.app.features.tmdb.CoreClock.todayProvider = {
            val formatter = NSDateFormatter().apply { dateFormat = "yyyy-MM-dd"; locale = NSLocale("en_US_POSIX") }
            formatter.stringFromDate(NSDate())
        }
        com.nuvio.app.features.tmdb.CoreKeyValue.backend = object : com.nuvio.app.features.tmdb.CoreKeyValue.Backend {
            override fun getString(store: String, key: String): String? = NSUserDefaults.standardUserDefaults.stringForKey("kv_${store}_$key")
            override fun putString(store: String, key: String, value: String) { NSUserDefaults.standardUserDefaults.setObject(value, forKey = "kv_${store}_$key") }
        }
        CoreRuntime.accountDataWiper = com.nuvio.app.core.platform.AccountDataWiper { userId -> MacAccountData.wipeLocalData(userId) }
        AuthStorage.backend = MacAuthStorage
        SyncClientIdentityStorage.backend = MacSyncClientIdentityStorage
        AddonStorage.backend = MacAddonStorage
        AddonHttp.backend = MacAddonHttp
        com.nuvio.app.features.livetv.LiveTvGzip.backend = MacGzip
        com.nuvio.app.features.livetv.LiveTvEpgDownload.backend = MacEpgDownload
        com.nuvio.app.features.livetv.LiveTvHttp.clientFactory = { macHttpClient }
        AppFeaturePolicy.values = MacFeaturePolicy
        installMacSports()
    }
}

private object MacFeaturePolicy : AppFeaturePolicy.Values {
    override val pluginsEnabled = false
    override val supportersContributorsPageEnabled = false
    override val donationActionsEnabled = false
    override val donationProgressEnabled = false
    override val accountDeletionEnabled = false
    override val personalMediaAddonCopyEnabled = false
    override val p2pEnabled = false
    override val trailerPlaybackMode = TrailerPlaybackMode.EXTERNAL
    override val heroTrailerPlaybackSupported = false
    override val inAppUpdaterEnabled = false
    override val imdbRatingLogoEnabled = true
    override val mediaPlaybackForegroundServiceEnabled = false
    override val downloadForegroundServiceEnabled = false
    override val customServerConnectionsEnabled = false
}

private object MacAuthStorage : AuthStorage.Backend {
    private const val key = "anonymous_user_id"
    override fun loadAnonymousUserId(): String? = NSUserDefaults.standardUserDefaults.stringForKey(key)
    override fun saveAnonymousUserId(userId: String) { NSUserDefaults.standardUserDefaults.setObject(userId, forKey = key) }
    override fun clearAnonymousUserId() { NSUserDefaults.standardUserDefaults.removeObjectForKey(key) }
}

private object MacSyncClientIdentityStorage : SyncClientIdentityStorage.Backend {
    private const val key = "client_instance_id"
    override fun loadClientId(): String? = NSUserDefaults.standardUserDefaults.stringForKey(key)
    override fun saveClientId(clientId: String) { NSUserDefaults.standardUserDefaults.setObject(clientId, forKey = key) }
}

private object MacAddonStorage : AddonStorage.Backend {
    private const val urlsKey = "installed_manifest_urls"
    private const val enabledKey = "installed_manifest_enabled_states"
    private val defaults get() = NSUserDefaults.standardUserDefaults

    // Kept per account, so one person's add-ons (which can carry their debrid keys) are never loaded for another.
    private fun key(base: String, profileId: Int) = "${base}_${MacAccountData.owner()}_$profileId"

    override fun loadInstalledAddonUrls(profileId: Int): List<String> =
        defaults.stringForKey(key(urlsKey, profileId)).orEmpty().lineSequence()
            .map { it.trim() }.filter { it.isNotEmpty() }.toList()

    override fun saveInstalledAddonUrls(profileId: Int, urls: List<String>) {
        defaults.setObject(urls.joinToString("\n"), forKey = key(urlsKey, profileId))
    }

    override fun loadAddonEnabledStates(profileId: Int): Map<String, Boolean> =
        defaults.stringForKey(key(enabledKey, profileId)).orEmpty().lineSequence().mapNotNull { line ->
            val url = line.substringBefore("\t").trim().takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            url to (line.substringAfter("\t", "true").trim().lowercase() != "false")
        }.toMap()

    override fun saveAddonEnabledStates(profileId: Int, states: Map<String, Boolean>) {
        defaults.setObject(
            states.entries.joinToString("\n") { (url, enabled) -> "$url\t$enabled" },
            forKey = key(enabledKey, profileId),
        )
    }
}

internal val macHttpClient = HttpClient(Darwin) {
    install(HttpTimeout) {
        requestTimeoutMillis = 60_000
        connectTimeoutMillis = 60_000
        socketTimeoutMillis = 60_000
    }
    expectSuccess = false
}

private suspend fun HttpResponse.requireText(): String {
    val payload = bodyAsText()
    if (!status.isSuccess()) error(CoreText.get(CoreStrings.networkRequestFailedHttp, status.value))
    if (payload.isBlank()) throw IllegalStateException(CoreText.get(CoreStrings.networkEmptyResponseBody))
    return payload
}

private object MacAddonHttp : AddonHttp.Backend {
    override suspend fun getText(url: String): String =
        macHttpClient.get(url) { accept(ContentType.Application.Json) }.requireText()

    override suspend fun postJson(url: String, body: String): String =
        macHttpClient.post(url) {
            accept(ContentType.Application.Json)
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            setBody(body)
        }.requireText()

    override suspend fun getTextWithHeaders(url: String, headers: Map<String, String>): String =
        macHttpClient.get(url) {
            accept(ContentType.Application.Json)
            headers.forEach { (k, v) -> header(k, v) }
        }.requireText()

    override suspend fun postJsonWithHeaders(url: String, body: String, headers: Map<String, String>): String =
        macHttpClient.post(url) {
            accept(ContentType.Application.Json)
            header(HttpHeaders.ContentType, ContentType.Application.Json.toString())
            headers.forEach { (k, v) -> header(k, v) }
            setBody(body)
        }.requireText()

    override suspend fun requestRaw(
        method: String,
        url: String,
        headers: Map<String, String>,
        body: String,
        followRedirects: Boolean,
        maxResponseBodyBytes: Int,
        bodyBytes: ByteArray?,
    ): RawHttpResponse {
        val response = macHttpClient.request {
            url(url)
            this.method = HttpMethod.parse(method.uppercase())
            headers.forEach { (k, v) -> header(k, v) }
            if (this.method == HttpMethod.Post || this.method == HttpMethod.Put || this.method == HttpMethod.Patch) {
                setBody(bodyBytes ?: body)
            }
        }
        val received = response.body<ByteArray>()
        val limited = received.copyOf(minOf(received.size, maxResponseBodyBytes.coerceAtLeast(0)))
        val decoded = limited.decodeToString()
        return RawHttpResponse(
            status = response.status.value,
            statusText = response.status.description,
            url = response.call.request.url.toString(),
            body = if (received.size > limited.size) "$decoded\n...[truncated]" else decoded,
            bodyBytes = limited,
            headers = response.headers.entries().associate { (name, values) -> name.lowercase() to values.joinToString(",") },
        )
    }
}
