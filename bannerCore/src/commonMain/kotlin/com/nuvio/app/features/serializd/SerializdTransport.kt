package com.nuvio.app.features.serializd

import io.ktor.client.HttpClient
import io.ktor.client.request.parameter
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.content.TextContent
import io.ktor.http.contentLength
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readAvailable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/** Where Serializd's private API lives and what its web app sends with every request. Kept in one place so a change is one edit. */
object SerializdApiConstants {
    const val BASE_URL = "https://serializd.onrender.com/api"
    const val FRONT_PAGE_URL = "https://www.serializd.com"
    const val APP_ID = "serializd_vercel"
    const val USER_AGENT = "BannerTV/1.0 (Serializd sync)"

    /** Serializd's API host cold-starts after idling, so a request is given this long before it is abandoned. */
    const val REQUEST_TIMEOUT_MS = 60_000L

    /** A show or season page on the website, for "open on Serializd". */
    fun showUrl(showTmdbId: Int) = "$FRONT_PAGE_URL/show/$showTmdbId"
}

/** A request to the Serializd API. [path] is relative to [SerializdApiConstants.BASE_URL]. The bearer token rides on the request, never on the client. */
data class SerializdRequest(
    val method: String,
    val path: String,
    val query: Map<String, String> = emptyMap(),
    val json: String? = null,
    val bearer: String? = null,
) {
    val isRead: Boolean get() = method.equals("GET", ignoreCase = true)
}

/** A reply. [headers] names are lower case. */
data class SerializdResponse(val status: Int, val headers: Map<String, String>, val body: String)

/** The network. It adds no credentials of its own and keeps no cookies: every account's requests are independent. */
interface SerializdTransport {
    /**
     * Sends [request]. Throws [SerializdException.Network] when nothing reached Serializd and [SerializdException.NoReplyAfterSend]
     * when a write was sent and the answer was lost (a timeout after sending).
     */
    suspend fun send(request: SerializdRequest, timeoutMs: Long = SerializdApiConstants.REQUEST_TIMEOUT_MS): SerializdResponse
}

sealed class SerializdException(message: String, val category: SerializdErrorCategory, val retryAfterMs: Long? = null) : Exception(message) {
    /** Nothing reached Serializd (no connection, a failed lookup, a refused connection). */
    class Network(message: String) : SerializdException(message, SerializdErrorCategory.Offline)
    /** A write was sent and no answer came back: it may have landed. */
    class NoReplyAfterSend(message: String) : SerializdException(message, SerializdErrorCategory.Ambiguous)
    class BadCredentials(message: String) : SerializdException(message, SerializdErrorCategory.BadCredentials)
    class SessionExpired(message: String) : SerializdException(message, SerializdErrorCategory.SessionExpired)
    class ReconnectRequired(message: String) : SerializdException(message, SerializdErrorCategory.ReconnectionRequired)
    class RateLimited(message: String, retryAfterMs: Long?) : SerializdException(message, SerializdErrorCategory.RateLimited, retryAfterMs)
    class Server(val status: Int) : SerializdException("Serializd returned $status", SerializdErrorCategory.ServerError)
    /** The show, season or episode is not on Serializd. */
    class NotFound(message: String) : SerializdException(message, SerializdErrorCategory.MetadataMissing)
    /** Serializd numbers the show differently and the episode cannot be placed with certainty. */
    class MetadataMismatch(message: String) : SerializdException(message, SerializdErrorCategory.MetadataMismatch)
    /** A 4xx other than auth: the request itself was refused. */
    class Rejected(val status: Int, message: String) : SerializdException(message, SerializdErrorCategory.Rejected)
    class Unsupported(message: String) : SerializdException(message, SerializdErrorCategory.Unsupported)
    class Unexpected(message: String) : SerializdException(message, SerializdErrorCategory.Unexpected)
}

/** Serializd over HTTPS with Ktor. Redirects are not followed and nothing is retried here: the session decides what is safe to repeat. */
class KtorSerializdTransport(clientFactory: () -> HttpClient) : SerializdTransport {
    private val client: HttpClient by lazy(clientFactory)

    override suspend fun send(request: SerializdRequest, timeoutMs: Long): SerializdResponse {
        val isWrite = !request.isRead
        return try {
            withTimeout(timeoutMs) { once(request) }
        } catch (e: TimeoutCancellationException) {
            // The clock ran out. A read simply did not answer; a write may still be applied on the other side.
            throw if (isWrite) SerializdException.NoReplyAfterSend("Timed out waiting for Serializd") else SerializdException.Network("Timed out waiting for Serializd")
        } catch (e: CancellationException) {
            throw e
        } catch (e: SerializdException) {
            throw e
        } catch (e: Throwable) {
            throw failure(e, isWrite)
        }
    }

    private suspend fun once(request: SerializdRequest): SerializdResponse {
        var result: SerializdResponse? = null
        client.prepareRequest(SerializdApiConstants.BASE_URL + request.path) {
            method = HttpMethod.parse(request.method.uppercase())
            request.query.forEach { (k, v) -> parameter(k, v) }
            header(HttpHeaders.Accept, "application/json")
            header(HttpHeaders.UserAgent, SerializdApiConstants.USER_AGENT)
            header(HttpHeaders.Origin, SerializdApiConstants.FRONT_PAGE_URL)
            header(HttpHeaders.Referrer, SerializdApiConstants.FRONT_PAGE_URL)
            header("X-Requested-With", SerializdApiConstants.APP_ID)
            // Set per request, so a token can never carry over from one account's request to another's.
            request.bearer?.let { header(HttpHeaders.Authorization, "Bearer $it") }
            request.json?.let { setBody(TextContent(it, ContentType.Application.Json)) }
        }.execute { response ->
            val body = readBounded(response.bodyAsChannel(), response.contentLength())
            val headers = response.headers.entries().associate { (k, v) -> k.lowercase() to v.firstOrNull().orEmpty() }
            result = SerializdResponse(response.status.value, headers, body)
        }
        return result ?: throw SerializdException.Network("No response")
    }

    /** The reply body as text, refusing anything over 16 MB (a Serializd page of data is far smaller). */
    private suspend fun readBounded(channel: ByteReadChannel, contentLength: Long?): String {
        if (contentLength != null && contentLength > MAX_BODY) throw SerializdException.Network("Response too large")
        val parts = ArrayList<ByteArray>(); var total = 0
        while (true) {
            val buffer = ByteArray(minOf(8_192, MAX_BODY - total + 1))
            val count = channel.readAvailable(buffer, 0, buffer.size)
            if (count == -1) break
            if (count == 0) continue
            total += count
            if (total > MAX_BODY) throw SerializdException.Network("Response too large")
            parts += buffer.copyOf(count)
        }
        val bytes = ByteArray(total); var offset = 0
        parts.forEach { it.copyInto(bytes, offset); offset += it.size }
        return bytes.decodeToString()
    }

    /**
     * A failure before anything reached Serializd is a plain network error. A write that failed any other way may have landed, so it is
     * reported as "no reply after sending" and checked against the diary before anything is sent again.
     */
    private fun failure(e: Throwable, isWrite: Boolean): SerializdException {
        val text = (e.message.orEmpty() + " " + (e::class.simpleName ?: "")).lowercase()
        val neverSent = NOT_SENT_MARKERS.any { it in text }
        val message = e::class.simpleName ?: "Network error"
        return if (isWrite && !neverSent) SerializdException.NoReplyAfterSend(message) else SerializdException.Network(message)
    }

    private companion object {
        const val MAX_BODY = 16 * 1024 * 1024
        // Connection-level failures: Android/JVM names, and Foundation's error codes (not connected, no host, DNS, cannot connect, TLS).
        val NOT_SENT_MARKERS = listOf(
            "unresolvedaddress", "unknownhost", "connectexception", "connecttimeout", "noroutetohost", "connection refused",
            "code=-1009", "code=-1004", "code=-1003", "code=-1006", "code=-1200",
        )
    }
}
