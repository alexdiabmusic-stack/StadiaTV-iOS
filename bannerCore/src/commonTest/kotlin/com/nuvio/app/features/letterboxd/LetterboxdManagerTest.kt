package com.nuvio.app.features.letterboxd

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

private val SIGNED_IN = mapOf(LetterboxdSession.SESSION_COOKIE to "abc", LetterboxdSession.CSRF_COOKIE to "tok123", "cf_clearance" to "cf")

@OptIn(ExperimentalCoroutinesApi::class)
private class ManagerRig(scope: CoroutineScope, val site: FakeLetterboxdSite = FakeLetterboxdSite()) {
    var clock = LetterboxdDates.epochDay("2026-11-21")!! * 86_400_000L + 20 * 3_600_000L
    val kv = MemoryKeyValue()
    val secrets = MemorySecretStore()
    private var ids = 0
    var favorite = false
    val manager = LetterboxdManager(
        kv, secrets, site, scope, now = { clock }, localDate = ::civilDate, newId = { "m${ids++}" },
        isFavorite = { _, _ -> favorite }, pageSpacingMs = 0,
    )

    init {
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        site.films += FakeLetterboxdSite.Film(680, "pulp-fiction", "777", "p1")
    }

    /** Plays a 100-minute film start to end, sampling every 5 seconds. */
    fun playThrough(profile: Int = 1, tmdb: Int = 603, fromMs: Long = 0, toFraction: Double = 1.0) {
        val film = 100 * 60_000L
        var pos = fromMs
        while (pos < film * toFraction) {
            clock += 5_000; pos = minOf((film * toFraction).toLong(), pos + 5_000)
            manager.playbackSample(profile, tmdb, "The Matrix", null, pos, film, true, pos >= film)
        }
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class LetterboxdManagerTest {
    @Test fun signingInStoresTheSessionProtectedAndReportsConnected() = runTest {
        val rig = ManagerRig(managerScope())
        val result = rig.manager.connect(1, SIGNED_IN, "UA/1")
        assertEquals(LetterboxdConnectResult.Connected("tester"), result)
        assertEquals(LetterboxdConnectionState.Connected, rig.manager.stateOf(1))
        assertEquals("tester", rig.manager.accountOf(1))
        val secret = rig.secrets.map.getValue(1)
        assertTrue(secret.contains("letterboxd.user.CURRENT") && secret.contains("UA/1"))
        // The session material is in the secret store only, never in the plain key-value store.
        assertTrue(rig.kv.map.values.none { it.contains("abc") && it.contains("letterboxd.user.CURRENT") })
        assertTrue(rig.kv.map.values.none { it.contains("tok123") })
    }

    @Test fun aSignInWithoutASessionCookieIsRefusedAndStoresNothing() = runTest {
        val rig = ManagerRig(managerScope())
        assertIs<LetterboxdConnectResult.Failed>(rig.manager.connect(1, mapOf("cf_clearance" to "x"), "UA"))
        assertEquals(LetterboxdConnectionState.Disconnected, rig.manager.stateOf(1))
        assertTrue(rig.secrets.map.isEmpty())
    }

    @Test fun aSignedOutSessionIsNotAccepted() = runTest {
        val rig = ManagerRig(managerScope()); rig.site.signedIn = false
        assertIs<LetterboxdConnectResult.Failed>(rig.manager.connect(1, SIGNED_IN, "UA"))
        assertTrue(rig.secrets.map.isEmpty()); assertNull(rig.manager.accountOf(1))
    }

    @Test fun anUnreadableUsernameAsksTheMemberAndTheirAnswerIsChecked() = runTest {
        val rig = ManagerRig(managerScope()); rig.site.settingsUsername = null
        assertEquals(LetterboxdConnectResult.NeedsUsername, rig.manager.connect(1, SIGNED_IN, "UA"))
        assertNull(rig.manager.accountOf(1))
        rig.site.profileExists = false
        assertIs<LetterboxdConnectResult.Failed>(rig.manager.connect(1, SIGNED_IN, "UA", usernameHint = "tester"))
        rig.site.profileExists = true
        assertIs<LetterboxdConnectResult.Failed>(rig.manager.connect(1, SIGNED_IN, "UA", usernameHint = "not a name!"))
        assertEquals(LetterboxdConnectResult.Connected("tester"), rig.manager.connect(1, SIGNED_IN, "UA", usernameHint = "tester"))
    }

    @Test fun aTypedUsernameThatDisagreesWithTheSiteIsRefused() = runTest {
        val rig = ManagerRig(managerScope()) // the settings page says "tester"
        val r = rig.manager.connect(1, SIGNED_IN, "UA", usernameHint = "someoneelse")
        assertIs<LetterboxdConnectResult.Failed>(r); assertNull(rig.manager.accountOf(1))
    }

    @Test fun reconnectingMustBeTheSameAccount() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.settingsUsername = "other_person"
        assertIs<LetterboxdConnectResult.Failed>(rig.manager.connect(1, SIGNED_IN, "UA"))
        assertEquals("tester", rig.manager.accountOf(1))
    }

    @Test fun disconnectDeletesTheSessionAndStopsEverything() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.writeScript += FakeLetterboxdSite.Write.Offline
        rig.playThrough(); advanceUntilIdle()
        rig.manager.disconnect(1, deleteLocalHistory = false)
        assertTrue(rig.secrets.map.isEmpty()); assertNull(rig.manager.accountOf(1))
        assertEquals(LetterboxdConnectionState.Disconnected, rig.manager.stateOf(1))
        assertTrue(rig.manager.engine.operations.value.none { it.status != LetterboxdOperationStatus.Succeeded && it.status != LetterboxdOperationStatus.Skipped })
        val before = rig.site.requests.size
        rig.playThrough(); advanceUntilIdle() // nothing is tracked or sent any more
        assertEquals(before, rig.site.requests.size)
    }

    @Test fun profilesKeepTheirOwnAccountsAndSessions() = runTest {
        val a = FakeLetterboxdSite("alice"); val rig = ManagerRig(managerScope(), a)
        rig.manager.connect(1, SIGNED_IN, "UA-alice")
        assertEquals("alice", rig.manager.accountOf(1)); assertNull(rig.manager.accountOf(2))
        rig.playThrough(profile = 2); advanceUntilIdle()
        assertEquals(0, rig.site.writeCount)
        rig.manager.disconnect(2, deleteLocalHistory = true)
        assertEquals("alice", rig.manager.accountOf(1))
    }

    @Test fun accountsSettingsAndStateSurviveARestart() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.manager.updateSettings(1) { it.copy(syncFavorites = true, completionThreshold = 0.9) }
        val again = LetterboxdManager(rig.kv, rig.secrets, rig.site, managerScope(), now = { rig.clock }, localDate = ::civilDate, newId = { "z" }, pageSpacingMs = 0)
        assertEquals("tester", again.accountOf(1)); assertTrue(again.settingsOf(1).syncFavorites); assertEquals(0.9, again.settingsOf(1).completionThreshold)
        assertEquals(LetterboxdConnectionState.Connected, again.stateOf(1))
        assertTrue(again.serviceOf(1) != null)
    }

    @Test fun anExpiredSessionIsDetectedAndPersistedAsNeedingReconnect() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.signedIn = false
        assertEquals(LetterboxdConnectionState.SessionExpired, rig.manager.checkConnection(1))
        val again = LetterboxdManager(rig.kv, rig.secrets, rig.site, managerScope(), now = { rig.clock }, localDate = ::civilDate, newId = { "z" }, pageSpacingMs = 0)
        assertEquals(LetterboxdConnectionState.SessionExpired, again.stateOf(1))
        rig.site.signedIn = true
        assertEquals(LetterboxdConnectionState.Connected, rig.manager.checkConnection(1))
    }

    @Test fun thresholdIsKeptInASafeRange() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.updateSettings(1) { it.copy(completionThreshold = 0.1) }; assertEquals(0.8, rig.manager.settingsOf(1).completionThreshold)
        rig.manager.updateSettings(1) { it.copy(completionThreshold = 5.0) }; assertEquals(1.0, rig.manager.settingsOf(1).completionThreshold)
    }

    // ---- playback end to end

    @Test fun watchingAFilmThroughLogsItOnceWithTheViewersDate() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.playThrough(); advanceUntilIdle()
        assertEquals(1, rig.site.writeCount)
        assertEquals("2026-11-21", rig.site.diaryWrites.single().toString().substringAfter("diaryDate\":\"").substringBefore("\""))
        // Keeping the player open on the credits and sampling more does not log it again.
        rig.manager.playbackSample(1, 603, "The Matrix", null, 100 * 60_000L, 100 * 60_000L, false, true); advanceUntilIdle()
        assertEquals(1, rig.site.writeCount)
    }

    @Test fun skippingToTheEndLogsNothing() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.playThrough(toFraction = 0.02)
        rig.clock += 1_000
        rig.manager.playbackSample(1, 603, "The Matrix", null, 99 * 60_000L, 100 * 60_000L, true, false)
        rig.manager.playbackSample(1, 603, "The Matrix", null, 100 * 60_000L, 100 * 60_000L, false, true)
        advanceUntilIdle()
        assertEquals(0, rig.site.writeCount); assertTrue(rig.manager.engine.viewings.value.isEmpty())
    }

    @Test fun stoppingMidwayKeepsProgressAndAFollowingSessionFinishesTheFilm() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.playThrough(toFraction = 0.5); rig.manager.playbackStopped(1, 603); advanceUntilIdle()
        assertEquals(0, rig.site.writeCount)
        assertTrue(rig.manager.engine.coverageNow(1, 603).fraction(100 * 60_000L) > 0.45)
        rig.playThrough(fromMs = 50 * 60_000L); advanceUntilIdle()
        assertEquals(1, rig.site.writeCount)
    }

    @Test fun anAccountlessProfileTracksNothing() = runTest {
        val rig = ManagerRig(managerScope())
        rig.playThrough(); advanceUntilIdle()
        assertEquals(0, rig.site.requests.size); assertTrue(rig.manager.engine.viewings.value.isEmpty())
    }

    @Test fun theFinishedViewingIsAnnouncedForThePostWatchSheet() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        val seen = mutableListOf<LetterboxdViewing>()
        managerScope().launchCollect(rig.manager.finishedViewings) { seen += it }
        rig.playThrough(); advanceUntilIdle()
        assertEquals(1, seen.size); assertEquals(603, seen.single().tmdbId)
    }

    @Test fun favouritesBecomeLikesOnlyWithTheSetting() = runTest {
        val rig = ManagerRig(managerScope()); rig.favorite = true
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.manager.updateSettings(1) { it.copy(syncFavorites = true) }
        rig.playThrough(); advanceUntilIdle()
        assertTrue(rig.site.diaryWrites.single().toString().contains("\"like\":true"))
    }

    @Test fun aRatingIsSentAfterItsDebounce() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.manager.setRating(1, 603, "The Matrix", 4.0); rig.manager.setRating(1, 603, "The Matrix", 4.5)
        advanceUntilIdle()
        // The debounce is on the manager's injected clock; move it and let the queue run.
        rig.clock += LetterboxdSyncEngine.RATING_DEBOUNCE_MS + 1_000
        rig.manager.engine.processPending()
        assertEquals(mapOf("51561" to 9), rig.site.ratings)
    }

    @Test fun wipingTheAppAccountRemovesEverythingForEveryProfile() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.manager.updateSettings(1) { it.copy(syncFavorites = true) }
        rig.playThrough(); advanceUntilIdle()
        rig.secrets.write(3, "{\"cookies\":{},\"userAgent\":\"u\",\"username\":\"x\"}") // a leftover from a profile with no record
        rig.manager.wipeAll()
        assertTrue(rig.secrets.map.isEmpty())
        assertNull(rig.manager.accountOf(1)); assertEquals(LetterboxdSettings(), rig.manager.settingsOf(1))
        assertTrue(rig.manager.engine.viewings.value.isEmpty()); assertTrue(rig.manager.engine.operations.value.isEmpty()); assertTrue(rig.manager.engine.events.value.isEmpty())
        assertTrue(rig.kv.map.keys.none { it.startsWith("letterboxd_ops") || it.startsWith("letterboxd_viewings") || it.startsWith("letterboxd_accounts") })
    }

    // ---- import

    @Test fun diaryImportIsIdempotentAndWritesNothingToLetterboxd() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.diaryRows += Triple("the-matrix", "2026-03-02", 4.5)
        rig.site.diaryRows += Triple("pulp-fiction", "2025-12-25", null)
        rig.site.diaryRows += Triple("the-matrix", "2024-01-05", 3.0)
        val writesBefore = rig.site.writeCount
        val first = rig.manager.importDiary(1)
        assertEquals(3, first.newViewings); assertFalse(first.partial); assertEquals(0, first.unmatched)
        val second = rig.manager.importDiary(1)
        assertEquals(0, second.newViewings); assertEquals(3, second.alreadyKnown)
        assertEquals(writesBefore, rig.site.writeCount)
        val matrix = rig.manager.engine.viewingsFor(1, 603)
        assertEquals(2, matrix.size); assertTrue(matrix.all { it.onDiary && it.source == "import" })
        assertEquals(4.5, matrix.first().stars)
        // An imported rating is known to be on Letterboxd, so choosing it again sends nothing.
        rig.manager.engine.setRating(1, 603, "The Matrix", 4.5, null)
        rig.clock += LetterboxdSyncEngine.RATING_DEBOUNCE_MS + 1; rig.manager.engine.processPending()
        assertEquals(0, rig.site.requests.count { it.path.endsWith("/rate/") })
    }

    @Test fun aLongDiaryIsImportedInRunsAndReportedAsPartial() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.films += FakeLetterboxdSite.Film(11, "star-wars", "888", "s1")
        rig.site.diaryRows += Triple("the-matrix", "2026-03-02", null)
        rig.site.diaryRows += Triple("pulp-fiction", "2026-03-03", null)
        rig.site.diaryRows += Triple("star-wars", "2026-03-04", null)
        val first = rig.manager.importDiary(1, maxFilms = 2)
        assertTrue(first.partial); assertEquals(2, first.newViewings)
        val second = rig.manager.importDiary(1, maxFilms = 2)
        assertEquals(1, second.newViewings); assertFalse(second.partial)
        assertEquals(3, rig.manager.engine.viewings.value.size)
    }

    @Test fun theWatchedFilmsListIsImportedAsUndatedViewingsAndDiaryFilmsAreNotDuplicated() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.films += FakeLetterboxdSite.Film(11, "star-wars", "888", "s1")
        rig.site.diaryRows += Triple("the-matrix", "2026-03-02", 4.5)
        // Three pages of the grid (two per page): one film is also in the diary, two are not, one is unknown to TMDB.
        rig.site.watchedList += Triple("the-matrix", "The Matrix", 4.5)
        rig.site.watchedList += Triple("pulp-fiction", "Pulp Fiction", null)
        rig.site.watchedList += Triple("star-wars", "Star Wars", 3.0)
        rig.site.watchedList += Triple("mystery-film", "Mystery Film", null)
        val writesBefore = rig.site.writeCount
        val first = rig.manager.importDiary(1)
        assertEquals(3, first.newViewings); assertFalse(first.partial); assertEquals(1, first.unmatched)
        val undated = rig.manager.engine.viewings.value.filter { it.localDate == LetterboxdViewing.UNDATED }
        assertEquals(setOf("Pulp Fiction", "Star Wars"), undated.map { it.title }.toSet())
        assertEquals(1, rig.manager.engine.viewingsFor(1, 603).size) // the diary entry only
        val again = rig.manager.importDiary(1)
        assertEquals(0, again.newViewings)
        assertEquals(writesBefore, rig.site.writeCount)
    }

    @Test fun anImportWithoutTheWatchedListReadsOnlyTheDiary() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.diaryRows += Triple("the-matrix", "2026-03-02", null)
        rig.site.watchedList += Triple("pulp-fiction", "Pulp Fiction", null)
        val r = rig.manager.importDiary(1, includeWatchedList = false)
        assertEquals(1, r.newViewings)
        assertTrue(rig.site.requests.none { it.path.startsWith("/${rig.site.userName}/films/") })
    }

    @Test fun aBlockedFilmPageStopsTheImportWithAReasonInsteadOfCallingEveryFilmUnmatched() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.diaryRows += Triple("the-matrix", "2026-03-02", null)
        rig.site.challenge = true
        val r = rig.manager.importDiary(1)
        assertTrue(r.partial); assertEquals(0, r.unmatched); assertTrue(r.message?.startsWith("Stopped early") == true)
    }

    @Test fun aFilmLetterboxdKnowsButTmdbDoesNotIsCountedAsUnmatched() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.diaryRows += Triple("mystery-film", "2026-03-02", null) // no such film page
        val r = rig.manager.importDiary(1)
        assertEquals(0, r.newViewings); assertEquals(1, r.unmatched)
    }

    @Test fun anImportWithAnExpiredSessionStopsPartiallyAndSaysSo() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA")
        rig.site.diaryRows += Triple("the-matrix", "2026-03-02", null)
        rig.site.signedIn = false
        val r = rig.manager.importDiary(1)
        assertEquals(0, r.newViewings); assertTrue(r.partial)
        assertEquals(LetterboxdConnectionState.SessionExpired, rig.manager.stateOf(1))
    }

    @Test fun theDiaryRowParserReadsTheMarkupItKnows() {
        val html = """<table><tr class="diary-entry-row"><td><a href="/u/diary/films/for/2026/3/2/">2</a></td>
            <td><div data-film-slug="heat"></div></td><td class="td-rewatch center icon-status-off"></td><span class="rated-9"></span></tr>
            <tr class="diary-entry-row"><td><a href="/u/diary/films/for/2025/12/25/">25</a></td><td><div data-item-slug="alien"></div></td>
            <td class="td-rewatch center"></td></tr></table>"""
        assertEquals(
            listOf(LetterboxdDiaryRow("heat", "2026-03-02", 4.5, false), LetterboxdDiaryRow("alien", "2025-12-25", null, true)),
            LetterboxdHtml.diaryRows(html),
        )
    }

    @Test fun theWatchedGridParserReadsTheLiveGridMarkup() {
        val html = """<ul><li class="griditem"><div class="react-component" data-item-name="The Love Hypothesis (2026)" data-item-slug="the-love-hypothesis"></div>
            <p class="poster-viewingdata"><span class="rating -micro -darker rated-6">★★★</span></p></li>
            <li class="griditem"><div class="react-component" data-item-name="Heat (1995)" data-item-slug="heat"></div><p class="poster-viewingdata"></p></li></ul>
            <div class="pagination"><a class="next" href="/u/films/page/2/">Older</a></div>"""
        assertEquals(
            listOf(LetterboxdGridFilm("the-love-hypothesis", "The Love Hypothesis", 3.0, "2026"), LetterboxdGridFilm("heat", "Heat", null, "1995")),
            LetterboxdHtml.watchedGrid(html),
        )
        assertTrue(LetterboxdHtml.hasNextPage(html, 1))
        assertFalse(LetterboxdHtml.hasNextPage("<div class=\"pagination\"><span class=\"next\">x</span></div>", 5))
    }
}

private fun CoroutineScope.launchCollect(flow: kotlinx.coroutines.flow.Flow<LetterboxdViewing>, block: (LetterboxdViewing) -> Unit) {
    launch(start = CoroutineStart.UNDISPATCHED) { flow.collect { block(it) } }
}

/** The manager's own scope for a test: it runs eagerly on the test's virtual clock. */
@OptIn(ExperimentalCoroutinesApi::class)
private fun TestScope.managerScope(): CoroutineScope = CoroutineScope(UnconfinedTestDispatcher(testScheduler))

@OptIn(ExperimentalCoroutinesApi::class)
class LetterboxdSettingsScreenFlowTest {
    private val clock = com.nuvio.app.features.serializd.SerializdClock { 0L }

    @Test fun theScreenStateFollowsTheAccountTheJournalAndTheSettings() = runTest {
        val rig = ManagerRig(managerScope())
        assertNull(rig.manager.screenNow(1, clock).username, "nothing is shown as connected before sign-in")
        rig.manager.connect(1, SIGNED_IN, "UA/1")
        val connected = rig.manager.screenNow(1, clock)
        assertEquals("tester", connected.username); assertEquals("Connected to Letterboxd", connected.connectionLabel)
        assertTrue(connected.logFilms && connected.syncRatings && connected.syncWatchlist, "the defaults are all on")
        assertEquals("Nothing logged yet", connected.watchHistoryLine)
        rig.playThrough(); advanceUntilIdle()
        assertEquals("1 film in your journal", rig.manager.screenNow(1, clock).watchHistoryLine)
        rig.manager.updateSettings(1) { it.copy(autoLogMovies = false) }
        val off = rig.manager.screenNow(1, clock)
        assertFalse(off.logFilms); assertTrue(off.settings.logRewatches && off.settings.syncRatings, "turning logging off keeps the other choices")
    }

    @Test fun theWatchlistSwitchStopsAndRestartsReadingIntoMyList() = runTest {
        val rig = ManagerRig(managerScope())
        rig.manager.connect(1, SIGNED_IN, "UA/1")
        rig.site.watchlist += "the-matrix" to "The Matrix (1999)"
        assertNull(rig.manager.setSyncWatchlist(1, false))
        assertFalse(rig.manager.screenNow(1, clock).syncWatchlist)
        val note = rig.manager.setSyncWatchlist(1, true)
        assertTrue(rig.manager.screenNow(1, clock).syncWatchlist); assertTrue(note != null)
        assertEquals("1 film", rig.manager.screenNow(1, clock).watchlistLine)
    }
}
