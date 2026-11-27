package com.nuvio.app.features.serializd

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * What a diary write sends. Serializd needs every key present and spelled in snake_case (a camelCase body is answered with a 500),
 * and `rating` must always be there: 0 means unrated. The body is built from explicit keys so the casing cannot drift.
 */
data class SerializdReviewPayload(
    val showTmdbId: Int,
    val seasonId: Int?,
    val episodeNumber: Int?,
    /** 1 to 10, or 0 for unrated. */
    val rating: Int,
    val reviewText: String,
    val containsSpoiler: Boolean,
    val backdateMs: Long,
    /** True makes a dated diary entry. A written review is only kept by Serializd when this is true. */
    val isLog: Boolean,
    val isRewatch: Boolean,
    val like: Boolean,
    val tags: List<String> = emptyList(),
    val allowsComments: Boolean = true,
) {
    /** The body of `/show/reviews/add`. */
    fun addBody(): String = buildJsonObject {
        put("show_id", showTmdbId)
        put("season_id", seasonId?.let { JsonPrimitive(it) } ?: JsonNull)
        put("episode_number", episodeNumber?.let { JsonPrimitive(it) } ?: JsonNull)
        put("review_text", reviewText)
        put("rating", rating.coerceIn(0, 10))
        put("contains_spoiler", containsSpoiler)
        put("backdate", SerializdDates.isoUtc(backdateMs))
        put("is_log", isLog)
        put("is_rewatch", isRewatch)
        put("tags", buildJsonArray { tags.forEach { add(JsonPrimitive(it)) } })
        put("allows_comments", allowsComments)
        put("like", like)
    }.toString()

    /** The body of `/show/reviews/update`, as Serializd's own web client sends it (the entry is named by [reviewId]). */
    fun updateBody(reviewId: Int): String = buildJsonObject {
        put("review_id", reviewId)
        put("review_text", reviewText)
        put("rating", rating.coerceIn(0, 10))
        put("contains_spoiler", containsSpoiler)
        put("backdate", SerializdDates.isoUtc(backdateMs))
        put("is_log", isLog)
        put("is_rewatch", isRewatch)
        put("episode_number", episodeNumber?.let { JsonPrimitive(it) } ?: JsonNull)
        put("tags", buildJsonArray { tags.forEach { add(JsonPrimitive(it)) } })
        put("allows_comments", allowsComments)
        put("like", like)
    }.toString()
}

/** What came back from a review write: the id of the entry, when the reply carried one. */
data class SerializdReviewAck(val reviewId: Int?)

/**
 * The Serializd endpoints BannerTV uses, one method each, parsed defensively. The reads and the verified-by-use writes here are the
 * only code that knows paths and field names, so a change on Serializd's side is an edit in this file.
 */
class SerializdApi(val session: SerializdSession) {

    // ------------------------------------------------------------------ catalogue

    /** `GET /show/{tmdbId}`: the show and its seasons as Serializd numbers them. */
    suspend fun show(showTmdbId: Int): SerializdShow {
        val root = SerializdJson.parseObject(session.send(SerializdRequest("GET", "/show/$showTmdbId")).body)
        val seasons = root.arr("seasons").orEmpty().mapNotNull { el ->
            val s = el as? JsonObject ?: return@mapNotNull null
            val number = s.int("seasonNumber") ?: return@mapNotNull null
            val id = s.int("id") ?: s.int("seasonId") ?: return@mapNotNull null
            SerializdSeasonInfo(number, id, s.int("episodeCount")?.takeIf { it > 0 })
        }
        return SerializdShow(
            tmdbId = root.int("id") ?: showTmdbId,
            name = root.str("name"),
            seasons = seasons,
            status = root.str("status"),
            posterPath = root.str("bannerImage"),
            inProduction = root["nextEpisodeToAir"].let { it != null && it !is JsonNull },
        )
    }

    /** `GET /show/{tmdbId}/season/{n}`: the episodes of one season. */
    suspend fun seasonEpisodes(showTmdbId: Int, seasonNumber: Int): List<SerializdEpisodeInfo> {
        val root = SerializdJson.parseObject(session.send(SerializdRequest("GET", "/show/$showTmdbId/season/$seasonNumber")).body)
        return root.arr("episodes").orEmpty().mapNotNull { el ->
            val e = el as? JsonObject ?: return@mapNotNull null
            SerializdEpisodeInfo(e.int("episodeNumber") ?: return@mapNotNull null, e.str("airDate"), e.str("name"))
        }
    }

    // ------------------------------------------------------------------ watched markers

    /**
     * `POST /episode_log/add`: marks episodes of one season watched. Marking an episode that is already marked changes nothing, so
     * this may be repeated freely. [seasonId] is Serializd's season id, not necessarily TMDB's.
     */
    suspend fun logEpisodes(showTmdbId: Int, seasonId: Int, episodeNumbers: List<Int>) {
        session.send(SerializdRequest("POST", "/episode_log/add", json = episodeBody(showTmdbId, seasonId, episodeNumbers, withNext = true)), SerializdSession.Repeat.Safe)
    }

    /** `POST /episode_log/remove`: takes the watched markers off. A dated diary entry is not touched. */
    suspend fun unlogEpisodes(showTmdbId: Int, seasonId: Int, episodeNumbers: List<Int>) {
        session.send(SerializdRequest("POST", "/episode_log/remove", json = episodeBody(showTmdbId, seasonId, episodeNumbers, withNext = false)), SerializdSession.Repeat.Safe)
    }

    private fun episodeBody(showTmdbId: Int, seasonId: Int, episodes: List<Int>, withNext: Boolean) = buildJsonObject {
        put("show_id", showTmdbId)
        put("season_id", seasonId)
        put("episode_numbers", buildJsonArray { episodes.forEach { add(JsonPrimitive(it)) } })
        // Serializd's web client sends this flag with the add; it is false because BannerTV picks what is next itself.
        if (withNext) put("should_get_next_episode", false)
    }.toString()

    // ------------------------------------------------------------------ diary writes

    /**
     * `POST /show/reviews/add`. Never repeated by the session: a new dated entry that was sent and not confirmed is looked for on the diary first.
     */
    suspend fun addReview(payload: SerializdReviewPayload): SerializdReviewAck {
        val reply = session.send(SerializdRequest("POST", "/show/reviews/add", json = payload.addBody()), SerializdSession.Repeat.Never)
        return SerializdReviewAck(reviewIdOf(reply.body))
    }

    /** `POST /show/reviews/update`: changes an entry that exists, so an edit is never a second entry. */
    suspend fun updateReview(reviewId: Int, payload: SerializdReviewPayload): SerializdReviewAck {
        val reply = session.send(SerializdRequest("POST", "/show/reviews/update", json = payload.updateBody(reviewId)), SerializdSession.Repeat.Never)
        return SerializdReviewAck(reviewIdOf(reply.body) ?: reviewId)
    }

    /** The id of the entry in a write's reply. The reply's exact shape is not documented, so the usual places are tried. */
    private fun reviewIdOf(body: String): Int? {
        val root = runCatching { SerializdJson.parseObject(body) }.getOrNull() ?: return null
        root.int("id")?.let { return it }
        root.int("reviewId")?.let { return it }
        root.obj("review")?.int("id")?.let { return it }
        (root.arr("reviews")?.firstOrNull() as? JsonObject)?.int("id")?.let { return it }
        return null
    }

    // ------------------------------------------------------------------ reads of the member's own data

    /** `GET /user/{username}/diary?page=N`. */
    suspend fun diaryPage(username: String, page: Int): SerializdDiaryPage {
        val root = SerializdJson.parseObject(session.send(SerializdRequest("GET", "/user/${encode(username)}/diary", query = mapOf("page" to page.toString()))).body)
        val rows = root.arr("reviews") ?: JsonArray(emptyList())
        val entries = rows.mapNotNull { el -> (el as? JsonObject)?.let(::diaryEntry) }
        return SerializdDiaryPage(entries, root.int("totalPages"), rows.size, root.int("totalReviews"))
    }

    /** One diary row. Any field can be JSON null: a review of a whole show or season has no episode number, and is not episode zero. */
    internal fun diaryEntry(r: JsonObject): SerializdDiaryEntry? {
        val show = r.int("showId") ?: return null
        val seasonId = r.int("seasonId")
        val seasonNumber = seasonId?.let { sid ->
            r.arr("showSeasons").orEmpty().firstNotNullOfOrNull { s ->
                (s as? JsonObject)?.takeIf { it.int("id") == sid || it.int("seasonId") == sid }?.int("seasonNumber")
            }
        }
        val episode = r.int("episodeNumber")?.takeIf { it > 0 }
        val back = SerializdDates.parse(r.str("backdate"))
        return SerializdDiaryEntry(
            id = r.int("id"),
            showTmdbId = show,
            showName = r.str("showName"),
            seasonId = seasonId,
            seasonNumber = seasonNumber,
            episodeNumber = episode,
            rating = r.int("rating")?.takeIf { it in 1..10 },
            reviewText = r.str("reviewText")?.takeIf { it.isNotBlank() },
            containsSpoiler = r.bool("containsSpoiler") == true,
            // A diary page lists dated entries: a row that does not say otherwise is one.
            isLog = r.bool("isLog") ?: true,
            isRewatch = r.bool("isRewatch") == true,
            like = r.bool("like") == true,
            backdateMs = back?.ms,
            backdateDateOnly = back?.dateOnly == true,
            dateAddedMs = SerializdDates.parse(r.str("dateAdded"))?.ms,
        )
    }

    /** `GET /user/{username}/watchedpage_v2/{page}`: shows with the seasons the member has marked watched. */
    suspend fun watchedPage(username: String, page: Int): SerializdWatchedPage {
        val root = SerializdJson.parseObject(
            session.send(SerializdRequest("GET", "/user/${encode(username)}/watchedpage_v2/$page", query = mapOf("sort_by" to "date_added_desc"))).body,
        )
        val rows = root.arr("items") ?: JsonArray(emptyList())
        val entries = rows.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val show = o.int("showId") ?: return@mapNotNull null
            SerializdWatchedEntry(show, o.str("showName"), intList(o.arr("seasonIds")), o.str("bannerImage"), o.int("numSeasons"), o.int("numEpisodes"))
        }
        return SerializdWatchedPage(entries, root.int("totalPages"), rows.size, root.int("numberOfShows"))
    }

    /** `GET /user/{username}/watchlistpage_v2/{page}?sort_by=date_added_desc`. */
    suspend fun watchlistPage(username: String, page: Int): SerializdWatchlistPage {
        val root = SerializdJson.parseObject(
            session.send(SerializdRequest("GET", "/user/${encode(username)}/watchlistpage_v2/$page", query = mapOf("sort_by" to "date_added_desc"))).body,
        )
        val rows = root.arr("items") ?: JsonArray(emptyList())
        val entries = rows.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val show = o.int("showId") ?: return@mapNotNull null
            SerializdWatchlistEntry(show, o.str("showName"), o.str("bannerImage"), emptyList(), intList(o.arr("seasonIds")))
        }
        return SerializdWatchlistPage(entries, root.int("totalPages"), rows.size, root.int("numberOfShows"))
    }

    private fun intList(a: JsonArray?): List<Int> = a.orEmpty().mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p !is JsonNull }?.content?.toIntOrNull() }

    /** Percent-encodes a path segment. Usernames are plain, but a segment never gets to change the path. */
    private fun encode(segment: String): String = buildString {
        for (b in segment.encodeToByteArray()) {
            val c = b.toInt() and 0xFF
            if ((c in 'a'.code..'z'.code) || (c in 'A'.code..'Z'.code) || (c in '0'.code..'9'.code) || c == '-'.code || c == '_'.code || c == '.'.code || c == '~'.code) append(c.toChar())
            else append('%').append(c.toString(16).uppercase().padStart(2, '0'))
        }
    }
}
