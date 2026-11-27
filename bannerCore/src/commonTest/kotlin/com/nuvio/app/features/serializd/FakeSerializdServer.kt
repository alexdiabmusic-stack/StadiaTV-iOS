package com.nuvio.app.features.serializd

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

class MemorySerializdKv : SerializdKeyValue {
    val map = HashMap<String, String>()
    override fun read(key: String): String? = map[key]
    override fun write(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
}

class MemorySecrets : SerializdSecretStore {
    val map = HashMap<Int, String>()
    override fun read(profileId: Int): String? = map[profileId]
    override fun write(profileId: Int, value: String?) { if (value == null) map.remove(profileId) else map[profileId] = value }
}

/**
 * An in-memory stand-in for the Serializd API. No network, no real account. It keeps the rules the real service is known to enforce:
 * a write body must be snake_case with every key present (anything else is a 500), a login with unknown details is a 401, a stale
 * token is answered 200 with `isValid: false`, and every other protected call without a good bearer token is a 401.
 */
class FakeSerializdServer : SerializdTransport {
    data class User(val email: String, val password: String, val username: String)
    class Season(val number: Int, val id: Int, val episodes: Int, val airDates: List<String?> = emptyList())
    class Show(val tmdbId: Int, val name: String, val seasons: List<Season>, val inProduction: Boolean = false)
    class Entry(
        var id: Int, val showId: Int, val seasonId: Int?, val episodeNumber: Int?, var rating: Int, var text: String, var spoiler: Boolean,
        var backdate: String, var isLog: Boolean, var isRewatch: Boolean, var like: Boolean, val dateAdded: String,
    )

    sealed interface Write {
        data object Ok : Write
        /** The write lands and the reply is lost. */
        data object LandedReplyLost : Write
        /** The write is lost on the way: nothing lands and nothing comes back. */
        data object LostBeforeLanding : Write
        /** No connection at all: nothing is sent. */
        data object Offline : Write
        /** The write lands, then Serializd answers 500. */
        data object ServerErrorLanded : Write
        data class Status(val code: Int, val body: String = "{\"message\":\"nope\"}") : Write
    }

    val users = mutableListOf(User("a@example.com", "pw", "alice"))
    val shows = mutableMapOf<Int, Show>()
    val markers = LinkedHashSet<Triple<Int, Int, Int>>()
    /** Dated entries, newest first. */
    val diary = mutableListOf<Entry>()
    val ratingsOnly = mutableListOf<Entry>()
    val watchlist = mutableListOf<Pair<Int, List<Int>>>()
    val watchedShows = mutableListOf<Pair<Int, List<Int>>>()
    val requests = mutableListOf<SerializdRequest>()
    val validTokens = mutableSetOf<String>()
    /** Which account each issued token belongs to, and which account each authenticated request was made as. */
    val tokenOwner = mutableMapOf<String, String>()
    val authLog = mutableListOf<Pair<String, String?>>()
    var loginCalls = 0
    var pageSize = 2
    var nextEntryId = 100
    var addReplyHasId = true
    var diaryIncludesNonLog = false
    var diaryFailsOnPage: Int? = null
    var watchlistRepeatsPage2 = false
    var watchlistFailsOnPage: Int? = null
    /** What the fake claims the lists hold in all, when it should lie about it. */
    var declaredWatchlistShows: Int? = null
    var declaredDiaryEntries: Int? = null
    val addScript = ArrayDeque<Write>()
    val markerScript = ArrayDeque<Write>()
    /** Statuses to answer the next reads with, then it works. */
    val readFailures = ArrayDeque<Int>()
    private var tokenCounter = 0

    init {
        shows[1399] = Show(1399, "Game of Thrones", listOf(Season(0, 3627, 5), Season(1, 3624, 10), Season(2, 3625, 10), Season(3, 3626, 10)))
    }

    fun posts(path: String) = requests.filter { it.method == "POST" && it.path == path }
    fun bodyOf(r: SerializdRequest): JsonObject = Json.parseToJsonElement(r.json!!).jsonObject
    fun seasonId(show: Int, number: Int) = shows.getValue(show).seasons.first { it.number == number }.id

    /** Puts a dated entry on the member's diary, newest first. A blank [backdate] is a row with no date at all. */
    fun log(show: Int, season: Int?, episode: Int?, backdate: String?, rating: Int = 0, text: String = "", isLog: Boolean = true, rewatch: Boolean = false, dateAdded: String = "2026-11-01T00:00:00Z"): Entry {
        val e = Entry(nextEntryId++, show, season?.let { seasonId(show, it) }, episode, rating, text, false, backdate.orEmpty(), isLog, rewatch, false, dateAdded)
        diary.add(0, e); return e
    }

    /** A stale token: every token issued so far stops working (the next sign-in gets a new one). */
    fun expireTokens() = validTokens.clear()

    private fun json(code: Int, body: String) = SerializdResponse(code, emptyMap(), body)
    private fun ok(body: JsonElement) = json(200, body.toString())

    /** Runs on every request before it is answered, so a test can hold a call open while it does something else. */
    var beforeReply: (suspend (SerializdRequest) -> Unit)? = null

    override suspend fun send(request: SerializdRequest, timeoutMs: Long): SerializdResponse {
        requests += request
        beforeReply?.invoke(request)
        val path = request.path
        val authed = request.bearer != null && request.bearer in validTokens
        if (authed) authLog += request.path to tokenOwner[request.bearer]
        fun needAuth(block: () -> SerializdResponse) = if (!authed) json(401, "{\"message\":\"Unauthorized\"}") else block()
        if (request.isRead && readFailures.isNotEmpty()) return json(readFailures.removeFirst(), "{\"message\":\"busy\"}")
        return when {
            path == "/login" -> {
                loginCalls++
                val body = bodyOf(request)
                val user = users.firstOrNull { it.email == body["email"]?.jsonPrimitive?.content && it.password == body["password"]?.jsonPrimitive?.content }
                    ?: return json(401, "{\"message\":\"User does not exist.\"}")
                val token = "tok-${++tokenCounter}"
                validTokens += token; tokenOwner[token] = user.username
                ok(buildJsonObject { put("token", token); put("username", user.username) })
            }
            path == "/validateauthtoken" -> {
                val token = bodyOf(request)["token"]?.jsonPrimitive?.content
                val valid = token in validTokens
                ok(buildJsonObject { put("isValid", valid); put("username", if (valid) tokenOwner[token] ?: "" else "") })
            }
            path.startsWith("/show/reviews/") -> needAuth { reviewWrite(request) }
            path == "/episode_log/add" || path == "/episode_log/remove" -> needAuth { episodeLog(request) }
            path.matches(Regex("/show/\\d+")) -> {
                val show = shows[path.removePrefix("/show/").toInt()] ?: return json(404, "{\"message\":\"Show not found\"}")
                ok(buildJsonObject {
                    put("id", show.tmdbId); put("name", show.name); put("status", "Ended")
                    put("nextEpisodeToAir", if (show.inProduction) buildJsonObject { put("episodeNumber", 1) } else JsonNull)
                    put("seasons", buildJsonArray { show.seasons.forEach { s -> add(buildJsonObject { put("id", s.id); put("seasonId", s.id); put("seasonNumber", s.number); put("episodeCount", s.episodes) }) } })
                })
            }
            path.matches(Regex("/show/\\d+/season/\\d+")) -> {
                val parts = path.split('/'); val show = shows[parts[2].toInt()]; val season = show?.seasons?.firstOrNull { it.number == parts[4].toInt() }
                if (season == null) json(404, "{\"message\":\"Season not found\"}") else ok(buildJsonObject {
                    put("seasonId", season.id); put("seasonNumber", season.number)
                    put("episodes", buildJsonArray { (1..season.episodes).forEach { n -> add(buildJsonObject { put("episodeNumber", n); put("airDate", season.airDates.getOrNull(n - 1)?.let { JsonPrimitive(it) } ?: JsonPrimitive("2020-01-01")) }) } })
                })
            }
            path.startsWith("/user/") -> needAuth { userRead(request) }
            else -> json(404, "{\"message\":\"unknown\"}")
        }
    }

    private fun applyScript(script: ArrayDeque<Write>, land: () -> Unit, reply: () -> SerializdResponse): SerializdResponse {
        when (val w = script.removeFirstOrNull() ?: Write.Ok) {
            Write.Ok -> { land(); return reply() }
            Write.LandedReplyLost -> { land(); throw SerializdException.NoReplyAfterSend("reply lost") }
            Write.LostBeforeLanding -> throw SerializdException.NoReplyAfterSend("lost")
            Write.Offline -> throw SerializdException.Network("offline")
            Write.ServerErrorLanded -> { land(); return json(500, "{\"message\":\"Internal\"}") }
            is Write.Status -> return json(w.code, w.body)
        }
    }

    private val addKeys = setOf("show_id", "season_id", "episode_number", "review_text", "rating", "contains_spoiler", "backdate", "is_log", "is_rewatch", "tags", "allows_comments", "like")
    private val updateKeys = setOf("review_id", "review_text", "rating", "contains_spoiler", "backdate", "is_log", "is_rewatch", "episode_number", "tags", "allows_comments", "like")

    private fun reviewWrite(request: SerializdRequest): SerializdResponse {
        val body = bodyOf(request)
        val isUpdate = request.path == "/show/reviews/update"
        // The real service answers a body with a missing or camelCase key with a 500.
        if (!body.keys.containsAll(if (isUpdate) updateKeys else addKeys)) return json(500, "{\"message\":\"Internal Server Error\"}")
        return applyScript(addScript, land = {
            if (isUpdate) {
                val e = (diary + ratingsOnly).first { it.id == body["review_id"]!!.jsonPrimitive.int }
                e.rating = body["rating"]!!.jsonPrimitive.int; e.text = body["review_text"]!!.jsonPrimitive.content
                e.spoiler = body["contains_spoiler"]!!.jsonPrimitive.boolean; e.backdate = body["backdate"]!!.jsonPrimitive.content
                e.isLog = body["is_log"]!!.jsonPrimitive.boolean; e.isRewatch = body["is_rewatch"]!!.jsonPrimitive.boolean; e.like = body["like"]!!.jsonPrimitive.boolean
            } else {
                val entry = Entry(
                    nextEntryId++, body["show_id"]!!.jsonPrimitive.int, body["season_id"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.int,
                    body["episode_number"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.int, body["rating"]!!.jsonPrimitive.int,
                    body["review_text"]!!.jsonPrimitive.content, body["contains_spoiler"]!!.jsonPrimitive.boolean, body["backdate"]!!.jsonPrimitive.content,
                    body["is_log"]!!.jsonPrimitive.boolean, body["is_rewatch"]!!.jsonPrimitive.boolean, body["like"]!!.jsonPrimitive.boolean, "2026-11-23T00:00:00Z",
                )
                if (entry.isLog) diary.add(0, entry) else ratingsOnly.add(0, entry)
            }
        }, reply = {
            val created = (diary + ratingsOnly).maxByOrNull { it.id }
            ok(buildJsonObject { if (addReplyHasId && created != null) put("id", if (isUpdate) body["review_id"]!!.jsonPrimitive.int else created.id); put("ok", true) })
        })
    }

    private fun episodeLog(request: SerializdRequest): SerializdResponse {
        val body = bodyOf(request)
        val show = body["show_id"]!!.jsonPrimitive.int; val season = body["season_id"]!!.jsonPrimitive.int
        val eps = (body["episode_numbers"] as JsonArray).map { it.jsonPrimitive.int }
        return applyScript(markerScript, land = {
            eps.forEach { if (request.path.endsWith("add")) markers += Triple(show, season, it) else markers -= Triple(show, season, it) }
        }, reply = { ok(buildJsonObject { put("ok", true) }) })
    }

    private fun entryJson(e: Entry): JsonObject {
        val show = shows[e.showId]
        return buildJsonObject {
            put("id", e.id); put("showId", e.showId); put("showName", show?.name ?: "Show ${e.showId}")
            put("seasonId", e.seasonId?.let { JsonPrimitive(it) } ?: JsonNull)
            put("showSeasons", buildJsonArray { show?.seasons?.forEach { s -> add(buildJsonObject { put("id", s.id); put("seasonNumber", s.number); put("name", "Season ${s.number}") }) } })
            put("episodeNumber", e.episodeNumber?.let { JsonPrimitive(it) } ?: JsonNull)
            put("rating", e.rating); put("reviewText", e.text); put("containsSpoiler", e.spoiler)
            put("backdate", e.backdate.takeIf { it.isNotEmpty() }?.let { JsonPrimitive(it) } ?: JsonNull)
            put("isLog", e.isLog); put("isRewatch", e.isRewatch); put("like", e.like)
            put("dateAdded", e.dateAdded.takeIf { it.isNotEmpty() }?.let { JsonPrimitive(it) } ?: JsonNull)
            put("tags", buildJsonArray { })
        }
    }

    private fun userRead(request: SerializdRequest): SerializdResponse {
        val parts = request.path.split('/')
        val name = parts[2]
        if (users.none { it.username == name }) return json(404, "{\"message\":\"Invalid user\"}")
        fun <T> paged(items: List<T>, page: Int, key: String, row: (T) -> JsonObject, declared: Int? = null): SerializdResponse {
            val total = (items.size + pageSize - 1) / pageSize
            return ok(buildJsonObject {
                put(key, buildJsonArray { items.drop((page - 1) * pageSize).take(pageSize).forEach { add(row(it)) } })
                put("totalPages", total)
                put(if (key == "reviews") "totalReviews" else "numberOfShows", declared ?: items.size)
            })
        }
        return when (parts[3]) {
            "diary" -> {
                val page = request.query["page"]!!.toInt()
                if (diaryFailsOnPage == page) return json(500, "{\"message\":\"Internal\"}")
                val rows = if (diaryIncludesNonLog) (diary + ratingsOnly).sortedByDescending { it.id } else diary.toList()
                paged(rows, page, "reviews", { entryJson(it) }, declaredDiaryEntries)
            }
            "watchedpage_v2" -> paged(watchedShows, parts[4].toInt(), "items", { (show, seasons) ->
                buildJsonObject { put("showId", show); put("showName", shows[show]?.name ?: "Show $show"); put("seasonIds", buildJsonArray { seasons.forEach { add(JsonPrimitive(it)) } }); put("numSeasons", seasons.size) }
            })
            "watchlistpage_v2" -> {
                val page = parts[4].toInt()
                if (watchlistFailsOnPage == page) return json(500, "{\"message\":\"Internal\"}")
                paged(watchlist, if (watchlistRepeatsPage2 && page == 2) 1 else page, "items", { (show, seasons) ->
                    buildJsonObject { put("showId", show); put("showName", shows[show]?.name ?: "Show $show"); put("seasonIds", buildJsonArray { seasons.forEach { add(JsonPrimitive(it)) } }) }
                }, declaredWatchlistShows)
            }
            else -> json(404, "{\"message\":\"unknown\"}")
        }
    }
}
