package com.nuvio.app.features.serializd

import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.random.Random

/**
 * The secret half of a connection: the credentials (Serializd has no refresh token, so signing in again needs them) and the current
 * bearer token. Kept in protected storage (the Keychain on iOS), one entry per BannerTV profile, never in preferences or logs.
 */
data class SerializdSessionMaterial(val email: String, val password: String, val token: String?, val username: String?)

/** At most two requests are in flight at once, across every account: Serializd answers a burst with 500s. */
internal object SerializdRequestGate {
    const val MAX_CONCURRENT = 2
    val permits = Semaphore(MAX_CONCURRENT)
}

/**
 * One account's session with Serializd: it signs in, keeps the token, and sends every request through the safety rules.
 *
 *  - The bearer token is put on each request; nothing is shared between accounts.
 *  - A 401 on a normal request signs in again once and repeats the request (a 401 means it was refused before it was processed).
 *    A 401 on the sign-in itself means the email or password is wrong and is never retried.
 *  - What may be repeated by itself: reads and the writes that are safe to repeat (sign-in, marking an episode watched, which
 *    is a set on Serializd's side). A write that makes a new dated entry is never repeated here: the caller reads the diary first.
 *  - Waits are exponential with jitter, and a rate limit is waited out only when it is short.
 */
class SerializdSession(
    material: SerializdSessionMaterial,
    private val transport: SerializdTransport,
    private val onMaterialChanged: (SerializdSessionMaterial) -> Unit = {},
    private val pause: suspend (Long) -> Unit = { delay(it) },
    private val jitter: () -> Long = { Random.nextLong(0, 400) },
    private val timeoutMs: Long = SerializdApiConstants.REQUEST_TIMEOUT_MS,
) {
    private var email: String = material.email
    private var password: String = material.password
    private var token: String? = material.token
    private var knownUsername: String? = material.username
    private val loginLock = Mutex()

    val username: String? get() = knownUsername
    val hasToken: Boolean get() = !token.isNullOrBlank()

    fun material(): SerializdSessionMaterial = SerializdSessionMaterial(email, password, token, knownUsername)

    /** How a request may be repeated when it failed in a way that tells nothing about whether it was applied. */
    enum class Repeat { Safe, Never }

    /**
     * Sends [request] and returns only a successful reply; every other outcome is an exception the app can act on.
     * [authenticated] false is for the sign-in itself.
     */
    suspend fun send(
        request: SerializdRequest,
        repeat: Repeat = if (request.isRead) Repeat.Safe else Repeat.Never,
        authenticated: Boolean = true,
    ): SerializdResponse {
        var attempt = 0
        var reauthed = false
        var rateWaited = false
        while (true) {
            if (authenticated && !hasToken) {
                // No token yet (a fresh connection, or one just dropped as stale): sign in first.
                signIn()
            }
            val outgoing = if (authenticated) request.copy(bearer = token) else request.copy(bearer = null)
            val response = try {
                SerializdRequestGate.permits.withPermit { transport.send(outgoing, timeoutMs) }
            } catch (e: SerializdException.Network) {
                if (repeat == Repeat.Safe && attempt + 1 < MAX_ATTEMPTS) { backoff(attempt++); continue }
                throw e
            } catch (e: SerializdException.NoReplyAfterSend) {
                if (repeat == Repeat.Safe && attempt + 1 < MAX_ATTEMPTS) { backoff(attempt++); continue }
                throw e
            }
            val status = response.status
            when {
                status in 200..299 -> return response
                status == 401 -> {
                    if (!authenticated) throw SerializdException.BadCredentials(messageOf(response) ?: "Serializd did not accept that email and password")
                    if (reauthed) throw SerializdException.SessionExpired("Serializd rejected the session again after signing in")
                    reauthed = true
                    // Drop the stale token, sign in once more with the saved credentials, then repeat this request.
                    token = null
                    try {
                        signIn()
                    } catch (e: SerializdException.BadCredentials) {
                        throw SerializdException.ReconnectRequired("Serializd no longer accepts the saved sign-in")
                    }
                    continue
                }
                status == 429 -> {
                    val wait = retryAfterMs(response)
                    if (wait != null && wait <= SHORT_RATE_WAIT_MS && !rateWaited) { rateWaited = true; pause(wait + jitter()); continue }
                    throw SerializdException.RateLimited("Serializd is rate limiting requests", wait ?: DEFAULT_RETRY_AFTER_MS)
                }
                status in TRANSIENT -> {
                    if (repeat == Repeat.Safe && attempt + 1 < MAX_ATTEMPTS) { backoff(attempt++); continue }
                    throw SerializdException.Server(status)
                }
                status == 404 -> throw SerializdException.NotFound(messageOf(response) ?: "Not found on Serializd")
                else -> throw SerializdException.Rejected(status, messageOf(response) ?: "Serializd refused the request ($status)")
            }
        }
    }

    /**
     * Signs in with the saved email and password and keeps the new token. Returns the username. A wrong email or password is
     * [SerializdException.BadCredentials], never retried.
     */
    suspend fun signIn(): String = loginLock.withLock {
        val body = buildJsonObject { put("email", email); put("password", password) }.toString()
        val reply = send(SerializdRequest("POST", "/login", json = body), repeat = Repeat.Safe, authenticated = false)
        val root = SerializdJson.parseObject(reply.body)
        val newToken = root.str("token")?.takeIf { it.isNotBlank() } ?: throw SerializdException.Unexpected("Serializd sent no token")
        val name = root.str("username")?.takeIf { it.isNotBlank() }
        token = newToken
        if (name != null) knownUsername = name
        onMaterialChanged(material())
        knownUsername ?: throw SerializdException.Unexpected("Serializd sent no username")
    }

    /**
     * Whether the saved token is still good (`/validateauthtoken`). Serializd answers 200 with `isValid: false` for a stale token,
     * so the body is read. Also recovers the username.
     */
    suspend fun validate(): Boolean {
        val current = token
        if (current.isNullOrBlank()) return false
        val reply = send(SerializdRequest("POST", "/validateauthtoken", json = buildJsonObject { put("token", current) }.toString()), repeat = Repeat.Safe, authenticated = false)
        val root = SerializdJson.parseObject(reply.body)
        val valid = root.bool("isValid") == true
        if (valid) {
            root.str("username")?.takeIf { it.isNotBlank() }?.let { if (it != knownUsername) { knownUsername = it; onMaterialChanged(material()) } }
        }
        return valid
    }

    /** The member's own username, from the sign-in or the token check. */
    suspend fun ensureUsername(): String {
        knownUsername?.let { return it }
        if (!hasToken) signIn() else validate()
        return knownUsername ?: signIn()
    }

    private suspend fun backoff(attempt: Int) = pause((BACKOFF_BASE_MS shl attempt.coerceIn(0, 6)) + jitter())

    private fun retryAfterMs(response: SerializdResponse): Long? =
        response.headers["retry-after"]?.trim()?.toLongOrNull()?.let { (it * 1000).coerceIn(0, MAX_RETRY_AFTER_MS) }

    /** The error text Serializd sent (`{"message": "..."}`), flattened and short. It never echoes a request body. */
    private fun messageOf(response: SerializdResponse): String? = runCatching {
        SerializdJson.parseObject(response.body).str("message")
    }.getOrNull()?.replace(Regex("\\s+"), " ")?.take(160)?.takeIf { it.isNotBlank() }

    companion object {
        const val MAX_ATTEMPTS = 4
        const val BACKOFF_BASE_MS = 500L
        const val SHORT_RATE_WAIT_MS = 10_000L
        const val DEFAULT_RETRY_AFTER_MS = 30_000L
        const val MAX_RETRY_AFTER_MS = 15 * 60_000L
        private val TRANSIENT = setOf(500, 502, 503, 504)
    }
}

/**
 * Stops repeated login failures from hammering Serializd: after a few wrong passwords in a row the sign-in is refused for a
 * growing time. One per profile; the app's clock is passed in.
 */
class SerializdLoginLimiter(private val now: () -> Long) {
    private var failures = 0
    private var lockedUntilMs = 0L

    /** Milliseconds until another attempt is allowed, or 0. */
    fun waitMs(): Long = (lockedUntilMs - now()).coerceAtLeast(0)

    fun recordFailure() {
        failures++
        if (failures >= FREE_ATTEMPTS) {
            val step = (failures - FREE_ATTEMPTS).coerceAtMost(4)
            lockedUntilMs = now() + (30_000L shl step).coerceAtMost(MAX_LOCK_MS)
        }
    }

    fun recordSuccess() { failures = 0; lockedUntilMs = 0L }

    private companion object {
        const val FREE_ATTEMPTS = 3
        const val MAX_LOCK_MS = 10 * 60_000L
    }
}

// ---------------------------------------------------------------------------------------------- JSON helpers

/** Reading Serializd's JSON. Every field can be missing or JSON null; nothing here throws on a field that is not what was expected. */
internal object SerializdJson {
    private val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true; isLenient = true }

    fun parseObject(body: String): JsonObject =
        try { json.parseToJsonElement(body) as? JsonObject ?: throw SerializdException.Unexpected("Serializd sent data in an unexpected shape") }
        catch (e: SerializdException) { throw e }
        catch (e: Exception) { throw SerializdException.Unexpected("Serializd sent something that is not JSON") }
}

internal fun JsonObject.prim(key: String): JsonPrimitive? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }

/** An integer, from a number or a numeric string. JSON null and anything else is null, never zero. */
internal fun JsonObject.int(key: String): Int? {
    val p = prim(key) ?: return null
    p.content.toIntOrNull()?.let { return it }
    return p.content.toDoubleOrNull()?.takeIf { it == it.toInt().toDouble() }?.toInt()
}

internal fun JsonObject.str(key: String): String? = prim(key)?.takeIf { it.isString }?.content

internal fun JsonObject.bool(key: String): Boolean? = prim(key)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull()

internal fun JsonObject.arr(key: String): kotlinx.serialization.json.JsonArray? = this[key] as? kotlinx.serialization.json.JsonArray

internal fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
