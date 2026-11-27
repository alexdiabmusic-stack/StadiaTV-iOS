package com.nuvio.app.features.letterboxd

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LetterboxdRatingTest {
    @Test fun halfStarsMapToTheSiteScale() {
        assertEquals(1, LetterboxdRating.toSiteScale(0.5))
        assertEquals(2, LetterboxdRating.toSiteScale(1.0))
        assertEquals(7, LetterboxdRating.toSiteScale(3.5))
        assertEquals(9, LetterboxdRating.toSiteScale(4.5))
        assertEquals(10, LetterboxdRating.toSiteScale(5.0))
        assertEquals(listOf(0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0), (1..10).map { LetterboxdRating.fromSiteScale(it) })
        assertNull(LetterboxdRating.fromSiteScale(0)); assertNull(LetterboxdRating.fromSiteScale(11))
    }

    @Test fun onlyHalfStepsInRangeAreValid() {
        assertTrue(LetterboxdRating.isValid(null)); assertTrue(LetterboxdRating.isValid(0.5)); assertTrue(LetterboxdRating.isValid(5.0))
        assertFalse(LetterboxdRating.isValid(0.0)); assertFalse(LetterboxdRating.isValid(5.5)); assertFalse(LetterboxdRating.isValid(3.3))
        assertEquals(11, LetterboxdRating.choices.size)
    }

    @Test fun snapRoundsToTheNearestHalfAndNeverMakesAZeroRating() {
        assertEquals(3.5, LetterboxdRating.snap(3.4)); assertEquals(0.5, LetterboxdRating.snap(0.1)); assertEquals(5.0, LetterboxdRating.snap(9.0))
        assertNull(LetterboxdRating.snap(0.0)); assertNull(LetterboxdRating.snap(null)); assertNull(LetterboxdRating.snap(-2.0))
        assertEquals("4.5", LetterboxdRating.label(4.5)); assertEquals("4", LetterboxdRating.label(4.0)); assertEquals("Unrated", LetterboxdRating.label(null))
        assertEquals(Triple(3, 1, 1), LetterboxdRating.glyphs(3.5))
    }

    @Test fun rewatchNeedsAnEarlierEntryMoreThanADayBack() {
        assertFalse(LetterboxdDates.isRewatch(null, "2026-11-21"))
        assertFalse(LetterboxdDates.isRewatch("2026-11-21", "2026-11-21"))
        assertFalse(LetterboxdDates.isRewatch("2026-11-20", "2026-11-21"))
        assertTrue(LetterboxdDates.isRewatch("2026-11-19", "2026-11-21"))
        assertTrue(LetterboxdDates.isRewatch("2025-12-31", "2026-01-02"))
        assertEquals(2L, LetterboxdDates.daysBetween("2024-02-28", "2024-03-01")) // leap year
    }
}

class LetterboxdHtmlTest {
    @Test fun filmSlugComesFromTheCanonicalLink() {
        assertEquals("the-thing-1982", LetterboxdHtml.filmSlug("""<head><link rel="canonical" href="https://letterboxd.com/film/the-thing-1982/"></head>"""))
        assertEquals("heat", LetterboxdHtml.filmSlug("""<a href="/film/heat/">Heat</a>"""))
        assertNull(LetterboxdHtml.filmSlug("""<link rel="canonical" href="https://letterboxd.com/tester/">"""))
        assertNull(LetterboxdHtml.filmSlug("<html></html>"))
    }

    @Test fun idsReadFromThePosterJsonOrDataAttributes() {
        val json = """<div data-film-slug="heat" data-postered-identifier="{&quot;lid&quot;:&quot;2a8i&quot;,&quot;uid&quot;:&quot;film:51561&quot;}"></div>"""
        assertEquals("51561" to "2a8i", LetterboxdHtml.filmIdentifiers(json, "heat"))
        assertEquals("777" to null, LetterboxdHtml.filmIdentifiers("""<div data-film-slug="heat" data-film-id="777"></div>""", "heat"))
        assertEquals("777" to "hdr", LetterboxdHtml.filmIdentifiers("""<div data-film-slug="heat" data-film-id="777"></div>""", "heat", "hdr"))
        assertNull(LetterboxdHtml.filmIdentifiers("<div>nothing</div>", "heat"))
    }

    @Test fun tvEntriesAreRecognisedByBodyTypeOrTmdbLink() {
        assertEquals(LetterboxdHtml.TmdbEntry(null, true), LetterboxdHtml.tmdbEntry("""<body data-tmdb-type="tv" data-tmdb-id="5">"""))
        assertEquals(LetterboxdHtml.TmdbEntry(null, true), LetterboxdHtml.tmdbEntry("""<body><a data-track-action="TMDB" href="https://www.themoviedb.org/tv/12/">TMDB</a>"""))
        assertEquals(LetterboxdHtml.TmdbEntry(603, false), LetterboxdHtml.tmdbEntry("""<body data-tmdb-type="movie" data-tmdb-id="603">"""))
        assertEquals(LetterboxdHtml.TmdbEntry(null, false), LetterboxdHtml.tmdbEntry("<body>"))
    }

    @Test fun diaryDatesZipMonthDayYear() {
        val html = """<a class="month">Nov</a><a class="date">3</a><a class="year">2025</a><a class="month">Jan</a><a class="daydate">21</a><a class="year">2026</a>"""
        assertEquals(listOf("2025-11-03", "2026-01-21"), LetterboxdHtml.diaryDates(html))
        assertEquals(emptyList(), LetterboxdHtml.diaryDates("<p>No diary entries</p>"))
    }

    @Test fun ratingsAndPostersOnAFilmsPage() {
        val html = """<ul><li class="poster-container"><div data-film-slug="a"></div><span class="rating rated-8"></span></li>
            <li class="poster-container"><div data-film-slug="b"></div></li></ul>"""
        assertEquals(listOf("a" to 4.0, "b" to null), LetterboxdHtml.postersWithRatings(html))
        assertEquals(0.5, LetterboxdHtml.ratedStars("rated-1")); assertEquals(5.0, LetterboxdHtml.ratedStars("rated-10")); assertNull(LetterboxdHtml.ratedStars("rated-11"))
    }

    @Test fun aChallengeIsTheTitleNotTheBody() {
        assertTrue(LetterboxdHtml.isChallenge("<title>Just a moment...</title>"))
        assertFalse(LetterboxdHtml.isChallenge("<title>Just A Moment (1990) • Letterboxd</title> <p>just a moment</p>"))
        assertTrue(LetterboxdHtml.isSignInPage("<title>Sign in • Letterboxd</title>"))
        assertFalse(LetterboxdHtml.isSignInPage("<title>Heat • Letterboxd</title><p>sign in</p>"))
    }

    @Test fun siteActionNeedsAnExplicitTrueResult() {
        assertNull(LetterboxdHtml.siteActionFailure("""{"result": true, "messages": []}"""))
        assertNotNull(LetterboxdHtml.siteActionFailure("""{"result": false, "messages": ["Rating failed"]}"""))
        assertTrue(LetterboxdHtml.siteActionFailure("""{"result": false, "messages": ["Rating failed"]}""")!!.contains("Rating failed"))
        assertNotNull(LetterboxdHtml.siteActionFailure("<html><title>Sign in</title></html>"))
        assertNotNull(LetterboxdHtml.siteActionFailure(""))
    }

    @Test fun usernameIsReadOnlyFromKnownMarkup() {
        assertEquals("film_fan", LetterboxdHtml.username("""<div data-person-username="film_fan"></div>"""))
        assertEquals("a_b", LetterboxdHtml.username("""<a href="/a_b/" data-track-action="Profile">me</a>"""))
        assertNull(LetterboxdHtml.username("<html>nothing here</html>"))
    }
}

class LetterboxdSessionTest {
    private fun session(site: FakeLetterboxdSite, changes: MutableList<LetterboxdSessionMaterial> = mutableListOf()) =
        LetterboxdSession(site.material(), site) { changes += it }

    @Test fun cookiesAreAbsorbedFromSetCookieAndTheCsrfCookieIsRead() = runTest {
        val site = FakeLetterboxdSite()
        val changes = mutableListOf<LetterboxdSessionMaterial>()
        val s = LetterboxdSession(LetterboxdSessionMaterial(mapOf(LetterboxdSession.SESSION_COOKIE to "abc"), "UA", "tester"), site) { changes += it }
        assertEquals("", s.csrf)
        s.refreshCsrf()
        assertEquals("tok123", s.csrf)
        assertTrue(changes.isNotEmpty())
        assertEquals("UA", s.material().userAgent)
    }

    @Test fun noSessionCookieMeansSessionExpired() = runTest {
        val s = LetterboxdSession(LetterboxdSessionMaterial(emptyMap(), "UA", "tester"), FakeLetterboxdSite())
        assertFailsWith<LetterboxdException.SessionExpired> { s.validate() }
    }

    @Test fun statusCodesAreClassified() = runTest {
        fun transportFor(r: LetterboxdResponse) = object : LetterboxdTransport { override suspend fun send(request: LetterboxdRequest, cookieHeader: String, userAgent: String) = r }
        fun sess(r: LetterboxdResponse) = LetterboxdSession(LetterboxdSessionMaterial(mapOf(LetterboxdSession.SESSION_COOKIE to "x"), "UA", "u"), transportFor(r))
        val get = LetterboxdRequest("GET", "/x")
        assertFailsWith<LetterboxdException.SessionExpired> { sess(LetterboxdResponse(401, emptyMap(), emptyList(), "")).send(get) }
        assertFailsWith<LetterboxdException.Blocked> { sess(LetterboxdResponse(403, emptyMap(), emptyList(), "")).send(get) }
        assertFailsWith<LetterboxdException.Server> { sess(LetterboxdResponse(503, emptyMap(), emptyList(), "")).send(get) }
        val limited = assertFailsWith<LetterboxdException.RateLimited> { sess(LetterboxdResponse(429, mapOf("retry-after" to "12"), emptyList(), "")).send(get) }
        assertEquals(12_000L, limited.retryAfterMs)
        val defaulted = assertFailsWith<LetterboxdException.RateLimited> { sess(LetterboxdResponse(429, emptyMap(), emptyList(), "")).send(get) }
        assertEquals(LetterboxdSession.DEFAULT_RETRY_AFTER_MS, defaulted.retryAfterMs)
        val capped = assertFailsWith<LetterboxdException.RateLimited> { sess(LetterboxdResponse(429, mapOf("retry-after" to "999999"), emptyList(), "")).send(get) }
        assertEquals(LetterboxdSession.MAX_RETRY_AFTER_MS, capped.retryAfterMs)
        assertFailsWith<LetterboxdException.Blocked> { sess(LetterboxdResponse(200, emptyMap(), emptyList(), "<title>Just a moment...</title>")).send(get) }
        assertFailsWith<LetterboxdException.SessionExpired> { sess(LetterboxdResponse(200, emptyMap(), emptyList(), "<title>Sign in</title>")).send(get, expectJson = true) }
    }

    @Test fun apiHeadersCarryThisSessionsToken() = runTest {
        val site = FakeLetterboxdSite(); val s = session(site); s.refreshCsrf()
        val h = s.apiHeaders("heat")
        assertEquals("tok123", h["X-CSRF-TOKEN"]); assertEquals("XMLHttpRequest", h["X-Requested-With"])
        assertEquals("https://letterboxd.com/film/heat/", h["Referer"]); assertEquals("https://letterboxd.com", h["Origin"])
    }

    @Test fun sessionsDoNotShareCookies() = runTest {
        val a = LetterboxdSession(LetterboxdSessionMaterial(mapOf(LetterboxdSession.CSRF_COOKIE to "A"), "UA", "a"), FakeLetterboxdSite())
        val b = LetterboxdSession(LetterboxdSessionMaterial(mapOf(LetterboxdSession.CSRF_COOKIE to "B"), "UA", "b"), FakeLetterboxdSite())
        assertEquals("A", a.csrf); assertEquals("B", b.csrf)
    }

    @Test fun authBreakerOpensAfterThreeFailuresAndClosesOnSuccessOrReset() {
        val b = LetterboxdAuthBreaker()
        assertFalse(b.recordFailure()); assertFalse(b.recordFailure()); assertTrue(b.recordFailure()); assertTrue(b.isOpen)
        b.reset(); assertFalse(b.isOpen)
        b.recordFailure(); b.recordFailure(); b.recordSuccess(); assertFalse(b.recordFailure()); assertFalse(b.isOpen)
    }
}

class LetterboxdMatchingTest {
    private var clock = 1_000_000L
    private fun setup(site: FakeLetterboxdSite = FakeLetterboxdSite()): Pair<FakeLetterboxdSite, LetterboxdWebService> {
        val kv = MemoryKeyValue()
        val service = LetterboxdWebService(LetterboxdSession(site.material(), site), LetterboxdFilmCache(kv) { clock }, now = { clock }, pause = {}, pageSpacingMs = 0)
        return site to service
    }

    @Test fun aTmdbIdResolvesToTheFilmAndItsIds() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        val film = service.resolveFilm(603)
        assertEquals("the-matrix", film.slug); assertEquals("51561", film.filmId); assertEquals("2a8i", film.productionId)
    }

    @Test fun aResolvedFilmIsCachedAndNotLookedUpAgain() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        service.resolveFilm(603); val before = site.requests.size
        service.resolveFilm(603)
        assertEquals(before, site.requests.size)
    }

    @Test fun aTvEntryIsNeverMatchedToAMovie() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(900, "some-miniseries", "1", "a", tv = true)
        assertFailsWith<LetterboxdException.NotAFilm> { service.resolveFilm(900) }
    }

    @Test fun aRemakeOrNamesakeWithAnotherTmdbIdIsRefused() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(100, "the-thing-2011", "9", "b", pageTmdbId = 200)
        assertFailsWith<LetterboxdException.FilmNotFound> { service.resolveFilm(100) }
        val before = site.requests.size
        assertFailsWith<LetterboxdException.FilmNotFound> { service.resolveFilm(100) } // remembered as a miss, no new requests
        assertEquals(before, site.requests.size)
    }

    @Test fun aMissingFilmIsRememberedBrieflyThenTriedAgain() = runTest {
        val (site, service) = setup()
        assertFailsWith<LetterboxdException.FilmNotFound> { service.resolveFilm(1) }
        val before = site.requests.size
        assertFailsWith<LetterboxdException.FilmNotFound> { service.resolveFilm(1) }
        assertEquals(before, site.requests.size)
        clock += LetterboxdFilmCache.MISS_TTL_MS + 1
        site.films += FakeLetterboxdSite.Film(1, "now-here", "5", "c")
        assertEquals("now-here", service.resolveFilm(1).slug)
    }

    @Test fun missingIdsAreAnErrorNotAGuess() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(7, "no-ids", "1", "a", noIds = true)
        assertFailsWith<LetterboxdException.Unexpected> { service.resolveFilm(7) }
    }

    @Test fun anOldCachedFilmIsLookedUpAgain() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        service.resolveFilm(603); val before = site.requests.size
        clock += LetterboxdFilmCache.FILM_TTL_MS + 1
        service.resolveFilm(603)
        assertTrue(site.requests.size > before)
    }

    @Test fun diaryReadsDistinguishNoEntryFromAFailedCheck() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        val film = service.resolveFilm(603)
        assertFalse(service.diaryInfo(film).hasAnyEntry) // 404: no entry
        site.diary["the-matrix"] = mutableListOf("2026-03-02", "2025-01-09")
        assertEquals(listOf("2025-01-09", "2026-03-02"), service.diaryInfo(film).dates)
        site.diaryStatus = 500
        assertFailsWith<LetterboxdException.Server> { service.diaryInfo(film) } // never "no entry"
        site.diaryStatus = null; site.signedIn = false
        assertFailsWith<LetterboxdException.SessionExpired> { service.diaryInfo(film) }
    }

    @Test fun diaryWriteUsesTheProductionEndpointThenFallsBackOnA404() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        val film = service.resolveFilm(603)
        val write = LetterboxdDiaryWrite(film, "2026-11-21", rewatch = true, liked = true, stars = 4.5, reviewText = "Great 🎬 — \"quoted\"", containsSpoilers = true)
        service.writeDiary(write)
        val first = site.requests.last { it.method == "POST" }
        assertEquals("/api/v0/production-log-entries", first.path)
        val body = Json.parseToJsonElement(first.json!!).jsonObject
        assertEquals("2a8i", body.getValue("productionId").jsonPrimitive.content)
        assertEquals("2026-11-21", body.getValue("diaryDetails").jsonObject.getValue("diaryDate").jsonPrimitive.content)
        assertEquals("true", body.getValue("diaryDetails").jsonObject.getValue("rewatch").jsonPrimitive.content)
        assertEquals("4.5", body.getValue("rating").jsonPrimitive.content)
        assertEquals("Great 🎬 — \"quoted\"", body.getValue("review").jsonObject.getValue("text").jsonPrimitive.content)
        assertEquals("true", body.getValue("review").jsonObject.getValue("containsSpoilers").jsonPrimitive.content)
        assertEquals("tok123", first.headers["X-CSRF-TOKEN"])

        site.writeScript += FakeLetterboxdSite.Write.Status(404)
        service.writeDiary(LetterboxdDiaryWrite(film, "2026-11-22", false))
        val fallback = site.requests.last { it.method == "POST" }
        assertEquals("/api/v0/log-entries", fallback.path)
        val fb = Json.parseToJsonElement(fallback.json!!).jsonObject
        assertEquals("51561", fb.getValue("filmId").jsonPrimitive.content)
        assertNull(fb["rating"]); assertNull(fb["review"])
    }

    @Test fun aDiaryWriteThatAnswersWithAPageIsNotSuccess() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        val film = service.resolveFilm(603)
        site.writeScript += FakeLetterboxdSite.Write.HtmlPage
        assertFailsWith<LetterboxdException.SessionExpired> { service.writeDiary(LetterboxdDiaryWrite(film, "2026-11-21", false)) }
    }

    @Test fun ratingGoesToTheRateActionOnTheSiteScaleAndNeedsResultTrue() = runTest {
        val (site, service) = setup()
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        val film = service.resolveFilm(603)
        service.rateFilm(film, 3.5)
        assertEquals(7, site.ratings["51561"])
        val req = site.requests.last { it.path.endsWith("/rate/") }
        assertEquals("/s/film:51561/rate/", req.path); assertEquals("tok123", req.form!!["__csrf"])
        site.rateBody = """{"result": false, "messages": ["nope"]}"""
        assertFailsWith<LetterboxdException.Unexpected> { service.rateFilm(film, 4.0) }
        assertFailsWith<IllegalArgumentException> { service.rateFilm(film, 3.3) }
    }

    @Test fun aBotCheckStopsEveryRequest() = runTest {
        val (site, service) = setup()
        site.challenge = true
        assertFailsWith<LetterboxdException.Blocked> { service.resolveFilm(603) }
    }
}

class LetterboxdPlaybackTrackerTest {
    private val FILM = 100 * 60_000L

    /** Plays [fromMs] to [toMs] with a sample every 5 s of wall time; returns the completion if one fired. */
    private fun play(t: LetterboxdPlaybackTracker, clock: LongArray, fromMs: Long, toMs: Long, speed: Double = 1.0, endAtEnd: Boolean = false): LetterboxdCompletion? {
        var pos = fromMs
        var result: LetterboxdCompletion? = null
        while (pos < toMs) {
            clock[0] += 5_000; pos = minOf(toMs, pos + (5_000 * speed).toLong())
            t.onSample(pos, FILM, isPlaying = true, isEnded = endAtEnd && pos >= toMs, wallMs = clock[0])?.let { result = it }
        }
        return result
    }

    private fun tracker(initial: WatchedCoverage = WatchedCoverage()) = LetterboxdPlaybackTracker("s1", 1, 603, "The Matrix", initial)

    @Test fun aFilmWatchedStraightThroughCompletesOnce() {
        val t = tracker(); val c = longArrayOf(0)
        val done = play(t, c, 0, FILM, endAtEnd = true)
        // Watching straight through reaches the 95% mark before the credits end, and that is when it counts, once.
        assertNotNull(done); assertTrue(done.watchedFraction >= 0.95)
        assertEquals(null, t.onSample(FILM, FILM, true, true, c[0] + 5000)) // no second completion
    }

    @Test fun reachingTheThresholdCompletesWithoutAnEndEvent() {
        val t = tracker(); val c = longArrayOf(0)
        val done = play(t, c, 0, (FILM * 0.96).toLong())
        assertNotNull(done); assertEquals(LetterboxdCompletionReason.ThresholdReached, done.reason)
    }

    @Test fun seekingToTheEndIsNotWatching() {
        val t = tracker(); val c = longArrayOf(0)
        play(t, c, 0, 30_000)
        // Jump to 99% and let the end play out.
        c[0] += 1_000
        assertNull(t.onSample((FILM * 0.99).toLong(), FILM, true, false, c[0]))
        val done = play(t, c, (FILM * 0.99).toLong(), FILM, endAtEnd = true)
        assertNull(done)
        assertFalse(t.completed)
    }

    @Test fun anEndEventNeedsMostOfTheFilmToHaveBeenWatched() {
        val ninety = tracker(); val c = longArrayOf(0)
        assertNotNull(play(ninety, c, 0, (FILM * 0.9).toLong(), endAtEnd = true)) // skipped some credits: still done
        val skipper = tracker(); val c2 = longArrayOf(0)
        play(skipper, c2, 0, FILM / 10)
        c2[0] += 1000; skipper.onSample(FILM - 10_000, FILM, true, false, c2[0])
        assertNull(play(skipper, c2, FILM - 10_000, FILM, endAtEnd = true))
    }

    @Test fun pausedTimeAndStoppingNeverCount() {
        val t = tracker(); val c = longArrayOf(0)
        play(t, c, 0, FILM / 2)
        val before = t.coverage.totalMs
        repeat(200) { c[0] += 5_000; t.onSample(FILM / 2, FILM, false, false, c[0]) }
        assertEquals(before, t.coverage.totalMs)
        t.onInterrupted()
        assertFalse(t.completed)
    }

    @Test fun fastPlaybackCountsButAFourTimesJumpDoesNot() {
        val fast = tracker(); val c = longArrayOf(0)
        play(fast, c, 0, FILM / 2, speed = 2.0)
        assertTrue(fast.coverage.fraction(FILM) > 0.45)
        val skimming = tracker(); val c2 = longArrayOf(0)
        play(skimming, c2, 0, FILM / 2, speed = 8.0)
        assertTrue(skimming.coverage.fraction(FILM) < 0.05)
    }

    @Test fun progressCarriesAcrossPlayerSessions() {
        val first = tracker(); val c = longArrayOf(0)
        play(first, c, 0, FILM / 2)
        val second = tracker(first.coverage); val c2 = longArrayOf(0)
        val done = play(second, c2, FILM / 2, FILM, endAtEnd = true)
        assertNotNull(done)
    }

    @Test fun rewatchingTheSameStretchCountsOnce() {
        val t = tracker(); val c = longArrayOf(0)
        play(t, c, 0, FILM / 4); t.onInterrupted()
        play(t, c, 0, FILM / 4)
        assertTrue(t.coverage.fraction(FILM) in 0.24..0.26)
    }

    @Test fun shortMediaIsNotAFilm() {
        val t = tracker(); var clock = 0L; var pos = 0L; var any: LetterboxdCompletion? = null
        while (pos < 4 * 60_000L) { clock += 5_000; pos += 5_000; t.onSample(pos, 4 * 60_000L, true, pos >= 4 * 60_000L, clock)?.let { any = it } }
        assertNull(any)
    }

    @Test fun resetCoverageStartsTheNextViewingFromNothing() {
        val t = tracker(); val c = longArrayOf(0)
        assertNotNull(play(t, c, 0, FILM, endAtEnd = true))
        t.resetCoverage(); t.onInterrupted()
        assertEquals(0L, t.coverage.totalMs); assertFalse(t.completed)
        assertNotNull(play(t, c, 0, FILM, endAtEnd = true))
    }
}
