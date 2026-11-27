package com.nuvio.app.features.letterboxd

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class KtorLetterboxdTransportTest {
    private fun transport(handler: suspend io.ktor.client.engine.mock.MockRequestHandleScope.(io.ktor.client.request.HttpRequestData) -> io.ktor.client.request.HttpResponseData) =
        KtorLetterboxdTransport { HttpClient(MockEngine { request -> handler(this, request) }) { followRedirects = false; expectSuccess = false } }

    @Test fun aRedirectWithinLetterboxdIsFollowedAndCookiesSetOnTheWayAreCarried() = runTest {
        val seen = mutableListOf<Pair<String, String?>>()
        val t = transport { request ->
            seen += request.url.toString() to request.headers[HttpHeaders.Cookie]
            if (request.url.encodedPath == "/tmdb/603") {
                respond("", HttpStatusCode.Found, io.ktor.http.headers { append(HttpHeaders.Location, "/film/the-matrix/"); append(HttpHeaders.SetCookie, "hop=1; Path=/") })
            } else respond("<html>film</html>", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "text/html"))
        }
        val r = t.send(LetterboxdRequest("GET", "/tmdb/603"), "a=1", "UA/1")
        assertEquals(200, r.status); assertEquals("<html>film</html>", r.body)
        assertEquals(listOf("https://letterboxd.com/tmdb/603", "https://letterboxd.com/film/the-matrix/"), seen.map { it.first })
        assertEquals("a=1", seen[0].second)
        assertTrue(seen[1].second!!.contains("a=1") && seen[1].second!!.contains("hop=1"))
        assertTrue(r.setCookies.any { it.startsWith("hop=1") })
    }

    @Test fun aRedirectToAnotherSiteIsNeverFollowedSoCookiesStayHome() = runTest {
        var requests = 0
        val t = transport { requests++; respond("", HttpStatusCode.Found, headersOf(HttpHeaders.Location, "https://evil.example/steal")) }
        val r = t.send(LetterboxdRequest("GET", "/x"), "letterboxd.user.CURRENT=secret", "UA")
        assertEquals(302, r.status); assertEquals(1, requests)
    }

    @Test fun aLookalikeHostIsNotLetterboxd() = runTest {
        var requests = 0
        val t = transport { requests++; respond("", HttpStatusCode.Found, headersOf(HttpHeaders.Location, "https://letterboxd.com.evil.example/x")) }
        assertEquals(302, t.send(LetterboxdRequest("GET", "/x"), "k=v", "UA").status); assertEquals(1, requests)
    }

    @Test fun aWriteIsSentOnceWithJsonAndIsNotRedirected() = runTest {
        var requests = 0; var body = ""; var type: String? = null; var agent: String? = null; var csrf: String? = null
        val t = transport { request ->
            requests++; body = request.body.toByteArray().decodeToString(); type = request.body.contentType?.toString(); agent = request.headers[HttpHeaders.UserAgent]; csrf = request.headers["X-CSRF-TOKEN"]
            respond("", HttpStatusCode.Found, headersOf(HttpHeaders.Location, "/elsewhere"))
        }
        val r = t.send(LetterboxdRequest("POST", "/api/v0/log-entries", mapOf("X-CSRF-TOKEN" to "tok"), json = "{\"a\":1}"), "c=1", "UA/2")
        assertEquals(302, r.status); assertEquals(1, requests)
        assertEquals("{\"a\":1}", body); assertTrue(type!!.startsWith("application/json")); assertEquals("UA/2", agent); assertEquals("tok", csrf)
    }

    @Test fun aFormIsUrlEncoded() = runTest {
        var body = ""
        val t = transport { request -> body = request.body.toByteArray().decodeToString(); respond("{\"result\": true}", HttpStatusCode.OK) }
        t.send(LetterboxdRequest("POST", "/s/film:1/rate/", form = mapOf("rating" to "7", "__csrf" to "a b&c")), "", "UA")
        assertTrue(body.contains("rating=7")); assertTrue(body.contains("__csrf=a+b%26c") || body.contains("__csrf=a%20b%26c"))
    }

    @Test fun readsFailWithANetworkErrorAndWritesThatMayHaveLandedSaySo() = runTest {
        val broken = transport { throw RuntimeException("socket closed") }
        assertFailsWith<LetterboxdException.Network> { broken.send(LetterboxdRequest("GET", "/"), "", "UA") }
        assertFailsWith<LetterboxdException.NoReplyAfterSend> { broken.send(LetterboxdRequest("POST", "/api/v0/log-entries", json = "{}"), "", "UA") }
    }

    @Test fun aWriteThatNeverConnectedIsAPlainNetworkError() = runTest {
        val offline = transport { throw RuntimeException("Error Domain=NSURLErrorDomain Code=-1009 The Internet connection appears to be offline") }
        assertFailsWith<LetterboxdException.Network> { offline.send(LetterboxdRequest("POST", "/api/v0/log-entries", json = "{}"), "", "UA") }
    }

    @Test fun setCookieHeadersAreReturnedForTheSessionToAbsorb() = runTest {
        val t = transport { respond("ok", HttpStatusCode.OK, io.ktor.http.headers { append(HttpHeaders.SetCookie, "com.xk72.webparts.csrf=new; Path=/"); append(HttpHeaders.SetCookie, "other=1; Path=/") }) }
        val r = t.send(LetterboxdRequest("GET", "/"), "", "UA")
        assertEquals(2, r.setCookies.size)
    }
}
