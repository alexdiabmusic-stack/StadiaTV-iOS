package com.nuvio.app.features.serializd

import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A transport that answers from a script and records what it was asked. */
class ScriptTransport(vararg items: Any) : SerializdTransport {
    val script = ArrayDeque(items.toList())
    val requests = mutableListOf<SerializdRequest>()
    override suspend fun send(request: SerializdRequest, timeoutMs: Long): SerializdResponse {
        requests += request
        val next = script.removeFirstOrNull() ?: error("script exhausted at ${request.path}")
        if (next is Throwable) throw next
        return next as SerializdResponse
    }
}

fun reply(code: Int, body: String = "{}", vararg headers: Pair<String, String>) = SerializdResponse(code, headers.toMap(), body)

private const val LOGIN_OK = """{"token":"fresh","username":"alice"}"""

private fun tokenSession(transport: SerializdTransport, pauses: MutableList<Long> = mutableListOf(), token: String? = "t0") =
    SerializdSession(SerializdSessionMaterial("a@example.com", "pw", token, "alice"), transport, pause = { pauses += it }, jitter = { 0 })

class SerializdSessionTest {
    @Test fun signInKeepsTheTokenAndTheUsernameAndTellsTheStore() = runTest {
        val server = FakeSerializdServer(); val saved = mutableListOf<SerializdSessionMaterial>()
        val s = SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, { saved += it }, pause = {})
        assertEquals("alice", s.signIn())
        assertTrue(s.hasToken); assertEquals("alice", s.username)
        assertEquals("a@example.com", saved.single().email); assertNotNull(saved.single().token)
        assertEquals(1, server.loginCalls)
    }

    @Test fun wrongCredentialsAreBadCredentialsAndNeverRetried() = runTest {
        val server = FakeSerializdServer()
        val s = SerializdSession(SerializdSessionMaterial("a@example.com", "WRONG", null, null), server, pause = {})
        assertFailsWith<SerializdException.BadCredentials> { s.signIn() }
        assertEquals(1, server.loginCalls)
    }

    @Test fun aStaleTokenIsRecognisedFromTheBodyNotTheStatus() = runTest {
        val server = FakeSerializdServer()
        val s = SerializdSession(SerializdSessionMaterial("a@example.com", "pw", "old", null), server, pause = {})
        assertFalse(s.validate()) // Serializd answers 200 with isValid:false
        s.signIn(); assertTrue(s.validate())
        server.expireTokens(); assertFalse(s.validate())
        assertFalse(SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, pause = {}).validate())
    }

    @Test fun eachRequestCarriesItsOwnAccountsTokenAndNothingLeaks() = runTest {
        val server = FakeSerializdServer(); server.users += FakeSerializdServer.User("b@example.com", "pw2", "bob")
        val a = SerializdApi(SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, pause = {}))
        val b = SerializdApi(SerializdSession(SerializdSessionMaterial("b@example.com", "pw2", null, null), server, pause = {}))
        a.diaryPage("alice", 1); b.diaryPage("bob", 1); a.diaryPage("alice", 1)
        val tokenOf = { name: String -> server.requests.filter { it.path == "/user/$name/diary" }.map { it.bearer }.toSet() }
        assertEquals(1, tokenOf("alice").size); assertEquals(1, tokenOf("bob").size)
        assertNotEquals(tokenOf("alice"), tokenOf("bob"))
        // A login carries no token at all.
        assertTrue(server.requests.filter { it.path == "/login" }.all { it.bearer == null })
        // A name Serializd does not know is a plain not-found.
        assertFailsWith<SerializdException.NotFound> { a.diaryPage("bob-who-is-not-alice", 1) }
    }

    @Test fun a401SignsInOnceMoreAndRepeatsTheRequest() = runTest {
        val server = FakeSerializdServer()
        val api = SerializdApi(SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, pause = {}))
        api.diaryPage("alice", 1)
        server.expireTokens()
        api.diaryPage("alice", 1)
        assertEquals(2, server.loginCalls)
        assertEquals(3, server.requests.count { it.path == "/user/alice/diary" }) // refused, then the same request again
    }

    @Test fun aSecond401AfterSigningInIsAnExpiredSessionNotALoop() = runTest {
        val t = ScriptTransport(reply(401), reply(200, LOGIN_OK), reply(401))
        assertFailsWith<SerializdException.SessionExpired> { SerializdApi(tokenSession(t)).diaryPage("alice", 1) }
        assertEquals(1, t.requests.count { it.path == "/login" })
    }

    @Test fun whenTheSavedSignInIsNoLongerAcceptedTheMemberMustReconnect() = runTest {
        val server = FakeSerializdServer()
        val api = SerializdApi(SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, pause = {}))
        api.diaryPage("alice", 1)
        server.users[0] = server.users[0].copy(password = "changed"); server.expireTokens()
        assertFailsWith<SerializdException.ReconnectRequired> { api.diaryPage("alice", 1) }
    }

    @Test fun aShortRateLimitIsWaitedOutOnceAndALongOneIsReported() = runTest {
        val pauses = mutableListOf<Long>()
        val ok = tokenSession(ScriptTransport(reply(429, "{}", "retry-after" to "2"), reply(200, """{"reviews":[],"totalPages":0}""")), pauses)
        SerializdApi(ok).diaryPage("alice", 1)
        assertEquals(1, pauses.size); assertEquals(2_000L, pauses.single())
        val long = assertFailsWith<SerializdException.RateLimited> { SerializdApi(tokenSession(ScriptTransport(reply(429, "{}", "retry-after" to "120")))).diaryPage("alice", 1) }
        assertEquals(120_000L, long.retryAfterMs)
        val unknown = assertFailsWith<SerializdException.RateLimited> { SerializdApi(tokenSession(ScriptTransport(reply(429)))).diaryPage("alice", 1) }
        assertEquals(SerializdSession.DEFAULT_RETRY_AFTER_MS, unknown.retryAfterMs)
    }

    @Test fun readsRetryServerErrorsWithGrowingWaits() = runTest {
        val pauses = mutableListOf<Long>()
        val t = ScriptTransport(reply(500), reply(502), reply(200, """{"reviews":[],"totalPages":0}"""))
        SerializdApi(tokenSession(t, pauses)).diaryPage("alice", 1)
        assertEquals(3, t.requests.size); assertEquals(listOf(500L, 1000L), pauses)
    }

    @Test fun readsGiveUpAfterFourTriesAndSayServerError() = runTest {
        val t = ScriptTransport(reply(503), reply(503), reply(503), reply(503))
        val e = assertFailsWith<SerializdException.Server> { SerializdApi(tokenSession(t)).diaryPage("alice", 1) }
        assertEquals(503, e.status); assertEquals(4, t.requests.size)
        assertEquals(SerializdErrorCategory.ServerError, e.category)
    }

    @Test fun aNewDiaryEntryIsNeverRepeatedByTheClientItself() = runTest {
        val payload = SerializdReviewPayload(1399, 3624, 1, 0, "", false, 1_700_000_000_000, true, false, false)
        val t500 = ScriptTransport(reply(500))
        assertFailsWith<SerializdException.Server> { SerializdApi(tokenSession(t500)).addReview(payload) }
        assertEquals(1, t500.requests.size)
        val lost = ScriptTransport(SerializdException.NoReplyAfterSend("timeout"))
        assertFailsWith<SerializdException.NoReplyAfterSend> { SerializdApi(tokenSession(lost)).addReview(payload) }
        assertEquals(1, lost.requests.size)
        val offline = ScriptTransport(SerializdException.Network("offline"))
        assertFailsWith<SerializdException.Network> { SerializdApi(tokenSession(offline)).addReview(payload) }
        assertEquals(1, offline.requests.size)
    }

    @Test fun markingWatchedIsSafeToRepeat() = runTest {
        val t = ScriptTransport(SerializdException.NoReplyAfterSend("timeout"), reply(500), reply(200))
        SerializdApi(tokenSession(t)).logEpisodes(1399, 3624, listOf(1))
        assertEquals(3, t.requests.size)
    }

    @Test fun aReadThatCannotConnectIsRetriedThenReportedAsOffline() = runTest {
        val t = ScriptTransport(SerializdException.Network("a"), SerializdException.Network("b"), SerializdException.Network("c"), SerializdException.Network("d"))
        val e = assertFailsWith<SerializdException.Network> { SerializdApi(tokenSession(t)).diaryPage("alice", 1) }
        assertEquals(SerializdErrorCategory.Offline, e.category); assertEquals(4, t.requests.size)
    }

    @Test fun otherRefusalsAreNamedNotRetried() = runTest {
        val notFound = ScriptTransport(reply(404, """{"message":"Show not found"}"""))
        assertEquals("Show not found", assertFailsWith<SerializdException.NotFound> { SerializdApi(tokenSession(notFound)).show(5) }.message)
        val bad = ScriptTransport(reply(400, """{"message":"bad season"}"""))
        val e = assertFailsWith<SerializdException.Rejected> { SerializdApi(tokenSession(bad)).logEpisodes(1, 2, listOf(1)) }
        assertEquals(400, e.status); assertEquals(1, bad.requests.size)
    }

    @Test fun answersThatAreNotTheExpectedShapeAreUnexpectedNotACrash() = runTest {
        assertFailsWith<SerializdException.Unexpected> { SerializdApi(tokenSession(ScriptTransport(reply(200, "<html>nope</html>")))).show(1) }
        assertFailsWith<SerializdException.Unexpected> { SerializdApi(tokenSession(ScriptTransport(reply(200, "[1,2]")))).show(1) }
        assertFailsWith<SerializdException.Unexpected> { SerializdApi(tokenSession(ScriptTransport(reply(200, "")))).diaryPage("alice", 1) }
    }
}

class SerializdParsingTest {
    private val api = SerializdApi(tokenSession(ScriptTransport()))

    @Test fun showSeasonsAreReadWithBothIdSpellingsAndSkipBrokenRows() = runTest {
        val body = """{"id":1399,"name":"GoT","status":"Ended","bannerImage":"/b.jpg","nextEpisodeToAir":null,
            "seasons":[{"id":3624,"seasonId":3624,"seasonNumber":1,"episodeCount":10},{"seasonId":3625,"seasonNumber":2},{"seasonNumber":3},{"id":7,"seasonNumber":null},"junk"]}"""
        val show = SerializdApi(tokenSession(ScriptTransport(reply(200, body)))).show(1399)
        assertEquals(listOf(SerializdSeasonInfo(1, 3624, 10), SerializdSeasonInfo(2, 3625, null)), show.seasons)
        assertEquals("GoT", show.name); assertFalse(show.inProduction); assertEquals("/b.jpg", show.posterPath)
    }

    @Test fun aDiaryRowWithNullEpisodeNumberIsAShowOrSeasonEntryNeverEpisodeZero() {
        val row = Json.parseToJsonElement("""{"id":5,"showId":1399,"seasonId":null,"episodeNumber":null,"rating":9,"reviewText":"Great","isLog":true,"backdate":"2026-11-01T10:00:00Z"}""").jsonObject
        val e = api.diaryEntry(row)!!
        assertNull(e.episodeNumber); assertNull(e.seasonId); assertNull(e.seasonNumber); assertEquals(9, e.rating)
        val season = Json.parseToJsonElement("""{"id":6,"showId":1399,"seasonId":3625,"episodeNumber":null,"showSeasons":[{"id":3625,"seasonNumber":2}]}""").jsonObject
        val s = api.diaryEntry(season)!!
        assertNull(s.episodeNumber); assertEquals(2, s.seasonNumber)
        val zero = Json.parseToJsonElement("""{"id":7,"showId":1399,"seasonId":3625,"episodeNumber":0,"showSeasons":[{"id":3625,"seasonNumber":2}]}""").jsonObject
        assertNull(api.diaryEntry(zero)!!.episodeNumber)
    }

    @Test fun anEpisodeRowGetsItsSeasonNumberFromItsOwnSeasonList() {
        val row = Json.parseToJsonElement(
            """{"id":9,"showId":1399,"showName":"GoT","seasonId":3625,"episodeNumber":4,"rating":0,"reviewText":"","containsSpoiler":false,"isLog":true,"isRewatch":true,"like":true,
               "backdate":"2026-11-02T08:30:00.000Z","dateAdded":"2026-11-02T09:00:00Z","showSeasons":[{"id":3624,"seasonNumber":1},{"id":3625,"seasonNumber":2}]}""",
        ).jsonObject
        val e = api.diaryEntry(row)!!
        assertEquals(2, e.seasonNumber); assertEquals(4, e.episodeNumber); assertTrue(e.isRewatch); assertTrue(e.like); assertTrue(e.isLog)
        assertNull(e.rating) // 0 is unrated, not a rating
        assertNull(e.reviewText); assertFalse(e.backdateDateOnly)
        assertEquals(SerializdDates.parse("2026-11-02T08:30:00Z")!!.ms, e.backdateMs)
    }

    @Test fun missingFieldsAreToleratedAndARowWithoutAShowIsSkipped() {
        val sparse = api.diaryEntry(Json.parseToJsonElement("""{"showId":5}""").jsonObject)!!
        assertNull(sparse.id); assertNull(sparse.backdateMs); assertTrue(sparse.isLog, "a diary row that does not say otherwise is a dated entry")
        assertNull(api.diaryEntry(Json.parseToJsonElement("""{"episodeNumber":3}""").jsonObject))
        assertNull(api.diaryEntry(Json.parseToJsonElement("""{"showId":null}""").jsonObject))
        val strings = api.diaryEntry(Json.parseToJsonElement("""{"showId":"77","id":"12","episodeNumber":"3","seasonId":"4","showSeasons":[{"id":4,"seasonNumber":1}]}""").jsonObject)!!
        assertEquals(77, strings.showTmdbId); assertEquals(3, strings.episodeNumber); assertEquals(1, strings.seasonNumber)
    }

    @Test fun pagesCarryTheirDeclaredCount() = runTest {
        val diary = SerializdApi(tokenSession(ScriptTransport(reply(200, """{"reviews":[{"showId":1},{"showId":2}],"totalPages":7}""")))).diaryPage("alice", 1)
        assertEquals(2, diary.entries.size); assertEquals(7, diary.totalPages); assertEquals(2, diary.rawCount)
        val none = SerializdApi(tokenSession(ScriptTransport(reply(200, """{"reviews":[]}""")))).diaryPage("alice", 1)
        assertEquals(0, none.rawCount); assertNull(none.totalPages)
        val watched = SerializdApi(tokenSession(ScriptTransport(reply(200, """{"items":[{"showId":1399,"showName":"GoT","seasonIds":[3624,3625,"x",null],"numSeasons":2}],"totalPages":1}""")))).watchedPage("alice", 1)
        assertEquals(listOf(3624, 3625), watched.entries.single().seasonIds)
        val list = SerializdApi(tokenSession(ScriptTransport(reply(200, """{"items":[{"showId":1399,"seasonIds":[3624]},{"nope":1}],"totalPages":1}""")))).watchlistPage("alice", 1)
        assertEquals(1, list.entries.size); assertEquals(listOf(3624), list.entries.single().seasonIds); assertEquals(2, list.rawCount)
    }

    @Test fun theUsernameIsPercentEncodedInThePath() = runTest {
        val t = ScriptTransport(reply(200, """{"reviews":[]}"""))
        SerializdApi(tokenSession(t)).diaryPage("a b/c?x", 2)
        assertEquals("/user/a%20b%2Fc%3Fx/diary", t.requests.single().path); assertEquals("2", t.requests.single().query["page"])
    }
}

class SerializdPayloadTest {
    private fun body(p: SerializdReviewPayload) = Json.parseToJsonElement(p.addBody()).jsonObject

    @Test fun aDatedEpisodeLogHasEveryKeyInSnakeCaseAndAZeroRatingWhenUnrated() {
        val b = body(SerializdReviewPayload(1399, 3624, 1, 0, "", false, 1_700_000_000_000, isLog = true, isRewatch = false, like = false))
        assertEquals(setOf("show_id", "season_id", "episode_number", "review_text", "rating", "contains_spoiler", "backdate", "is_log", "is_rewatch", "tags", "allows_comments", "like"), b.keys)
        assertEquals("1399", b["show_id"]!!.jsonPrimitive.content); assertEquals("3624", b["season_id"]!!.jsonPrimitive.content); assertEquals("1", b["episode_number"]!!.jsonPrimitive.content)
        assertEquals("0", b["rating"]!!.jsonPrimitive.content, "rating is required even for an unrated log")
        assertEquals("2023-11-14T22:13:20Z", b["backdate"]!!.jsonPrimitive.content)
        assertEquals("true", b["is_log"]!!.jsonPrimitive.content); assertEquals("false", b["is_rewatch"]!!.jsonPrimitive.content)
        assertEquals("true", b["allows_comments"]!!.jsonPrimitive.content); assertEquals("[]", b["tags"].toString())
    }

    @Test fun aWholeShowEntryHasExplicitNullsForTheSeasonAndEpisode() {
        val b = body(SerializdReviewPayload(1399, null, null, 9, "An excellent series.", false, 1_700_000_000_000, isLog = true, isRewatch = false, like = false))
        assertEquals(JsonNull, b["season_id"]); assertEquals(JsonNull, b["episode_number"])
        assertEquals("9", b["rating"]!!.jsonPrimitive.content); assertEquals("An excellent series.", b["review_text"]!!.jsonPrimitive.content)
    }

    @Test fun flagsAndTextAreCarriedExactly() {
        val b = body(SerializdReviewPayload(1, 2, 3, 4, "line one\nline \"two\"", true, 0, isLog = false, isRewatch = true, like = true))
        assertEquals("line one\nline \"two\"", b["review_text"]!!.jsonPrimitive.content)
        assertEquals("true", b["contains_spoiler"]!!.jsonPrimitive.content); assertEquals("false", b["is_log"]!!.jsonPrimitive.content)
        assertEquals("true", b["is_rewatch"]!!.jsonPrimitive.content); assertEquals("true", b["like"]!!.jsonPrimitive.content)
        assertEquals(10, body(SerializdReviewPayload(1, 2, 3, 99, "", false, 0, true, false, false))["rating"]!!.jsonPrimitive.content.toInt(), "an out of range rating is clamped")
    }

    @Test fun anEditNamesTheEntryAndSendsTheFieldsSerializdsOwnClientSends() {
        val b = Json.parseToJsonElement(SerializdReviewPayload(1399, 3624, 1, 8, "t", false, 1_700_000_000_000, true, false, false).updateBody(55)).jsonObject
        assertEquals(setOf("review_id", "review_text", "rating", "contains_spoiler", "backdate", "is_log", "is_rewatch", "episode_number", "tags", "allows_comments", "like"), b.keys)
        assertEquals("55", b["review_id"]!!.jsonPrimitive.content)
    }

    @Test fun markingWatchedSendsTheSeasonIdAndEpisodeNumbers() = runTest {
        val t = ScriptTransport(reply(200), reply(200))
        val api = SerializdApi(tokenSession(t))
        api.logEpisodes(1399, 3624, listOf(1, 2)); api.unlogEpisodes(1399, 3624, listOf(2))
        val add = Json.parseToJsonElement(t.requests[0].json!!).jsonObject
        assertEquals("/episode_log/add", t.requests[0].path); assertEquals("[1,2]", add["episode_numbers"].toString()); assertEquals("3624", add["season_id"]!!.jsonPrimitive.content)
        assertEquals("/episode_log/remove", t.requests[1].path); assertFalse("should_get_next_episode" in Json.parseToJsonElement(t.requests[1].json!!).jsonObject)
    }
}

/** The transport's timeout is real time, which a test's virtual clock would run out at once: send on a real dispatcher. */
private suspend fun SerializdTransport.sendReal(request: SerializdRequest): SerializdResponse = withContext(Dispatchers.Default) { send(request) }

class KtorSerializdTransportTest {
    private fun transport(handler: suspend io.ktor.client.engine.mock.MockRequestHandleScope.(io.ktor.client.request.HttpRequestData) -> io.ktor.client.request.HttpResponseData) =
        KtorSerializdTransport { HttpClient(MockEngine { request -> handler(this, request) }) { followRedirects = false; expectSuccess = false } }

    @Test fun sendsTheHeadersTheWebAppSendsAndTheBearerOnlyWhenGiven() = runTest {
        val seen = mutableListOf<io.ktor.client.request.HttpRequestData>()
        val t = transport { request -> seen += request; respond("{}", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json")) }
        t.sendReal(SerializdRequest("GET", "/show/1399", bearer = "secret-token"))
        t.sendReal(SerializdRequest("POST", "/login", json = "{\"email\":\"e\",\"password\":\"p\"}"))
        val first = seen[0]; val second = seen[1]
        assertEquals("https://serializd.onrender.com/api/show/1399", first.url.toString())
        assertEquals("Bearer secret-token", first.headers[HttpHeaders.Authorization])
        assertEquals("https://www.serializd.com", first.headers[HttpHeaders.Origin]); assertEquals("https://www.serializd.com", first.headers[HttpHeaders.Referrer])
        assertEquals("serializd_vercel", first.headers["X-Requested-With"]); assertEquals("application/json", first.headers[HttpHeaders.Accept])
        assertEquals(SerializdApiConstants.USER_AGENT, first.headers[HttpHeaders.UserAgent]); assertTrue("BannerTV" in SerializdApiConstants.USER_AGENT)
        assertNull(second.headers[HttpHeaders.Authorization], "the next request does not inherit the last one's token")
        assertTrue(second.body.contentType.toString().startsWith("application/json"))
        assertEquals("{\"email\":\"e\",\"password\":\"p\"}", second.body.toByteArray().decodeToString())
    }

    @Test fun queryValuesGoInTheUrl() = runTest {
        var url = ""
        val t = transport { request -> url = request.url.toString(); respond("{}", HttpStatusCode.OK) }
        t.sendReal(SerializdRequest("GET", "/user/alice/diary", query = mapOf("page" to "3")))
        assertEquals("https://serializd.onrender.com/api/user/alice/diary?page=3", url)
    }

    @Test fun aBodyAndStatusComeBackWithLowerCaseHeaderNames() = runTest {
        val t = transport { respond("{\"message\":\"x\"}", HttpStatusCode.TooManyRequests, headersOf("Retry-After", "7")) }
        val r = t.sendReal(SerializdRequest("GET", "/x"))
        assertEquals(429, r.status); assertEquals("7", r.headers["retry-after"]); assertEquals("{\"message\":\"x\"}", r.body)
    }

    @Test fun aSlowAnswerWithinTheTimeoutIsSimplyWaitedFor() = runTest {
        val t = transport { kotlinx.coroutines.delay(150); respond("{\"ok\":true}", HttpStatusCode.OK) }
        val r = withContext(Dispatchers.Default) { t.send(SerializdRequest("POST", "/show/reviews/add", json = "{}"), timeoutMs = 2_000) }
        assertEquals(200, r.status)
    }

    @Test fun aWriteThatTimesOutMayHaveLandedAndAReadThatTimesOutIsJustOffline() = runTest {
        val slow = transport { kotlinx.coroutines.delay(2_000); respond("{}", HttpStatusCode.OK) }
        val write = runCatching { withContext(Dispatchers.Default) { slow.send(SerializdRequest("POST", "/show/reviews/add", json = "{}"), timeoutMs = 150) } }.exceptionOrNull()
        assertIs<SerializdException.NoReplyAfterSend>(write)
        val read = runCatching { withContext(Dispatchers.Default) { slow.send(SerializdRequest("GET", "/show/1399"), timeoutMs = 150) } }.exceptionOrNull()
        assertIs<SerializdException.Network>(read)
    }

    @Test fun aWriteThatFailsOnTheWireMayHaveLandedAndAReadIsJustOffline() = runTest {
        val broken = KtorSerializdTransport { HttpClient(MockEngine { throw RuntimeException("boom: stream reset") }) }
        assertIs<SerializdException.NoReplyAfterSend>(runCatching { broken.sendReal(SerializdRequest("POST", "/show/reviews/add", json = "{}")) }.exceptionOrNull())
        assertIs<SerializdException.Network>(runCatching { broken.sendReal(SerializdRequest("GET", "/show/1")) }.exceptionOrNull())
        val unreachable = KtorSerializdTransport { HttpClient(MockEngine { throw RuntimeException("UnknownHostException: serializd.onrender.com") }) }
        assertIs<SerializdException.Network>(runCatching { unreachable.sendReal(SerializdRequest("POST", "/show/reviews/add", json = "{}")) }.exceptionOrNull(), "never reached the server, so nothing to reconcile")
    }
}
