package com.nuvio.app.features.serializd

import com.nuvio.app.features.watchlist.WatchlistApplyResult
import com.nuvio.app.features.watchlist.WatchlistSink
import com.nuvio.app.features.watchlist.WatchlistTitle
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private const val CLOCK0 = 1_700_000_000_000L
private const val SECRET_PASSWORD = "hunter2-secret"

private class ManagerRig(scope: CoroutineScope) {
    val server = FakeSerializdServer().also {
        it.users[0] = FakeSerializdServer.User("a@example.com", SECRET_PASSWORD, "alice")
        it.users += FakeSerializdServer.User("b@example.com", "bobs-password", "bob")
    }
    val kv = MemorySerializdKv()
    val secrets = MemorySecrets()
    var clock = CLOCK0
    var sinkFails = false
    var myListFails = false
    val applied = mutableListOf<SerializdImportedEpisode>()
    /** Each batch of watchlist titles handed to My List. */
    val myList = mutableListOf<List<WatchlistTitle>>()
    private var ids = 0
    val manager = SerializdManager(
        kv = kv, secrets = secrets, transport = server, scope = scope, now = { clock }, newId = { "m${ids++}" },
        importSink = SerializdImportSink { _, episodes -> if (sinkFails) error("the watched list is unavailable"); applied += episodes },
        watchlistSink = WatchlistSink { _, source, titles ->
            check(source == "serializd")
            if (myListFails) error("My List is unavailable")
            myList += titles; WatchlistApplyResult(titles.size, 0, 0, 0, 0)
        },
        pause = {},
    )

    suspend fun connectAlice(profile: Int = 1) = manager.connect(profile, "a@example.com", SECRET_PASSWORD)

    /** Plays [fromMs]..[toMs] of an episode, one sample a second, the clock moving with the playback. */
    fun play(profile: Int = 1, show: Int = 1399, season: Int = 1, episode: Int = 1, durationMs: Long = 40 * 60_000L, fromMs: Long = 0, toMs: Long = durationMs) {
        var p = fromMs
        while (p <= toMs) {
            clock += 1_000
            manager.playbackSample(profile, show, season, episode, "Game of Thrones", "Winter Is Coming", null, p, durationMs, true, p >= durationMs)
            p += 1_000
        }
    }

    val writes get() = server.requests.filter { it.method == "POST" && it.path != "/login" && it.path != "/validateauthtoken" }
}

class SerializdManagerConnectionTest {
    @Test fun connectingChecksTheAccountFirstAndKeepsCredentialsOnlyInProtectedStorage() = runTest {
        val rig = ManagerRig(this)
        assertEquals(SerializdConnectionState.Disconnected, rig.manager.stateOf(1))
        val result = rig.connectAlice()
        assertEquals(SerializdConnectResult.Connected("alice"), result)
        assertEquals(SerializdConnectionState.Connected, rig.manager.stateOf(1)); assertEquals("alice", rig.manager.accountOf(1))
        advanceUntilIdle()
        val secret = rig.secrets.read(1)!!
        assertTrue("a@example.com" in secret && SECRET_PASSWORD in secret, "the sign-in is in the protected store")
        assertTrue(rig.kv.map.values.none { SECRET_PASSWORD in it || "a@example.com" in it || "tok-" in it }, "never in preferences")
    }

    @Test fun aWrongPasswordNeverShowsConnectedAndStoresNothing() = runTest {
        val rig = ManagerRig(this)
        val r = rig.manager.connect(1, "a@example.com", "nope")
        assertIs<SerializdConnectResult.Failed>(r)
        assertEquals(SerializdConnectionState.Disconnected, rig.manager.stateOf(1)); assertNull(rig.manager.accountOf(1)); assertNull(rig.secrets.read(1))
        assertIs<SerializdConnectResult.Failed>(rig.manager.connect(1, " ", ""))
    }

    @Test fun repeatedWrongPasswordsAreLockedOutForAWhile() = runTest {
        val rig = ManagerRig(this)
        repeat(3) { assertIs<SerializdConnectResult.Failed>(rig.manager.connect(1, "a@example.com", "bad$it")) }
        val locked = rig.manager.connect(1, "a@example.com", SECRET_PASSWORD)
        assertIs<SerializdConnectResult.TooManyAttempts>(locked); assertTrue(locked.waitMs > 0)
        assertEquals(3, rig.server.loginCalls, "no request was made while locked out")
        rig.clock += 31_000
        assertIs<SerializdConnectResult.Connected>(rig.connectAlice())
    }

    @Test fun anUnreachableServiceIsSaidApartFromBadCredentials() = runTest {
        val rig = ManagerRig(this)
        val failing = SerializdManager(rig.kv, rig.secrets, ScriptTransport(SerializdException.Network("down"), SerializdException.Network("down"), SerializdException.Network("down"), SerializdException.Network("down")), this, newId = { "x" }, pause = {})
        val r = failing.connect(1, "a@example.com", "pw") as SerializdConnectResult.Failed
        assertTrue("reach" in r.message, r.message); assertFalse("password" in r.message)
        val busy = SerializdManager(MemorySerializdKv(), MemorySecrets(), ScriptTransport(reply(503), reply(503), reply(503), reply(503)), this, newId = { "x" }, pause = {})
        assertTrue("trouble" in (busy.connect(1, "a@example.com", "pw") as SerializdConnectResult.Failed).message)
    }

    @Test fun aProfileCanOnlyReconnectAsItsOwnAccount() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        val other = rig.manager.connect(1, "b@example.com", "bobs-password") as SerializdConnectResult.Failed
        assertTrue("alice" in other.message)
        assertEquals("alice", rig.manager.accountOf(1)); assertTrue(SECRET_PASSWORD in rig.secrets.read(1)!!)
    }

    @Test fun profilesStayIsolatedAndDisconnectingOneTouchesNoOther() = runTest {
        val rig = ManagerRig(this)
        rig.connectAlice(1); rig.manager.connect(2, "b@example.com", "bobs-password"); advanceUntilIdle()
        rig.manager.engine.onCompletion(SerializdCompletion("a", 1, 1399, 1, listOf(1), "GoT", null, rig.clock, 1.0), null, false)
        rig.manager.engine.onCompletion(SerializdCompletion("b", 2, 1399, 1, listOf(2), "GoT", null, rig.clock, 1.0), null, false)
        rig.manager.engine.processPending(); advanceUntilIdle()
        val owners = rig.server.authLog.filter { it.first == "/episode_log/add" || it.first == "/show/reviews/add" }
        assertEquals(setOf("alice", "bob"), owners.map { it.second }.toSet())
        assertEquals(2, rig.server.diary.size)
        // Queue one more for each, then disconnect Alice.
        rig.manager.engine.onCompletion(SerializdCompletion("a2", 1, 1399, 1, listOf(5), "GoT", null, rig.clock, 1.0), null, false)
        rig.manager.engine.onCompletion(SerializdCompletion("b2", 2, 1399, 1, listOf(6), "GoT", null, rig.clock, 1.0), null, false)
        rig.manager.disconnect(1, deleteLocalHistory = true)
        assertNull(rig.secrets.read(1)); assertNull(rig.manager.accountOf(1)); assertNotNull(rig.secrets.read(2)); assertEquals("bob", rig.manager.accountOf(2))
        rig.manager.engine.processPending(); advanceUntilIdle()
        assertTrue(rig.server.diary.any { it.episodeNumber == 6 }, "Bob's queued entry was sent"); assertTrue(rig.server.diary.none { it.episodeNumber == 5 }, "Alice's was dropped")
        assertTrue(rig.manager.engine.operations.value.none { it.account == "alice" }); assertTrue(rig.manager.engine.watches.value.none { it.profileId == 1 })
    }

    @Test fun disconnectingDeletesTheCredentialsAndSettings() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.manager.updateSettings(1) { it.copy(syncRatings = false) }
        rig.manager.disconnect(1, deleteLocalHistory = true)
        assertNull(rig.secrets.read(1)); assertEquals(SerializdSettings(), rig.manager.settingsOf(1)); assertEquals(SerializdConnectionState.Disconnected, rig.manager.stateOf(1))
        assertTrue(rig.kv.map.values.none { SECRET_PASSWORD in it })
    }

    @Test fun anAccountWipeRemovesEveryProfilesSignInAndRecords() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(1); rig.manager.connect(2, "b@example.com", "bobs-password"); advanceUntilIdle()
        rig.manager.wipeAll()
        assertTrue(rig.secrets.map.isEmpty()); assertTrue(rig.manager.accountsFlow.value.isEmpty()); assertTrue(rig.manager.engine.watches.value.isEmpty())
        assertTrue(rig.kv.map.values.none { SECRET_PASSWORD in it })
    }

    @Test fun theSavedTokenIsReusedAcrossARestartInsteadOfSigningInAgain() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        val loginsBefore = rig.server.loginCalls
        var n = 0
        val reopened = SerializdManager(rig.kv, rig.secrets, rig.server, this, now = { rig.clock }, newId = { "n${n++}" }, pause = {})
        reopened.engine.onCompletion(SerializdCompletion("z", 1, 1399, 1, listOf(3), "GoT", null, rig.clock, 1.0), null, false)
        reopened.engine.processPending(); advanceUntilIdle()
        assertEquals(loginsBefore, rig.server.loginCalls); assertEquals(1, rig.server.diary.count { it.episodeNumber == 3 })
    }

    @Test fun aStaleTokenIsRenewedQuietlyAndAChangedPasswordAsksToReconnect() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.expireTokens()
        assertEquals(SerializdConnectionState.Connected, rig.manager.checkConnection(1))
        rig.server.users[0] = rig.server.users[0].copy(password = "changed"); rig.server.expireTokens()
        assertEquals(SerializdConnectionState.ReconnectionRequired, rig.manager.checkConnection(1))
        assertEquals("alice", rig.manager.accountOf(1), "the account stays; only the sign-in needs redoing")
    }

    @Test fun connectingReadsWhatIsOnSerializdButNeverSendsBannerTVsOwnHistory() = runTest {
        val rig = ManagerRig(this)
        rig.server.log(1399, 1, 1, "2026-10-01T20:00:00Z"); rig.server.log(1399, 1, 2, "2026-10-02T20:00:00Z")
        rig.server.watchlist += 1399 to listOf(3624)
        rig.connectAlice(); advanceUntilIdle()
        assertEquals(2, rig.applied.size); assertTrue(rig.writes.isEmpty(), "nothing was written to Serializd")
        assertEquals(1, rig.manager.watchlistFlow.value[1]!!.entries.size); assertTrue(rig.server.markers.isEmpty())
        assertTrue(rig.manager.accountsFlow.value[1]!!.lastImportAtMs > 0)
    }
}

class SerializdManagerPlaybackTest {
    @Test fun watchingAnEpisodeThroughMarksItWatchedAndLogsItWithoutBlockingPlayback() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.play(toMs = 38 * 60_000L)
        advanceUntilIdle()
        assertEquals(setOf(Triple(1399, 3624, 1)), rig.server.markers)
        val entry = rig.server.diary.single()
        assertEquals(1, entry.episodeNumber); assertFalse(entry.isRewatch)
        assertTrue(SerializdDates.parse(entry.backdate)!!.ms in CLOCK0..rig.clock)
    }

    @Test fun skippingToTheEndIsNotWatching() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.play(toMs = 60_000L)
        rig.play(fromMs = 39 * 60_000L, toMs = 40 * 60_000L)
        advanceUntilIdle()
        assertTrue(rig.server.diary.isEmpty()); assertTrue(rig.writes.isEmpty())
    }

    @Test fun stoppingNeverCompletesAnEpisodeButProgressIsKept() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.play(toMs = 20 * 60_000L)
        rig.manager.playbackStopped(1, 1399, 1, 1); advanceUntilIdle()
        assertTrue(rig.server.diary.isEmpty())
        rig.play(fromMs = 20 * 60_000L, toMs = 37 * 60_000L) // the other part, another evening
        advanceUntilIdle()
        assertEquals(1, rig.server.diary.size)
    }

    @Test fun watchingTheSameEpisodeAgainLaterIsARewatch() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.play(toMs = 38 * 60_000L); advanceUntilIdle()
        rig.play(toMs = 38 * 60_000L); advanceUntilIdle()
        assertEquals(2, rig.server.diary.size); assertTrue(rig.server.diary.first().isRewatch)
        assertEquals(1, rig.server.posts("/episode_log/add").size)
    }

    @Test fun trackingOffNoAccountAndNonEpisodesAreIgnored() = runTest {
        val rig = ManagerRig(this)
        rig.play(toMs = 38 * 60_000L); advanceUntilIdle()
        assertTrue(rig.server.requests.isEmpty(), "no account")
        rig.connectAlice(); advanceUntilIdle()
        rig.manager.updateSettings(1) { it.copy(autoTrackEpisodes = false) }
        rig.play(toMs = 38 * 60_000L); advanceUntilIdle()
        assertTrue(rig.writes.isEmpty(), "tracking off")
        rig.manager.updateSettings(1) { it.copy(autoTrackEpisodes = true) }
        rig.play(episode = 0, toMs = 38 * 60_000L); rig.play(show = 0, toMs = 38 * 60_000L); advanceUntilIdle()
        assertTrue(rig.writes.isEmpty(), "an item with no episode number or no show id is not an episode")
    }
}

class SerializdManagerImportTest {
    @Test fun anImportReadsEveryPageAndWritesNothingToSerializd() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.log(1399, 1, 1, "2026-10-01T20:00:00Z", rating = 8)
        rig.server.log(1399, 1, 2, "2026-10-02T20:00:00Z")
        rig.server.log(1399, null, null, "2026-10-03T20:00:00Z", rating = 9, text = "Great show")
        rig.server.log(1399, 2, null, "2026-10-04T20:00:00Z", rating = 7)
        rig.server.log(1399, 1, 1, "2026-10-05T20:00:00Z", rewatch = true)
        val writesBefore = rig.writes.size
        val result = rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertEquals(2, result.newEpisodes); assertEquals(3, result.pagesRead); assertFalse(result.partial)
        val e1 = rig.applied.first { it.episodeNumber == 1 }
        assertEquals(SerializdDates.parse("2026-10-05T20:00:00Z")!!.ms, e1.watchedAtMs, "the newest viewing's date")
        assertEquals(writesBefore, rig.writes.size)
        val watches = rig.manager.engine.watches.value
        assertEquals(3, watches.size); assertTrue(watches.all { it.source == SerializdWatch.SOURCE_IMPORT && it.onDiary && it.markedWatched && it.remoteReviewId != null })
        assertTrue(watches.any { it.rewatch })
        assertEquals(2, rig.manager.remoteEntriesFlow.value["alice"]!!.size)
        assertEquals(4.5, rig.manager.engine.knownRating("alice", SerializdTarget(1399)))
        assertEquals(4.0, rig.manager.engine.knownRating("alice", SerializdTarget(1399, 1, 1)), "a later entry with no rating does not erase the rating")
    }

    @Test fun showAndSeasonEntriesAreNeverTreatedAsEpisodes() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.log(1399, null, null, "2026-10-03T20:00:00Z", rating = 9, text = "Whole show")
        rig.server.log(1399, 2, null, "2026-10-04T20:00:00Z", rating = 7, text = "Whole season")
        rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertTrue(rig.applied.isEmpty()); assertTrue(rig.manager.engine.watches.value.isEmpty())
        assertTrue(rig.manager.remoteEntriesFlow.value["alice"]!!.any { it.reviewText == "Whole show" && it.seasonNumber == null && it.episodeNumber == null })
    }

    @Test fun runningItAgainAddsNothingAndMakesNoDuplicates() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.log(1399, 1, 1, "2026-10-01T20:00:00Z"); rig.server.log(1399, 1, 2, "2026-10-02T20:00:00Z")
        rig.manager.importHistory(1, includeWatchedSeasons = false)
        val first = rig.applied.size; val watches = rig.manager.engine.watches.value.size
        val again = rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertEquals(0, again.newEpisodes); assertEquals(first, rig.applied.size); assertEquals(watches, rig.manager.engine.watches.value.size); assertEquals(2, again.alreadyKnown)
    }

    @Test fun anImportedEpisodeIsNeverSentBack() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.log(1399, 1, 1, "2026-10-01T20:00:00Z")
        rig.manager.importHistory(1, includeWatchedSeasons = false)
        rig.manager.engine.processPending(); rig.manager.syncNow(); advanceUntilIdle()
        assertTrue(rig.writes.isEmpty()); assertTrue(rig.manager.engine.isMarkerKnown("alice", SerializdTarget(1399, 1, 1)))
        assertTrue(rig.manager.engine.operations.value.isEmpty())
    }

    @Test fun existingLocalRecordsArePreservedAndNothingIsDoubled() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.manager.engine.onCompletion(SerializdCompletion("local", 1, 1399, 1, listOf(1), "GoT", null, CLOCK0, 1.0), null, false)
        rig.manager.engine.processPending(); advanceUntilIdle()
        rig.server.log(1399, 1, 1, "2026-10-01T20:00:00Z"); rig.server.log(1399, 1, 2, "2026-10-02T20:00:00Z")
        rig.applied.clear()
        val r = rig.manager.importHistory(1, includeWatchedSeasons = false)
        // The diary now holds three entries: the member's own from before, the one BannerTV sent for the local viewing, and episode 2.
        assertEquals(1, r.newEpisodes); assertEquals(2, r.alreadyKnown)
        assertEquals(listOf(2), rig.applied.map { it.episodeNumber })
        val kept = rig.manager.engine.watches.value
        assertTrue(kept.any { it.source == SerializdWatch.SOURCE_PLAYBACK && it.id == "w-local" })
        assertEquals(3, kept.size, "the local viewing, the imported entry for episode 1 and the one for episode 2; BannerTV's own entry is not read back as a second viewing")
    }

    @Test fun aReadThatFailsPartWayKeepsWhatWasReadAndTheNextRunContinues() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        (1..5).forEach { rig.server.log(1399, 1, it, "2026-10-0${it}T20:00:00Z") }
        rig.server.diaryFailsOnPage = 2
        val partial = rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertTrue(partial.partial); assertTrue(partial.message!!.startsWith("Stopped early")); assertEquals(2, partial.newEpisodes)
        rig.server.diaryFailsOnPage = null
        val rest = rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertFalse(rest.partial); assertEquals(3, rest.newEpisodes)
        assertEquals(setOf(1, 2, 3, 4, 5), rig.applied.map { it.episodeNumber }.toSet())
    }

    @Test fun anImportThatCouldNotBeAppliedIsNotRememberedAsDone() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.log(1399, 1, 1, "2026-10-01T20:00:00Z")
        rig.sinkFails = true
        val failed = rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertTrue(failed.partial); assertEquals(0, failed.newEpisodes); assertFalse(rig.manager.engine.isMarkerKnown("alice", SerializdTarget(1399, 1, 1)))
        rig.sinkFails = false
        assertEquals(1, rig.manager.importHistory(1, includeWatchedSeasons = false).newEpisodes)
    }

    @Test fun anEntryWithNoDateIsWatchedWithAnUnknownDateNotAnInventedOne() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.log(1399, 1, 4, null, dateAdded = "")
        rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertNull(rig.applied.single().watchedAtMs)
        assertTrue(rig.manager.engine.watches.value.single().undated)
    }

    @Test fun anEntryWhoseSeasonCannotBeToldIsNotGuessedAt() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.diary.add(0, FakeSerializdServer.Entry(900, 1399, 424242, 3, 0, "", false, "2026-10-01T20:00:00Z", true, false, false, "2026-10-01T20:00:00Z"))
        val r = rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertEquals(1, r.unmatched); assertTrue(rig.applied.isEmpty())
    }

    @Test fun ratingsReadFromSerializdAreRememberedAndNotSentBack() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.log(1399, 1, 1, "2026-10-01T20:00:00Z", rating = 8)
        rig.manager.importHistory(1, includeWatchedSeasons = false)
        val t = SerializdTarget(1399, 1, 1)
        assertEquals(4.0, rig.manager.engine.knownRating("alice", t))
        rig.manager.engine.setRating(1, t, "GoT", 4.0); rig.clock += 11_000; rig.manager.engine.processPending()
        assertTrue(rig.writes.isEmpty())
    }

    @Test fun editingAnImportedEntryUsesItsOwnIdNotANewEntry() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        val entry = rig.server.log(1399, 1, 1, "2026-10-01T20:00:00Z", rating = 8)
        rig.manager.importHistory(1, includeWatchedSeasons = false)
        rig.manager.engine.setRating(1, SerializdTarget(1399, 1, 1), "GoT", 5.0); rig.clock += 11_000; rig.manager.engine.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(10, entry.rating)
        val update = rig.server.posts("/show/reviews/update").single()
        assertEquals(entry.id.toString(), rig.server.bodyOf(update)["review_id"]!!.toString())
        assertTrue(rig.server.posts("/show/reviews/add").isEmpty())
    }

    @Test fun seasonsMarkedWatchedBecomeWatchedWithUnknownDatesAndSpecialsAreLeftOut() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.log(1399, 1, 2, "2026-10-02T20:00:00Z")
        rig.server.watchedShows += 1399 to listOf(3624, 3625, 3627)
        val r = rig.manager.importHistory(1, includeWatchedSeasons = true)
        assertEquals(20, r.newEpisodes); assertEquals(20, rig.applied.size)
        assertTrue(rig.applied.none { it.seasonNumber == 0 })
        assertEquals(SerializdDates.parse("2026-10-02T20:00:00Z")!!.ms, rig.applied.single { it.seasonNumber == 1 && it.episodeNumber == 2 }.watchedAtMs)
        assertTrue(rig.applied.filter { !(it.seasonNumber == 1 && it.episodeNumber == 2) }.all { it.watchedAtMs == null })
        assertEquals(1, rig.applied.count { it.seasonNumber == 1 && it.episodeNumber == 2 }, "a dated episode is not also added undated")
    }

    @Test fun aWatchedSeasonSerializdNoLongerListsIsReportedNotSilentlyDropped() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        // The member's record points at season ids Serializd has since replaced (what a renumbered show looks like). One season resolves,
        // one id does not, and the show has two more numbered seasons: which of them was meant cannot be told, so nothing is guessed.
        rig.server.watchedShows += 1399 to listOf(3624, 13775)
        val r = rig.manager.importHistory(1, includeWatchedSeasons = true)
        assertEquals(10, r.newEpisodes, "the season that does resolve is imported")
        assertEquals(1, r.unmatched); assertEquals(listOf("Game of Thrones (1 season)"), r.notMatched); assertTrue(r.placedByCount.isEmpty())
        assertTrue(rig.manager.accountsFlow.value[1]!!.lastImportSummary!!.contains("Not matched: Game of Thrones (1 season)"))
        assertTrue(rig.applied.all { it.seasonNumber == 1 }, "nothing was guessed for the season that could not be placed")
    }

    @Test fun seasonsWhoseIdsWereReCreatedArePlacedByCountWhenTheCountLeavesNoChoice() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        // Three stale ids and three numbered seasons (the show also has specials, which are not among the marks): every season was marked.
        rig.server.watchedShows += 1399 to listOf(13775, 13776, 13777)
        val r = rig.manager.importHistory(1, includeWatchedSeasons = true)
        assertEquals(30, r.newEpisodes); assertEquals(0, r.unmatched); assertTrue(r.notMatched.isEmpty())
        assertEquals(listOf("Game of Thrones (3 seasons)"), r.placedByCount)
        assertEquals(setOf(1, 2, 3), rig.applied.map { it.seasonNumber }.toSet()); assertTrue(rig.applied.none { it.seasonNumber == 0 })
        val summary = rig.manager.accountsFlow.value[1]!!.lastImportSummary!!
        assertTrue(summary.contains("Placed by season count") && summary.contains("Game of Thrones (3 seasons)"), "the member is told, not left to find out")
        assertTrue(!summary.contains("Not matched:"))
        // A second run adds nothing new: the placed episodes are remembered like any other import.
        val again = rig.manager.importHistory(1, includeWatchedSeasons = true)
        assertEquals(0, again.newEpisodes)
    }

    @Test fun staleIdsAlongsideResolvedOnesFillTheRemainingSeasons() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.watchedShows += 1399 to listOf(3624, 13775, 13776) // season 1 by id, the other two numbered seasons by count
        val r = rig.manager.importHistory(1, includeWatchedSeasons = true)
        assertEquals(30, r.newEpisodes); assertEquals(0, r.unmatched); assertEquals(listOf("Game of Thrones (2 seasons)"), r.placedByCount)
    }

    @Test fun staleIdsThatCoverEverySeasonIncludingSpecialsStillPlaceTheNumberedOnes() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.watchedShows += 1399 to listOf(13774, 13775, 13776, 13777) // four ids for four seasons: specials among them
        val r = rig.manager.importHistory(1, includeWatchedSeasons = true)
        assertEquals(30, r.newEpisodes); assertEquals(0, r.unmatched)
        assertTrue(rig.applied.none { it.seasonNumber == 0 }, "specials are never imported, as for any other show")
    }

    @Test fun moreStaleIdsThanSeasonsAreNotGuessedAt() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.watchedShows += 1399 to listOf(13770, 13771, 13772, 13773, 13774) // five ids, only four seasons exist: the shapes do not line up
        val r = rig.manager.importHistory(1, includeWatchedSeasons = true)
        assertEquals(0, r.newEpisodes); assertEquals(5, r.unmatched); assertEquals(listOf("Game of Thrones (5 seasons)"), r.notMatched); assertTrue(r.placedByCount.isEmpty())
    }

    @Test fun aSeasonStillAiringOnlyCountsWhatHasAired() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.shows[8000] = FakeSerializdServer.Show(8000, "Airing", listOf(FakeSerializdServer.Season(1, 8001, 6, listOf("2023-10-01", "2023-10-08", "2023-11-14", "2099-01-01", "2099-01-08", "2099-01-15"))), inProduction = true)
        rig.server.watchedShows += 8000 to listOf(8001)
        rig.manager.importHistory(1, includeWatchedSeasons = true)
        assertEquals(listOf(1, 2, 3), rig.applied.filter { it.showTmdbId == 8000 }.map { it.episodeNumber }.sorted())
    }

    @Test fun theWatchedHistoryImportCanBeSwitchedOff() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.watchedShows += 1399 to listOf(3624)
        rig.manager.updateSettings(1) { it.copy(importWatchedHistory = false) }
        rig.manager.importHistory(1)
        assertTrue(rig.applied.isEmpty())
    }

    @Test fun historyIsReadAgainWhenTheAppReturnsOnlyOnceItHasGoneStale() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        rig.server.log(1399, 1, 7, "2026-10-07T20:00:00Z")
        rig.manager.refreshIfStale(1); advanceUntilIdle()
        assertTrue(rig.applied.isEmpty(), "read a moment ago: left alone")
        rig.clock += 13 * 3_600_000L
        val reads = rig.server.requests.count { it.path.endsWith("/diary") }
        rig.manager.refreshIfStale(1); advanceUntilIdle()
        assertEquals(listOf(7), rig.applied.map { it.episodeNumber }); assertTrue(rig.server.requests.count { it.path.endsWith("/diary") } > reads)
        val afterRefresh = rig.server.requests.size
        rig.manager.refreshIfStale(1); advanceUntilIdle()
        assertEquals(afterRefresh, rig.server.requests.size, "and not again straight away"); assertTrue(rig.writes.isEmpty())
    }

    @Test fun nothingIsReadForAProfileThatIsNotConnected() = runTest {
        val rig = ManagerRig(this)
        rig.manager.refreshIfStale(1); advanceUntilIdle()
        assertTrue(rig.server.requests.isEmpty())
    }

    @Test fun anImportIsRefusedWhileAnotherRunsAndWithoutAnAccount() = runTest {
        val rig = ManagerRig(this)
        assertEquals("No Serializd account is connected", rig.manager.importHistory(1).message)
    }

    @Test fun aDiaryThatComesUpShortOfItsDeclaredSizeIsReportedAsNotFinished() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear()
        (1..3).forEach { rig.server.log(1399, 1, it, "2026-10-0${it}T20:00:00Z") }
        rig.server.declaredDiaryEntries = 10
        val r = rig.manager.importHistory(1, includeWatchedSeasons = false)
        assertTrue(r.partial); assertEquals(3, r.newEpisodes); assertTrue(r.message!!.contains("lists 10 diary entries but only 3"))
        rig.server.declaredDiaryEntries = null
        assertFalse(rig.manager.importHistory(1, includeWatchedSeasons = false).partial)
    }
}

class SerializdManagerWatchlistTest {
    @Test fun aCompleteReadIsKeptWithSeasonNumbersAndNothingIsWrittenBack() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchlist += listOf(1399 to listOf(3624, 3626), 5555 to emptyList(), 9999 to listOf(1))
        assertEquals(3, rig.manager.refreshWatchlist(1))
        val entries = rig.manager.watchlistFlow.value[1]!!.entries
        assertEquals(listOf(1, 3), entries.first { it.showTmdbId == 1399 }.seasonNumbers)
        assertTrue(entries.first { it.showTmdbId == 9999 }.seasonNumbers.isEmpty(), "a show Serializd does not know keeps its entry")
        assertEquals(rig.clock, rig.manager.watchlistFlow.value[1]!!.completeAtMs); assertTrue(rig.writes.isEmpty())
    }

    @Test fun aReadThatFailsHalfwayLeavesTheLastCompleteSnapshotUntouched() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchlist += listOf(1399 to listOf(3624), 1399 + 1 to emptyList(), 1399 + 2 to emptyList())
        assertEquals(3, rig.manager.refreshWatchlist(1))
        val before = rig.manager.watchlistFlow.value[1]
        rig.server.watchlistFailsOnPage = 2
        assertNull(rig.manager.refreshWatchlist(1))
        assertEquals(before, rig.manager.watchlistFlow.value[1])
        assertTrue(rig.manager.engine.events.value.any { it.note?.contains("last one was kept") == true })
    }

    @Test fun aPageThatOnlyRepeatsEarlierOnesIsNotTakenForTheEnd() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchlist += listOf(1399 to listOf(3624), 1399 + 1 to emptyList(), 1399 + 2 to emptyList())
        assertEquals(3, rig.manager.refreshWatchlist(1)); val before = rig.manager.watchlistFlow.value[1]
        rig.server.watchlistRepeatsPage2 = true
        assertNull(rig.manager.refreshWatchlist(1)); assertEquals(before, rig.manager.watchlistFlow.value[1])
    }

    @Test fun aCompleteWatchlistGoesToMyListAsShows() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.myList.clear()
        rig.server.watchlist += listOf(1399 to listOf(3624), 5555 to emptyList(), 9999 to listOf(1))
        assertEquals(3, rig.manager.refreshWatchlist(1))
        val titles = rig.myList.single()
        assertEquals(listOf(1399, 5555, 9999), titles.map { it.tmdbId }); assertTrue(titles.all { it.isSeries })
        assertEquals("Game of Thrones", titles.first().name)
        assertTrue(rig.manager.accountsFlow.value[1]!!.lastWatchlistSummary!!.startsWith("3 added"))
        assertTrue(rig.writes.isEmpty(), "nothing was written to Serializd")
    }

    @Test fun aShortReadNeverReachesMyList() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchlist += listOf(1399 to listOf(3624), 1400 to emptyList(), 1401 to emptyList())
        rig.manager.refreshWatchlist(1); rig.myList.clear()
        rig.server.declaredWatchlistShows = 9
        assertNull(rig.manager.refreshWatchlist(1)); assertTrue(rig.myList.isEmpty())
        rig.server.watchlistFailsOnPage = 2; rig.server.declaredWatchlistShows = null
        assertNull(rig.manager.refreshWatchlist(1)); assertTrue(rig.myList.isEmpty())
    }

    @Test fun theSettingKeepsTheWatchlistOutOfMyListAndSwitchingItOnUsesTheSavedCopy() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.myList.clear()
        rig.manager.updateSettings(1) { it.copy(watchlistToLibrary = false) }
        rig.server.watchlist += 1399 to listOf(3624)
        assertEquals(1, rig.manager.refreshWatchlist(1)); assertTrue(rig.myList.isEmpty())
        val requests = rig.server.requests.size
        rig.manager.updateSettings(1) { it.copy(watchlistToLibrary = true) }
        assertNotNull(rig.manager.addSavedWatchlistToMyList(1)); assertEquals(1, rig.myList.size); assertEquals(requests, rig.server.requests.size)
    }

    @Test fun aFailureAddingToMyListDoesNotCostTheCopyThatWasRead() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.myListFails = true; rig.server.watchlist += 1399 to listOf(3624)
        assertEquals(1, rig.manager.refreshWatchlist(1))
        assertEquals(1, rig.manager.watchlistFlow.value[1]!!.entries.size)
        assertTrue(rig.manager.accountsFlow.value[1]!!.lastWatchlistSummary!!.startsWith("Could not add the watchlist to My List"))
    }

    @Test fun aWatchlistThatDoesNotAddUpToItsDeclaredSizeIsAShortReadNotASmallerList() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchlist += listOf(1399 to listOf(3624), 1399 + 1 to emptyList(), 1399 + 2 to emptyList())
        assertEquals(3, rig.manager.refreshWatchlist(1)); val before = rig.manager.watchlistFlow.value[1]
        rig.server.declaredWatchlistShows = 5
        assertNull(rig.manager.refreshWatchlist(1)); assertEquals(before, rig.manager.watchlistFlow.value[1])
        rig.server.declaredWatchlistShows = 3
        assertEquals(3, rig.manager.refreshWatchlist(1))
    }

    @Test fun anEmptyWatchlistIsAGenuineCompleteRead() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchlist += 1399 to listOf(3624)
        rig.manager.refreshWatchlist(1)
        rig.server.watchlist.clear()
        assertEquals(0, rig.manager.refreshWatchlist(1)); assertTrue(rig.manager.watchlistFlow.value[1]!!.entries.isEmpty())
    }

    @Test fun theSnapshotSurvivesARestartAndGoesWithADisconnect() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchlist += 1399 to listOf(3624)
        rig.manager.refreshWatchlist(1)
        val reopened = SerializdManager(rig.kv, rig.secrets, rig.server, this, newId = { "r" }, pause = {})
        assertEquals(1, reopened.watchlistFlow.value[1]!!.entries.size)
        reopened.disconnect(1, deleteLocalHistory = true)
        assertNull(reopened.watchlistFlow.value[1])
    }
}

class SerializdSettingsScreenFlowTest {
    private val utc = SerializdClock { 0L }

    @Test fun theScreenStateFollowsTheAccountAndItsSettings() = runTest {
        val rig = ManagerRig(this)
        assertNull(rig.manager.screenFlow(1, utc).first().username, "nothing is shown as connected before sign-in")
        rig.connectAlice(); advanceUntilIdle()
        val connected = rig.manager.screenFlow(1, utc).first()
        assertEquals("alice", connected.username); assertEquals("Connected to Serializd", connected.connectionLabel)
        assertTrue(connected.trackEpisodes && connected.syncRatings && connected.syncWatchlist, "the defaults are all on")
        rig.manager.updateSettings(1) { it.copy(autoTrackEpisodes = false) }
        val off = rig.manager.screenFlow(1, utc).first()
        assertFalse(off.trackEpisodes)
        assertTrue(off.settings.createDiaryEntries && off.settings.logRewatches, "turning tracking off keeps the advanced choices")
    }

    @Test fun trackedEpisodesAreCountedFromWhatIsKnownOnSerializd() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchedShows += 1399 to listOf(3624, 3625)
        rig.manager.importHistory(1, includeWatchedSeasons = true)
        val s = rig.manager.screenFlow(1, utc).first()
        assertEquals("20 episodes tracked", s.watchHistoryLine)
        assertEquals("20 episodes imported successfully.", s.importLine); assertEquals(20, s.importStats!!.added)
    }

    @Test fun theLastImportsNumbersAreKeptForTheDetailsView() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchedShows += 1399 to listOf(3624, 13775) // one season by id, one stale id the count cannot settle
        rig.manager.importHistory(1, includeWatchedSeasons = true)
        val stats = rig.manager.accountsFlow.value[1]!!.lastImportStats!!
        assertEquals(10, stats.added); assertEquals(1, stats.unmatched); assertEquals(listOf("Game of Thrones (1 season)"), stats.notMatched); assertEquals(1, stats.watchedShows)
        assertEquals("10 episodes imported successfully. 1 couldn't be matched.", rig.manager.screenFlow(1, utc).first().importLine)
    }

    @Test fun theSingleWatchlistSwitchTurnsReadingAndAddingOnAndOffTogether() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.server.watchlist += 1399 to listOf(3624)
        rig.manager.setSyncWatchlist(1, false)
        val off = rig.manager.settingsFlow.value[1]!!
        assertFalse(off.importWatchlist); assertFalse(off.watchlistToLibrary); assertFalse(rig.manager.screenFlow(1, utc).first().syncWatchlist)
        rig.myList.clear()
        val note = rig.manager.setSyncWatchlist(1, true)
        val on = rig.manager.settingsFlow.value[1]!!
        assertTrue(on.importWatchlist && on.watchlistToLibrary); assertNotNull(note)
        assertEquals(1, rig.myList.sumOf { it.size }, "turning it on puts the watchlist in My List")
    }

    @Test fun turningTheWatchlistSwitchOffRemovesNothingAndTouchesNoOtherPreference() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        rig.manager.updateSettings(1) { it.copy(syncFavorites = true, completionThreshold = 0.95, createDiaryEntries = false) }
        rig.myList.clear()
        rig.manager.setSyncWatchlist(1, false)
        val s = rig.manager.settingsFlow.value[1]!!
        assertTrue(s.syncFavorites && !s.createDiaryEntries); assertEquals(0.95, s.completionThreshold)
        assertTrue(rig.myList.isEmpty(), "nothing is sent to My List, and nothing is removed from it")
    }

    @Test fun aNewAccountWaitsForTheSetupChoiceBeforeAnythingIsRead() = runTest {
        val rig = ManagerRig(this)
        rig.server.watchedShows += 1399 to listOf(3624)
        rig.manager.connect(1, "a@example.com", SECRET_PASSWORD, guidedSetup = true); advanceUntilIdle()
        assertTrue(rig.manager.accountsFlow.value[1]!!.setupPending)
        assertTrue(rig.applied.isEmpty(), "no first import before the member has chosen")
        assertTrue(rig.server.requests.none { it.path.contains("watchedpage_v2") || it.path.contains("diary") })
        rig.manager.refreshIfStale(1); advanceUntilIdle()
        assertTrue(rig.applied.isEmpty(), "a foreground refresh does not read either while the setup step is open")
        assertTrue(rig.manager.screenFlow(1, utc).first().setupPending)
    }

    @Test fun recommendedSettingsSwitchTheMainFeaturesOnAndReadSerializdButNeverSendHistory() = runTest {
        val rig = ManagerRig(this)
        rig.server.watchedShows += 1399 to listOf(3624)
        rig.server.watchlist += 1399 to listOf(3624)
        rig.manager.connect(1, "a@example.com", SECRET_PASSWORD, guidedSetup = true); advanceUntilIdle()
        rig.manager.updateSettings(1) { it.copy(autoTrackEpisodes = false, syncRatings = false, createDiaryEntries = false, syncFavorites = true) }
        rig.manager.completeSetup(1, recommended = true)
        val s = rig.manager.settingsFlow.value[1]!!
        assertTrue(s.autoTrackEpisodes && s.syncRatings && s.importWatchedHistory && s.importWatchlist && s.watchlistToLibrary)
        assertFalse(s.createDiaryEntries, "the diary choice is not forced"); assertTrue(s.syncFavorites)
        assertFalse(rig.manager.accountsFlow.value[1]!!.setupPending)
        assertEquals(10, rig.applied.size, "the existing Serializd history was read")
        assertEquals(1, rig.myList.sumOf { it.size }, "and the watchlist went to My List")
        assertTrue(rig.writes.isEmpty(), "nothing was written to Serializd")
    }

    @Test fun customizeEndsTheStepWithoutChangingOrReadingAnything() = runTest {
        val rig = ManagerRig(this)
        rig.manager.connect(1, "a@example.com", SECRET_PASSWORD, guidedSetup = true); advanceUntilIdle()
        val before = rig.manager.settingsFlow.value[1] ?: SerializdSettings()
        rig.manager.completeSetup(1, recommended = false)
        assertFalse(rig.manager.accountsFlow.value[1]!!.setupPending)
        assertEquals(before, rig.manager.settingsFlow.value[1] ?: SerializdSettings()); assertTrue(rig.applied.isEmpty())
        rig.manager.completeSetup(1, recommended = true) // the step is already over: a second call changes nothing
        assertTrue(rig.applied.isEmpty())
    }

    @Test fun anAccountThatConnectedEarlierNeverGetsTheSetupStep() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        assertFalse(rig.manager.accountsFlow.value[1]!!.setupPending)
        rig.manager.connect(1, "a@example.com", SECRET_PASSWORD, guidedSetup = true) // a reconnect, even through the guided path
        assertFalse(rig.manager.accountsFlow.value[1]!!.setupPending)
    }

    @Test fun repeatedSyncNowTapsRunOneSyncAtATime() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle()
        val gate = CompletableDeferred<Unit>()
        rig.server.requests.clear()
        rig.server.beforeReply = { if (it.path == "/validateauthtoken") gate.await() }
        val first = launch(Dispatchers.Default) { rig.manager.syncNowAndWait(1) }
        withContext(Dispatchers.Default) { withTimeout(5_000) { while (rig.server.requests.none { it.path == "/validateauthtoken" }) delay(10) } }
        assertTrue(rig.manager.screenFlow(1, utc).first().busy, "the screen shows the sync as running")
        rig.manager.syncNowAndWait(1) // taps arriving meanwhile start nothing
        rig.manager.syncNowAndWait(1)
        assertEquals(1, rig.server.requests.count { it.path == "/validateauthtoken" })
        gate.complete(Unit); first.join()
        assertFalse(rig.manager.screenFlow(1, utc).first().busy)
        rig.server.beforeReply = null
        rig.manager.syncNowAndWait(1)
        assertEquals(2, rig.server.requests.count { it.path == "/validateauthtoken" }, "a later sync runs normally")
    }

    @Test fun importFromSerializdReadsHistoryAndTheWatchlistAndAnswersInOneSentence() = runTest {
        val rig = ManagerRig(this); rig.connectAlice(); advanceUntilIdle(); rig.applied.clear(); rig.myList.clear()
        rig.server.watchedShows += 1399 to listOf(3624)
        rig.server.watchlist += 1399 to listOf(3624)
        assertEquals("10 episodes imported successfully.", rig.manager.importFromSerializd(1))
        assertEquals(1, rig.myList.sumOf { it.size })
        assertEquals("Nothing new to import. Everything is already here.", rig.manager.importFromSerializd(1))
    }
}
