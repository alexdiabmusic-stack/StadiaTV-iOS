package com.nuvio.app.features.letterboxd

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/**
 * Reads Letterboxd's pages. The site has no public API for a member's session, so this is markup parsing: every reader
 * returns null (or an empty list) instead of guessing when the markup is not what it expects, and callers treat that as
 * "could not tell", never as "does not exist".
 */
internal object LetterboxdHtml {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val TITLE = Regex("<title[^>]*>(.*?)</title>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))

    /** The challenge page's own <title>, never body text (a film or review called "just a moment" must not stop a sync). */
    fun isChallenge(html: String): Boolean {
        val title = TITLE.find(html)?.groupValues?.get(1) ?: return false
        val t = title.trim()
        // Cloudflare's interstitial is titled exactly "Just a moment..." or "Attention Required! | Cloudflare"; a film's page
        // is "Title (Year) • Letterboxd", so a film with that name is not mistaken for a bot check.
        return t.equals("Just a moment...", ignoreCase = true) || t.equals("Just a moment", ignoreCase = true) ||
            (t.startsWith("Attention Required", ignoreCase = true) && t.contains("Cloudflare", ignoreCase = true))
    }

    /** A sign-in page served where data was expected (the session ended). */
    fun isSignInPage(html: String): Boolean {
        val title = TITLE.find(html)?.groupValues?.get(1)?.lowercase() ?: return false
        return title.contains("sign in") || title.contains("log in")
    }

    fun decode(text: String): String = text
        .replace("&quot;", "\"").replace("&#34;", "\"").replace("&#039;", "'").replace("&#39;", "'")
        .replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")

    private fun attr(tag: String, name: String): String? =
        Regex("""\b${Regex.escape(name)}\s*=\s*("([^"]*)"|'([^']*)')""", RegexOption.IGNORE_CASE).find(tag)
            ?.let { it.groups[2]?.value ?: it.groups[3]?.value }?.let(::decode)

    private fun tags(html: String, name: String): Sequence<String> =
        Regex("<$name\\b[^>]*>", RegexOption.IGNORE_CASE).findAll(html).map { it.value }

    /** The value of a hidden form input, for a form-based token. */
    fun hiddenInput(html: String, name: String): String? = tags(html, "input")
        .firstOrNull { attr(it, "name") == name }?.let { attr(it, "value") }

    /** The film's slug, from the page's canonical link (or its first /film/ link). Null when the page is not a film. */
    fun filmSlug(html: String): String? {
        val canonical = tags(html, "link").firstOrNull { attr(it, "rel").equals("canonical", ignoreCase = true) }?.let { attr(it, "href") }
        val href = canonical?.takeIf { it.isNotBlank() }
            ?: tags(html, "a").mapNotNull { attr(it, "href") }.firstOrNull { it.startsWith("/film/") }
            ?: return null
        val path = href.substringAfter("letterboxd.com", href).substringBefore('?').trim('/')
        val parts = path.split('/').filter { it.isNotEmpty() }
        return if (parts.size >= 2 && parts[0].equals("film", ignoreCase = true)) parts[1] else null
    }

    /** The film's ids: the numeric film id and the production id. Either may be missing; both missing is null. */
    fun filmIdentifiers(html: String, slug: String, headerProductionId: String? = null): Pair<String, String?>? {
        var productionId = headerProductionId?.takeIf { it.isNotBlank() }
        val divs = tags(html, "div").toList()
        // Newer markup carries both ids in one JSON attribute on the poster element: {"lid":"2a8i","uid":"film:51561"}.
        val el = divs.firstOrNull { attr(it, "data-film-slug") == slug }
            ?: divs.firstOrNull { attr(it, "data-item-slug") == slug }
            ?: divs.firstOrNull { attr(it, "data-item-link") == "/film/$slug/" }
            ?: divs.firstOrNull { attr(it, "data-film-id") != null }
            ?: divs.firstOrNull { attr(it, "data-postered-identifier") != null }
            ?: return null
        var filmId = attr(el, "data-film-id").orEmpty()
        if (filmId.isEmpty() || productionId.isNullOrEmpty()) {
            val posterJson = attr(el, "data-postered-identifier")
                ?: divs.firstNotNullOfOrNull { attr(it, "data-postered-identifier") }
            val obj = posterJson?.let { runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull() }
            if (obj != null) {
                if (productionId.isNullOrEmpty()) productionId = obj.str("lid")
                if (filmId.isEmpty()) obj.str("uid")?.let { uid -> filmId = uid.substringAfterLast(':') }
            }
        }
        if (filmId.isEmpty() && productionId.isNullOrEmpty()) return null
        return filmId to productionId
    }

    private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf { it.isNotBlank() }

    /** What TMDB entry the page is: a movie id, or a TV entry (Letterboxd lists miniseries and specials as films). */
    data class TmdbEntry(val movieId: Int?, val isTv: Boolean)

    fun tmdbEntry(html: String): TmdbEntry {
        val body = tags(html, "body").firstOrNull().orEmpty()
        val type = attr(body, "data-tmdb-type").orEmpty().trim()
        val button = tags(html, "a").firstOrNull { attr(it, "data-track-action") == "TMDB" }?.let { attr(it, "href") }.orEmpty()
        val tv = button.contains("themoviedb.org/tv/", ignoreCase = true) || type.equals("tv", ignoreCase = true)
        if (tv) return TmdbEntry(null, true)
        val id = attr(body, "data-tmdb-id")?.toIntOrNull()?.takeIf { it > 0 }
        return TmdbEntry(id, false)
    }

    /**
     * The diary page's dates, "yyyy-MM-dd". The page lists each entry's month, day and year as separate links, so the
     * three lists are zipped in order, as Jellyscribe's ParseDiaryDates does.
     */
    fun diaryDates(html: String): List<String> {
        fun texts(cls: Regex): List<String> = Regex("<a\\b([^>]*)>(.*?)</a>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
            .findAll(html).filter { m -> attr("<a ${m.groupValues[1]}>", "class")?.let { cls.containsMatchIn(it) } == true }
            .map { it.groupValues[2].replace(Regex("<[^>]*>"), "").trim() }.toList()
        val months = texts(Regex("""\bmonth\b"""))
        val days = texts(Regex("""\b(date|daydate)\b"""))
        val years = texts(Regex("""\byear\b"""))
        val n = minOf(months.size, days.size, years.size)
        val out = ArrayList<String>()
        for (i in 0 until n) {
            val m = LetterboxdDates.monthNumber(months[i]) ?: continue
            val d = days[i].toIntOrNull() ?: continue
            val y = years[i].toIntOrNull() ?: continue
            out += LetterboxdDates.format(y, m, d)
        }
        return out
    }

    /** The star rating from a poster container's "rated-N" class (N is half stars). */
    fun ratedStars(markup: String): Double? {
        val m = Regex("""\brated-(\d{1,2})\b""").find(markup) ?: return null
        val half = m.groupValues[1].toIntOrNull() ?: return null
        return if (half in 1..10) half / 2.0 else null
    }

    /** The slugs of the film posters on a member's films page, each with the rating shown beside it. */
    fun postersWithRatings(html: String): List<Pair<String, Double?>> {
        val items = Regex("<li\\b[^>]*poster-container[^>]*>(.*?)</li>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).findAll(html).toList()
        if (items.isNotEmpty()) {
            return items.mapNotNull { m ->
                val block = m.groupValues[1]
                val slug = tags(block, "div").firstNotNullOfOrNull { attr(it, "data-film-slug") ?: attr(it, "data-item-slug") } ?: return@mapNotNull null
                slug to ratedStars(block)
            }
        }
        return tags(html, "div").mapNotNull { attr(it, "data-film-slug") ?: attr(it, "data-item-slug") }.map { it to null }.toList()
    }

    fun hasNextPage(html: String, page: Int): Boolean =
        Regex("<a\\b[^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\bnext\\b[^\"']*[\"'][^>]*>", RegexOption.IGNORE_CASE).containsMatchIn(html) ||
            Regex("<li[^>]*>\\s*<a[^>]*>\\s*${page + 1}\\s*</a>", RegexOption.IGNORE_CASE).containsMatchIn(html)

    /**
     * The films on one page of a member's watched-films grid: slug, the "Title (Year)" the grid shows, and the rating shown.
     * The grid is `li.griditem` (older markup: `li.poster-container`).
     */
    fun watchedGrid(html: String): List<LetterboxdGridFilm> {
        val items = Regex("<li\\b[^>]*(?:griditem|poster-container)[^>]*>(.*?)</li>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).findAll(html).toList()
        return items.mapNotNull { m ->
            val block = m.groupValues[1]
            val tag = tags(block, "div").firstOrNull { attr(it, "data-item-slug") != null || attr(it, "data-film-slug") != null } ?: return@mapNotNull null
            val slug = attr(tag, "data-item-slug") ?: attr(tag, "data-film-slug") ?: return@mapNotNull null
            val name = attr(tag, "data-item-name") ?: attr(tag, "data-item-full-display-name")
            val year = name?.let { Regex("\\((\\d{4})\\)\\s*$").find(it)?.groupValues?.get(1) }
            LetterboxdGridFilm(slug, name?.replace(Regex("\\s*\\(\\d{4}\\)\\s*$"), "")?.trim()?.ifEmpty { null }, ratedStars(block), year)
        }
    }

    /**
     * How many films a watchlist page says the watchlist holds: the `js-watchlist-count` text ("191 films", "1,204 films"), or the heading
     * ("Alex wants to see 191 films"). Null when the page does not say, never a guess.
     */
    fun watchlistCount(html: String): Int? {
        val patterns = listOf(
            Regex("js-watchlist-count[^>]*>\\s*([\\d,.]+)\\s*film", RegexOption.IGNORE_CASE),
            Regex("wants to see\\s*(?:<[^>]+>\\s*)*([\\d,.]+)\\s*film", RegexOption.IGNORE_CASE),
        )
        for (p in patterns) p.find(html)?.groupValues?.get(1)?.replace(",", "")?.replace(".", "")?.toIntOrNull()?.let { return it }
        return null
    }

    /**
     * The signed-in member's username from a page that is only served to a signed-in session. The site has used several
     * markups for it, so these are tried in order; null means "could not tell" and the member confirms it by hand.
     */
    fun username(html: String): String? {
        val patterns = listOf(
            Regex("""data-person-username\s*=\s*["']([A-Za-z0-9_]{2,15})["']"""),
            Regex("""\bperson\s*=\s*\{[^}]*["']?username["']?\s*:\s*["']([A-Za-z0-9_]{2,15})["']"""),
            Regex("""<body[^>]*\bdata-owner\s*=\s*["']([A-Za-z0-9_]{2,15})["']"""),
            Regex("""<a[^>]*data-track-action\s*=\s*["']Profile["'][^>]*href\s*=\s*["']/([A-Za-z0-9_]{2,15})/["']"""),
            Regex("""<a[^>]*href\s*=\s*["']/([A-Za-z0-9_]{2,15})/["'][^>]*data-track-action\s*=\s*["']Profile["']"""),
        )
        for (p in patterns) p.find(html)?.groupValues?.get(1)?.let { return it }
        return null
    }

    /**
     * Null when a site action's reply is JSON with `"result": true`. Otherwise why it does not count as success. A 200 can
     * also be a sign-in or challenge page, and recording that as done would stop every retry.
     */
    fun siteActionFailure(body: String): String? {
        if (body.isBlank()) return "empty response"
        if (!body.trimStart().startsWith("{")) return "non-JSON response (a sign-in or challenge page)"
        val obj = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return "unparseable JSON response"
        val result = obj["result"] as? JsonPrimitive
        if (result?.contentOrNull == "true") return null
        val messages = (obj["messages"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty()
        return if (messages.isNotEmpty()) messages.joinToString("; ") else "result was not true"
    }


    fun diaryRows(html: String): List<LetterboxdDiaryRow> {
        val rows = Regex("<tr\\b[^>]*diary-entry-row[^>]*>(.*?)</tr>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL)).findAll(html)
        return rows.mapNotNull { m ->
            val block = m.groupValues[1]
            val slug = tags(block, "div").firstNotNullOfOrNull { attr(it, "data-film-slug") ?: attr(it, "data-item-slug") }
                ?: tags(block, "a").mapNotNull { attr(it, "href") }.firstNotNullOfOrNull { Regex("/film/([^/]+)/").find(it)?.groupValues?.get(1) }
                ?: return@mapNotNull null
            val d = Regex("/diary/(?:films/)?for/(\\d{4})/(\\d{1,2})/(\\d{1,2})/").find(block) ?: return@mapNotNull null
            val date = LetterboxdDates.format(d.groupValues[1].toInt(), d.groupValues[2].toInt(), d.groupValues[3].toInt())
            val rewatchCell = Regex("<td[^>]*td-rewatch[^>]*>").find(block)?.value
            LetterboxdDiaryRow(slug, date, ratedStars(block), rewatch = rewatchCell != null && !rewatchCell.contains("icon-status-off"))
        }.toList()
    }

    /** True when a reply body looks like JSON rather than a web page. */
    fun looksLikeJson(body: String): Boolean = body.trimStart().let { it.startsWith("{") || it.startsWith("[") }
}
