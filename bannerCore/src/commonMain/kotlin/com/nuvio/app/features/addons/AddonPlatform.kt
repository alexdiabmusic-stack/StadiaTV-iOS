package com.nuvio.app.features.addons

/** Where the installed add-on list is kept. The platform supplies the [Backend]. */
object AddonStorage {
    interface Backend {
        fun loadInstalledAddonUrls(profileId: Int): List<String>
        fun saveInstalledAddonUrls(profileId: Int, urls: List<String>)
        fun loadAddonEnabledStates(profileId: Int): Map<String, Boolean>
        fun saveAddonEnabledStates(profileId: Int, states: Map<String, Boolean>)
    }

    var backend: Backend? = null

    fun loadInstalledAddonUrls(profileId: Int): List<String> = backend?.loadInstalledAddonUrls(profileId).orEmpty()
    fun saveInstalledAddonUrls(profileId: Int, urls: List<String>) { backend?.saveInstalledAddonUrls(profileId, urls) }
    fun loadAddonEnabledStates(profileId: Int): Map<String, Boolean> = backend?.loadAddonEnabledStates(profileId).orEmpty()
    fun saveAddonEnabledStates(profileId: Int, states: Map<String, Boolean>) { backend?.saveAddonEnabledStates(profileId, states) }
}

data class RawHttpResponse(
    val status: Int,
    val statusText: String,
    val url: String,
    val body: String,
    val headers: Map<String, String>,
    /** The response body before charset decoding. */
    val bodyBytes: ByteArray = body.encodeToByteArray(),
)

/** Default safety limit for generic and plugin-provided HTTP responses. */
const val DefaultRawHttpResponseMaxBytes = 1024 * 1024

/** Plain HTTP for add-ons and plugins. The platform supplies the [Backend]; the functions below keep the old call sites. */
object AddonHttp {
    interface Backend {
        suspend fun getText(url: String): String
        suspend fun postJson(url: String, body: String): String
        suspend fun getTextWithHeaders(url: String, headers: Map<String, String>): String
        suspend fun postJsonWithHeaders(url: String, body: String, headers: Map<String, String>): String
        suspend fun requestRaw(
            method: String,
            url: String,
            headers: Map<String, String>,
            body: String,
            followRedirects: Boolean,
            maxResponseBodyBytes: Int,
            bodyBytes: ByteArray?,
        ): RawHttpResponse
    }

    var backend: Backend? = null

    internal fun current(): Backend = backend ?: error("No HTTP backend registered")
}

suspend fun httpGetText(url: String): String = AddonHttp.current().getText(url)

suspend fun httpPostJson(url: String, body: String): String = AddonHttp.current().postJson(url, body)

suspend fun httpGetTextWithHeaders(
    url: String,
    headers: Map<String, String>,
): String = AddonHttp.current().getTextWithHeaders(url, headers)

suspend fun httpPostJsonWithHeaders(
    url: String,
    body: String,
    headers: Map<String, String>,
): String = AddonHttp.current().postJsonWithHeaders(url, body, headers)

suspend fun httpRequestRaw(
    method: String,
    url: String,
    headers: Map<String, String>,
    body: String,
    followRedirects: Boolean = true,
    maxResponseBodyBytes: Int = DefaultRawHttpResponseMaxBytes,
    /** When present, sends these bytes verbatim instead of UTF-8 encoding [body]. */
    bodyBytes: ByteArray? = null,
): RawHttpResponse = AddonHttp.current().requestRaw(
    method, url, headers, body, followRedirects, maxResponseBodyBytes, bodyBytes,
)
