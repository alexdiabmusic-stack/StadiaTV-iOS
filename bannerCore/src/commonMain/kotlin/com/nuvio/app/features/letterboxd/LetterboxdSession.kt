package com.nuvio.app.features.letterboxd

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** A request to letterboxd.com. [path] is relative to the site. */
data class LetterboxdRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String> = emptyMap(),
    val form: Map<String, String>? = null,
    val json: String? = null,
)

/** A reply. [setCookies] are the raw Set-Cookie header values; [headers] names are lower case. */
data class LetterboxdResponse(
    val status: Int,
    val headers: Map<String, String>,
    val setCookies: List<String>,
    val body: String,
)

/** The network. Cookies are not its business: the session adds the Cookie header and reads Set-Cookie itself. */
interface LetterboxdTransport {
    /**
     * Sends [request] with the given cookies. Throws [LetterboxdException.Network] when no reply came back, and
     * [LetterboxdException.NoReplyAfterSend] when the request was sent but the reply was lost (a timeout after a write).
     */
    suspend fun send(request: LetterboxdRequest, cookieHeader: String, userAgent: String): LetterboxdResponse
}

sealed class LetterboxdException(message: String, val category: LetterboxdErrorCategory, val retryAfterMs: Long? = null) : Exception(message) {
    class Network(message: String) : LetterboxdException(message, LetterboxdErrorCategory.Offline)
    /** A write was sent and no answer came back: it may have landed. */
    class NoReplyAfterSend(message: String) : LetterboxdException(message, LetterboxdErrorCategory.Ambiguous)
    class SessionExpired(message: String) : LetterboxdException(message, LetterboxdErrorCategory.SessionExpired)
    class ReconnectRequired(message: String) : LetterboxdException(message, LetterboxdErrorCategory.ReconnectionRequired)
    class Blocked(message: String) : LetterboxdException(message, LetterboxdErrorCategory.Blocked)
    class RateLimited(message: String, retryAfterMs: Long?) : LetterboxdException(message, LetterboxdErrorCategory.RateLimited, retryAfterMs)
    class Server(val status: Int) : LetterboxdException("Letterboxd returned $status", LetterboxdErrorCategory.ServerError)
    class FilmNotFound(message: String) : LetterboxdException(message, LetterboxdErrorCategory.FilmNotFound)
    class NotAFilm(message: String) : LetterboxdException(message, LetterboxdErrorCategory.NotAFilm)
    class Unsupported(message: String) : LetterboxdException(message, LetterboxdErrorCategory.Unsupported)
    class Unexpected(message: String) : LetterboxdException(message, LetterboxdErrorCategory.Unexpected)
}

/** The secret half of a connection: cookies and the browser identity they were issued to. Kept in protected storage. */
data class LetterboxdSessionMaterial(val cookies: Map<String, String>, val userAgent: String, val username: String)

/**
 * One account's website session: its cookies, its CSRF token and its connection state. One instance per connected
 * account; nothing here is shared between accounts. The cookie names are the site's:
 * `letterboxd.user.CURRENT` marks a signed-in session and `com.xk72.webparts.csrf` carries the token.
 */
class LetterboxdSession(
    material: LetterboxdSessionMaterial,
    private val transport: LetterboxdTransport,
    private val onMaterialChanged: (LetterboxdSessionMaterial) -> Unit = {},
) {
    private val cookies = LinkedHashMap(material.cookies)
    private val lock = Mutex()
    val userAgent: String = material.userAgent
    val username: String = material.username

    val csrf: String get() = cookies[CSRF_COOKIE].orEmpty()
    val hasSessionCookie: Boolean get() = !cookies[SESSION_COOKIE].isNullOrBlank()

    fun material(): LetterboxdSessionMaterial = LetterboxdSessionMaterial(cookies.toMap(), userAgent, username)

    private fun cookieHeader(): String = cookies.entries.joinToString("; ") { (k, v) -> "$k=$v" }

    private fun absorb(setCookies: List<String>) {
        var changed = false
        for (raw in setCookies) {
            val pair = raw.substringBefore(';')
            val name = pair.substringBefore('=').trim()
            val value = pair.substringAfter('=', "").trim()
            if (name.isEmpty()) continue
            val expired = raw.contains("Max-Age=0", ignoreCase = true) || value.isEmpty()
            if (expired) { if (cookies.remove(name) != null) changed = true } else if (cookies[name] != value) { cookies[name] = value; changed = true }
        }
        if (changed) onMaterialChanged(material())
    }

    /** Sends a request through the session and classifies the reply. A page that is not what was asked for is an error. */
    suspend fun send(request: LetterboxdRequest, expectJson: Boolean = false): LetterboxdResponse {
        val response = transport.send(request, cookieHeader(), userAgent)
        absorb(response.setCookies)
        classify(response, expectJson)
        return response
    }

    private fun retryAfterMs(response: LetterboxdResponse): Long? =
        response.headers["retry-after"]?.trim()?.toLongOrNull()?.let { (it * 1000).coerceIn(0, MAX_RETRY_AFTER_MS) }

    private fun classify(r: LetterboxdResponse, expectJson: Boolean) {
        when {
            r.status == 401 -> throw LetterboxdException.SessionExpired("Letterboxd returned 401")
            r.status == 429 -> throw LetterboxdException.RateLimited("Letterboxd is rate limiting requests", retryAfterMs(r) ?: DEFAULT_RETRY_AFTER_MS)
            r.status == 403 -> throw LetterboxdException.Blocked("Letterboxd returned 403 (a bot check)")
            r.status in 500..599 -> throw LetterboxdException.Server(r.status)
        }
        if (r.status in 200..299) {
            if (LetterboxdHtml.isChallenge(r.body)) throw LetterboxdException.Blocked("Letterboxd served a bot check page")
            if (expectJson && !LetterboxdHtml.looksLikeJson(r.body)) {
                throw if (LetterboxdHtml.isSignInPage(r.body)) LetterboxdException.SessionExpired("Letterboxd served its sign-in page")
                else LetterboxdException.Unexpected("Letterboxd answered with a page instead of data")
            }
        }
    }

    /** Reads a fresh CSRF token (the site sets it as a cookie on any page). Throws if the session is not signed in. */
    suspend fun refreshCsrf() = lock.withLock {
        val r = send(LetterboxdRequest("GET", "/", navHeaders()))
        if (!hasSessionCookie) throw LetterboxdException.SessionExpired("No signed-in session")
        if (csrf.isBlank()) throw LetterboxdException.Unexpected("Could not read the CSRF cookie")
        r
    }

    /** Whether the session is still signed in, and the page it answered with (for reading the username). */
    suspend fun validate(): LetterboxdResponse {
        if (!hasSessionCookie) throw LetterboxdException.SessionExpired("No signed-in session")
        refreshCsrf()
        // A page only a signed-in member is served: a signed-out session ends up on the sign-in page.
        val r = send(LetterboxdRequest("GET", "/settings/", navHeaders()))
        if (LetterboxdHtml.isSignInPage(r.body) || r.status in 300..399) throw LetterboxdException.SessionExpired("Letterboxd served its sign-in page")
        if (r.status !in 200..299) throw LetterboxdException.Server(r.status)
        return r
    }

    fun navHeaders(referrer: String? = null): Map<String, String> = buildMap {
        put("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        put("Accept-Language", "en-US,en;q=0.9")
        put("sec-fetch-dest", "document"); put("sec-fetch-mode", "navigate"); put("sec-fetch-site", if (referrer == null) "none" else "same-origin")
        put("upgrade-insecure-requests", "1")
        referrer?.let { put("Referer", it) }
    }

    /** Headers for the site's own AJAX actions. The token is this session's, never another account's. */
    fun apiHeaders(filmSlug: String): Map<String, String> = mapOf(
        "Accept" to "application/json",
        "Referer" to "https://letterboxd.com/film/$filmSlug/",
        "Origin" to "https://letterboxd.com",
        "X-Requested-With" to "XMLHttpRequest",
        "X-CSRF-TOKEN" to csrf,
        "sec-fetch-dest" to "empty", "sec-fetch-mode" to "cors", "sec-fetch-site" to "same-origin",
    )

    companion object {
        const val SESSION_COOKIE = "letterboxd.user.CURRENT"
        const val CSRF_COOKIE = "com.xk72.webparts.csrf"
        const val DEFAULT_RETRY_AFTER_MS = 10_000L
        const val MAX_RETRY_AFTER_MS = 15 * 60_000L
    }
}

/**
 * Stops repeated login-type failures from hammering the site (Jellyscribe's AuthBreaker): after [THRESHOLD] consecutive
 * authentication failures the account is paused until the member reconnects.
 */
class LetterboxdAuthBreaker {
    var consecutiveFailures: Int = 0; private set
    val isOpen: Boolean get() = consecutiveFailures >= THRESHOLD
    fun recordFailure(): Boolean { consecutiveFailures++; return consecutiveFailures == THRESHOLD }
    fun recordSuccess() { consecutiveFailures = 0 }
    fun reset() { consecutiveFailures = 0 }
    companion object { const val THRESHOLD = 3 }
}
