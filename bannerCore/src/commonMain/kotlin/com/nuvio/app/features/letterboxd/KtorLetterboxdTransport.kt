package com.nuvio.app.features.letterboxd

import io.ktor.client.HttpClient
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.request.header
import io.ktor.client.request.forms.FormDataContent
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.Parameters
import io.ktor.http.content.TextContent
import io.ktor.http.contentLength
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readAvailable
import kotlinx.coroutines.CancellationException

/**
 * Letterboxd over HTTPS with Ktor. Redirects are followed here (the shared client does not), for reads only and only within
 * letterboxd.com, and cookies set on the way are carried along. A write is never repeated or redirected.
 */
class KtorLetterboxdTransport(
    clientFactory: () -> HttpClient,
) : LetterboxdTransport {
    private val client: HttpClient by lazy(clientFactory)

    override suspend fun send(request: LetterboxdRequest, cookieHeader: String, userAgent: String): LetterboxdResponse {
        val isWrite = !request.method.equals("GET", ignoreCase = true)
        var url = BASE + request.path
        val cookies = LinkedHashMap<String, String>().also { map ->
            cookieHeader.split(';').map { it.trim() }.filter { it.contains('=') }.forEach { map[it.substringBefore('=')] = it.substringAfter('=') }
        }
        val allSetCookies = ArrayList<String>()
        var hops = 0
        while (true) {
            val reply = try {
                once(request, url, cookies.entries.joinToString("; ") { "${it.key}=${it.value}" }, userAgent, hops == 0)
            } catch (e: CancellationException) {
                throw e
            } catch (e: LetterboxdException) {
                throw e
            } catch (e: Throwable) {
                throw failure(e, isWrite)
            }
            allSetCookies += reply.setCookies
            reply.setCookies.forEach { raw ->
                val pair = raw.substringBefore(';'); val name = pair.substringBefore('=').trim(); val value = pair.substringAfter('=', "").trim()
                if (name.isNotEmpty()) { if (value.isEmpty() || raw.contains("Max-Age=0", true)) cookies.remove(name) else cookies[name] = value }
            }
            val location = reply.headers["location"]
            if (!isWrite && reply.status in REDIRECTS && location != null && hops < MAX_HOPS) {
                url = resolve(url, location) ?: return reply.copy(setCookies = allSetCookies)
                hops++
                continue
            }
            return reply.copy(setCookies = allSetCookies)
        }
    }

    private suspend fun once(request: LetterboxdRequest, url: String, cookie: String, userAgent: String, first: Boolean): LetterboxdResponse {
        val method = if (first) HttpMethod.parse(request.method.uppercase()) else HttpMethod.Get
        var result: LetterboxdResponse? = null
        client.prepareRequest(url) {
            this.method = method
            request.headers.forEach { (k, v) -> header(k, v) }
            header(HttpHeaders.UserAgent, userAgent)
            if (cookie.isNotBlank()) header(HttpHeaders.Cookie, cookie)
            if (first) {
                request.form?.let { form -> setBody(FormDataContent(Parameters.build { form.forEach { (k, v) -> append(k, v) } })) }
                request.json?.let { setBody(TextContent(it, ContentType.Application.Json)) }
            }
        }.execute { response ->
            val body = readBounded(response.bodyAsChannel(), response.contentLength())
            val headers = response.headers.entries().associate { (k, v) -> k.lowercase() to v.firstOrNull().orEmpty() }
            result = LetterboxdResponse(response.status.value, headers, response.headers.getAll(HttpHeaders.SetCookie).orEmpty(), body)
        }
        return result ?: throw LetterboxdException.Network("No response")
    }

    /** The reply body as text, refusing anything over 16 MB (a Letterboxd page is a few hundred KB). */
    private suspend fun readBounded(channel: ByteReadChannel, contentLength: Long?): String {
        if (contentLength != null && contentLength > MAX_BODY) throw LetterboxdException.Network("Response too large")
        val out = ArrayList<ByteArray>(); var total = 0
        while (true) {
            val buffer = ByteArray(minOf(8_192, MAX_BODY - total + 1))
            val count = channel.readAvailable(buffer, 0, buffer.size)
            if (count == -1) break
            if (count == 0) continue
            total += count
            if (total > MAX_BODY) throw LetterboxdException.Network("Response too large")
            out += buffer.copyOf(count)
        }
        val bytes = ByteArray(total); var offset = 0
        out.forEach { it.copyInto(bytes, offset); offset += it.size }
        return bytes.decodeToString()
    }

    /** Only https://letterboxd.com (and its subdomains) is ever followed: the session's cookies go nowhere else. */
    private fun resolve(from: String, location: String): String? {
        val target = when {
            location.startsWith("https://") -> location
            location.startsWith("//") -> "https:$location"
            location.startsWith("/") -> BASE + location
            else -> return null
        }
        val host = target.removePrefix("https://").substringBefore('/').substringBefore(':').lowercase()
        return target.takeIf { host == HOST || host.endsWith(".$HOST") }
    }

    /**
     * A failure before anything reached the site is a plain network error. A write that failed any other way may have landed, so
     * it is reported as "no reply after sending" and checked against the diary before anything is sent again.
     */
    private fun failure(e: Throwable, isWrite: Boolean): LetterboxdException {
        val text = (e.message.orEmpty() + " " + (e::class.simpleName ?: "")).lowercase()
        val neverSent = NOT_SENT_MARKERS.any { it in text }
        val message = e::class.simpleName ?: "Network error"
        return if (isWrite && !neverSent) LetterboxdException.NoReplyAfterSend(message) else LetterboxdException.Network(message)
    }

    private companion object {
        const val HOST = "letterboxd.com"
        const val BASE = "https://letterboxd.com"
        const val MAX_HOPS = 5
        const val MAX_BODY = 16 * 1024 * 1024
        val REDIRECTS = setOf(301, 302, 303, 307, 308)
        // Connection-level failures: Android/JVM names, and Foundation's error codes (not connected, no host, DNS, cannot connect).
        val NOT_SENT_MARKERS = listOf(
            "unresolvedaddress", "unknownhost", "connectexception", "connecttimeout", "noroutetohost", "connection refused",
            "code=-1009", "code=-1004", "code=-1003", "code=-1006", "code=-1200",
        )
    }
}
