package com.nuvio.app.features.letterboxd

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** An in-memory stand-in for letterboxd.com's website session. No network, no real account. */
class FakeLetterboxdSite(val userName: String = "tester") : LetterboxdTransport {
    private val user get() = userName
    class Film(val tmdbId: Int, val slug: String, val filmId: String, val lid: String, val tv: Boolean = false, val pageTmdbId: Int = tmdbId, val noIds: Boolean = false)
    sealed interface Write {
        /** The write works. */
        data object Ok : Write
        /** The entry lands and the reply is lost. */
        data object LandedReplyLost : Write
        /** The request is lost on the way: nothing lands, no reply. */
        data object LostBeforeLanding : Write
        /** No connection at all: the write cannot be sent. */
        data object Offline : Write
        data class Status(val code: Int, val body: String = "") : Write
        /** A 200 with a web page, such as a sign-in page. */
        data object HtmlPage : Write
    }

    val films = mutableListOf<Film>()
    val diary = mutableMapOf<String, MutableList<String>>()
    val requests = mutableListOf<LetterboxdRequest>()
    val diaryWrites = mutableListOf<JsonObject>()
    val ratings = mutableMapOf<String, Int>()
    val writeScript = ArrayDeque<Write>()
    var signedIn = true
    var diaryStatus: Int? = null
    var challenge = false
    var rateBody: String? = null
    /** What the settings page's username field holds; null leaves the field out (the markup the app does not know). */
    var settingsUsername: String? = user
    var profileExists = true
    /** (slug, yyyy-MM-dd, stars) newest first; served two per page. */
    val diaryRows = mutableListOf<Triple<String, String, Double?>>()
    /** (slug, title, stars) of every film marked watched, dated or not; served two per page. */
    val watchedList = mutableListOf<Triple<String, String, Double?>>()
    /** (slug, title) of every film on the watchlist; served two per page, with the total the live page declares. */
    val watchlist = mutableListOf<Pair<String, String>>()
    var watchlistFailsOnPage: Int? = null
    var declaredWatchlistTotal: Int? = null

    val writeCount get() = requests.count { it.method == "POST" && it.path.startsWith("/api/v0/") }

    override suspend fun send(request: LetterboxdRequest, cookieHeader: String, userAgent: String): LetterboxdResponse {
        requests += request
        val path = request.path
        if (challenge) return html("<html><head><title>Just a moment...</title></head></html>")
        return when {
            path == "/settings/" -> if (!signedIn) html("<html><head><title>Sign in • Letterboxd</title></head></html>")
                else html("""<html><head><title>Settings</title></head><body>${settingsUsername?.let { """<input type="text" name="username" value="$it">""" }.orEmpty()}</body></html>""")
            path == "/$user/" -> if (profileExists) html("<html><title>$user • Letterboxd</title></html>") else LetterboxdResponse(404, emptyMap(), emptyList(), "")
            path == "/$user/diary/" || path.startsWith("/$user/diary/films/page/") -> {
                if (!signedIn) return html("<html><head><title>Sign in • Letterboxd</title></head></html>")
                val page = if (path == "/$user/diary/") 1 else path.removePrefix("/$user/diary/films/page/").removeSuffix("/").toInt()
                val chunk = diaryRows.drop((page - 1) * 2).take(2)
                if (chunk.isEmpty() && page > 1) return LetterboxdResponse(404, emptyMap(), emptyList(), "")
                // The markup the live site serves (checked against a real diary page): dates link to /diary/films/for/, the slug is data-item-slug.
                val rows = chunk.joinToString("") { (slug, date, stars) ->
                    val (y, m, d) = date.split("-")
                    """<tr class="diary-entry-row viewing-poster-container"><td class="col-monthdate"><a class="month" href="/$user/diary/films/for/$y/${m.toInt()}/">M</a></td><td class="col-daydate"><a class="daydate" href="/$user/diary/films/for/$y/${m.toInt()}/${d.toInt()}/">$d</a></td><td class="col-production"><div class="react-component figure" data-item-slug="$slug" data-item-link="/film/$slug/"></div></td>${stars?.let { """<td class="col-rating"><span class="rating rated-${(it * 2).toInt()}"></span></td>""" }.orEmpty()}<td class="col-rewatch js-td-rewatch icon-status-off"></td></tr>"""
                }
                val more = if (diaryRows.size > page * 2) """<div class="pagination"><a class="next" href="/$user/diary/films/page/${page + 1}/">Older</a></div>""" else ""
                html("<html><body><table>$rows</table>$more</body></html>")
            }
            path == "/$user/watchlist/" || path.startsWith("/$user/watchlist/page/") -> {
                if (!signedIn) return html("<html><head><title>Sign in • Letterboxd</title></head></html>")
                val page = if (path == "/$user/watchlist/") 1 else path.removePrefix("/$user/watchlist/page/").removeSuffix("/").toInt()
                if (watchlistFailsOnPage == page) return LetterboxdResponse(500, emptyMap(), emptyList(), "")
                val chunk = watchlist.drop((page - 1) * 2).take(2)
                if (chunk.isEmpty() && page > 1) return LetterboxdResponse(404, emptyMap(), emptyList(), "")
                // The markup the live watchlist page serves (checked against a real one): li.griditem with data-item-slug and "Title (Year)", js-watchlist-count.
                val items = chunk.joinToString("") { (slug, title) ->
                    """<li class="griditem"><div class="react-component" data-component-class="LazyPoster" data-item-name="$title (2020)" data-item-slug="$slug" data-item-link="/film/$slug/"></div></li>"""
                }
                val more = if (watchlist.size > page * 2) """<div class="pagination"><a class="next" href="/$user/watchlist/page/${page + 1}/">Older</a></div>""" else ""
                html("""<html><body><section class="section-heading">$user wants to see <span class="js-watchlist-count">${declaredWatchlistTotal ?: watchlist.size} films</span></section><ul>$items</ul>$more</body></html>""")
            }
            path == "/$user/films/" || path.startsWith("/$user/films/page/") -> {
                if (!signedIn) return html("<html><head><title>Sign in • Letterboxd</title></head></html>")
                val page = if (path == "/$user/films/") 1 else path.removePrefix("/$user/films/page/").removeSuffix("/").toInt()
                val chunk = watchedList.drop((page - 1) * 2).take(2)
                if (chunk.isEmpty() && page > 1) return LetterboxdResponse(404, emptyMap(), emptyList(), "")
                val items = chunk.joinToString("") { (slug, title, stars) ->
                    """<li class="griditem"><div class="react-component" data-component-class="LazyPoster" data-item-name="$title (2020)" data-item-slug="$slug"></div><p class="poster-viewingdata">${stars?.let { """<span class="rating -micro rated-${(it * 2).toInt()}"></span>""" }.orEmpty()}</p></li>"""
                }
                val more = if (watchedList.size > page * 2) """<div class="pagination"><a class="next" href="/$user/films/page/${page + 1}/">Older</a><ul><li class="paginate-page"><a href="x">…</a></li></ul></div>""" else ""
                html("<html><body><ul>$items</ul>$more</body></html>")
            }
            path == "/" -> LetterboxdResponse(200, emptyMap(), if (signedIn) listOf("letterboxd.user.CURRENT=abc; Path=/", "com.xk72.webparts.csrf=tok123; Path=/") else listOf("com.xk72.webparts.csrf=tok123; Path=/"), "<html><title>Letterboxd</title></html>")
            path.startsWith("/tmdb/") -> {
                val film = films.firstOrNull { it.tmdbId == path.removePrefix("/tmdb/").toInt() } ?: return LetterboxdResponse(404, emptyMap(), emptyList(), "")
                html("""<html><head><link rel="canonical" href="https://letterboxd.com/film/${film.slug}/"><title>x</title></head></html>""")
            }
            path.startsWith("/film/") -> {
                val film = films.firstOrNull { "/film/${it.slug}/" == path } ?: return LetterboxdResponse(404, emptyMap(), emptyList(), "")
                val type = if (film.tv) "tv" else "movie"
                val ids = if (film.noIds) "" else """<div data-film-slug="${film.slug}" data-postered-identifier="{&quot;lid&quot;:&quot;${film.lid}&quot;,&quot;uid&quot;:&quot;film:${film.filmId}&quot;}"></div>"""
                html("""<html><head><title>${film.slug}</title></head><body data-tmdb-type="$type" data-tmdb-id="${film.pageTmdbId}">$ids</body></html>""")
            }
            path.startsWith("/$user/film/") && path.endsWith("/diary/") -> {
                diaryStatus?.let { return LetterboxdResponse(it, emptyMap(), emptyList(), "") }
                if (!signedIn) return html("<html><head><title>Sign in • Letterboxd</title></head></html>")
                val slug = path.removePrefix("/$user/film/").removeSuffix("/diary/")
                val dates = diary[slug].orEmpty()
                if (dates.isEmpty()) return LetterboxdResponse(404, emptyMap(), emptyList(), "")
                html(dates.joinToString("") { d ->
                    val (y, m, day) = d.split("-")
                    val month = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")[m.toInt() - 1]
                    """<a class="month">$month</a><a class="date">${day.toInt()}</a><a class="year">$y</a>"""
                })
            }
            path.startsWith("/api/v0/") && request.method == "POST" -> handleDiaryWrite(request)
            path.startsWith("/s/film:") && path.endsWith("/rate/") -> {
                rateBody?.let { return json(200, it) }
                val id = path.removePrefix("/s/film:").removeSuffix("/rate/")
                ratings[id] = request.form!!.getValue("rating").toInt()
                json(200, """{"result": true, "messages": []}""")
            }
            else -> LetterboxdResponse(404, emptyMap(), emptyList(), "")
        }
    }

    private fun handleDiaryWrite(request: LetterboxdRequest): LetterboxdResponse {
        val behavior = if (writeScript.isEmpty()) Write.Ok else writeScript.removeFirst()
        if (behavior is Write.Offline) throw LetterboxdException.Network("offline")
        if (behavior is Write.LostBeforeLanding) throw LetterboxdException.NoReplyAfterSend("timeout")
        if (behavior is Write.Status) return LetterboxdResponse(behavior.code, emptyMap(), emptyList(), behavior.body)
        if (behavior is Write.HtmlPage) return html("<html><head><title>Sign in • Letterboxd</title></head></html>")
        val body = Json.parseToJsonElement(request.json!!).jsonObject
        diaryWrites += body
        val date = body.getValue("diaryDetails").jsonObject.getValue("diaryDate").jsonPrimitive.content
        val id = body["productionId"]?.jsonPrimitive?.content ?: body.getValue("filmId").jsonPrimitive.content
        val film = films.first { it.lid == id || it.filmId == id }
        diary.getOrPut(film.slug) { mutableListOf() } += date
        if (behavior is Write.LandedReplyLost) throw LetterboxdException.NoReplyAfterSend("timeout")
        return json(200, """{"result": true}""")
    }

    private fun html(body: String) = LetterboxdResponse(200, emptyMap(), emptyList(), body)
    private fun json(status: Int, body: String) = LetterboxdResponse(status, emptyMap(), emptyList(), body)

    fun material() = LetterboxdSessionMaterial(mapOf(LetterboxdSession.SESSION_COOKIE to "abc", LetterboxdSession.CSRF_COOKIE to "tok123"), "TestAgent/1.0", user)
}

class MemoryKeyValue : LetterboxdKeyValue {
    val map = HashMap<String, String>()
    override fun read(key: String): String? = map[key]
    override fun write(key: String, value: String?) { if (value == null) map.remove(key) else map[key] = value }
}

class MemorySecretStore : LetterboxdSecretStore {
    val map = HashMap<Int, String>()
    override fun read(profileId: Int): String? = map[profileId]
    override fun write(profileId: Int, value: String?) { if (value == null) map.remove(profileId) else map[profileId] = value }
}

/** The UTC calendar day of an epoch-millisecond time, "yyyy-MM-dd" (tests run on a fixed zone). */
internal fun civilDate(ms: Long): String {
    val day = 86_400_000L
    val z = ms.floorDiv(day) + 719468
    val era = z.floorDiv(146097L); val doe = z - era * 146097
    val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    val mp = (5 * doy + 2) / 153
    val d = doy - (153 * mp + 2) / 5 + 1
    val m = if (mp < 10) mp + 3 else mp - 9
    return LetterboxdDates.format((yoe + era * 400 + if (m <= 2) 1 else 0).toInt(), m.toInt(), d.toInt())
}
