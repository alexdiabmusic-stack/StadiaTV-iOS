package com.nuvio.app.features.serializd

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 2023-11-14T22:13:20Z. */
private const val T0 = 1_700_000_000_000L
private const val MIN = 60_000L
private const val ISO0 = "2023-11-14T22:13:20Z"

internal class Rig(val server: FakeSerializdServer = FakeSerializdServer(), account: String? = "alice") : SerializdEngineHost {
    var clock = T0
    val kv = MemorySerializdKv()
    var account: String? = account
    var settings = SerializdSettings()
    val states = mutableListOf<SerializdConnectionState>()
    var lengths: Map<Int, Map<Int, Int>> = emptyMap()
    var hasService = true
    private var ids = 0
    private val api = SerializdApi(SerializdSession(SerializdSessionMaterial("a@example.com", "pw", null, null), server, pause = {}, jitter = { 0 }))
    private val service = SerializdService(api, SerializdSeasonResolver(api, kv, { clock }))

    override fun accountOf(profileId: Int) = if (profileId == 1) account else null
    override fun settingsOf(profileId: Int) = settings
    override fun serviceOf(profileId: Int) = if (hasService) service else null
    override fun onConnectionState(profileId: Int, state: SerializdConnectionState) { states += state }
    override suspend fun seasonLengths(showTmdbId: Int): Map<Int, Int> = lengths[showTmdbId].orEmpty()

    fun engine() = SerializdSyncEngine(kv, this, now = { clock }, newId = { "id${ids++}" })

    fun done(session: String = "s1", show: Int = 1399, season: Int = 1, episodes: List<Int> = listOf(1), at: Long = clock) =
        SerializdCompletion(session, 1, show, season, episodes, "Game of Thrones", "Winter Is Coming", at, 1.0)

    val got1 get() = SerializdTarget(1399, 1, 1)
}

private fun SerializdSyncEngine.ops(type: SerializdOperationType) = operations.value.filter { it.type == type }
private fun SerializdSyncEngine.op(type: SerializdOperationType) = ops(type).single()

class SerializdEngineCompletionTest {
    @Test fun aFinishedEpisodeMarksWatchedAndMakesADatedEntryWithTheRealTime() = runTest {
        val rig = Rig(); val e = rig.engine()
        val watch = e.onCompletion(rig.done(), "poster", false)!!
        assertFalse(watch.rewatch)
        e.processPending()
        assertEquals(setOf(Triple(1399, 3624, 1)), rig.server.markers)
        val entry = rig.server.diary.single()
        assertEquals(ISO0, entry.backdate); assertEquals(3624, entry.seasonId); assertEquals(1, entry.episodeNumber)
        assertTrue(entry.isLog); assertFalse(entry.isRewatch); assertEquals(0, entry.rating); assertEquals("", entry.text)
        val saved = e.watches.value.single()
        assertTrue(saved.markedWatched); assertTrue(saved.onDiary); assertEquals(entry.id, saved.remoteReviewId)
        assertTrue(e.operations.value.all { it.status == SerializdOperationStatus.Synced })
    }

    @Test fun theDiaryDateIsWhenPlaybackFinishedNotWhenTheRetryRan() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.Offline
        e.onCompletion(rig.done(), null, false)
        e.processPending()
        rig.clock += 3 * 3_600_000L // three hours later, back online
        e.processPending()
        assertEquals(ISO0, rig.server.diary.single().backdate)
    }

    @Test fun theSameFinishReportedTwiceIsOneViewing() = runTest {
        val rig = Rig(); val e = rig.engine()
        val a = e.onCompletion(rig.done("s1"), null, false)!!
        val b = e.onCompletion(rig.done("s1"), null, false)!!
        assertEquals(a.id, b.id); assertEquals(2, e.operations.value.size)
        e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(1, rig.server.posts("/episode_log/add").size)
    }

    @Test fun aSecondFinishSecondsLaterFromAnotherSessionIsNotARewatch() = runTest {
        val rig = Rig(); val e = rig.engine()
        val a = e.onCompletion(rig.done("s1"), null, false)!!
        rig.clock += 3_000
        val b = e.onCompletion(rig.done("s2"), null, false)!!
        assertEquals(a.id, b.id); assertEquals(1, e.watches.value.size); assertEquals(2, e.operations.value.size)
        e.processPending()
        assertEquals(1, rig.server.diary.size); assertFalse(rig.server.diary.single().isRewatch)
        assertTrue(e.events.value.any { it.status == SerializdOperationStatus.Skipped && it.note!!.contains("repeated finish") })
    }

    @Test fun theSuppressionWindowEndsAfterFiveMinutes() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done("s1"), null, false)
        rig.clock += 4 * MIN + 59_000
        e.onCompletion(rig.done("s2"), null, false)
        assertEquals(1, e.watches.value.size, "4 minutes 59 seconds later is still the same finish")
        rig.clock += 2_000
        e.onCompletion(rig.done("s3"), null, false)
        assertEquals(2, e.watches.value.size); assertTrue(e.watches.value.last().rewatch)
    }

    @Test fun aGenuineLaterViewingIsLoggedAsARewatchWithoutMarkingWatchedAgain() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done("s1"), null, false); e.processPending()
        rig.clock += 2 * 3_600_000L
        val again = e.onCompletion(rig.done("s2"), null, false)!!
        assertTrue(again.rewatch)
        e.processPending()
        assertEquals(2, rig.server.diary.size)
        assertTrue(rig.server.diary.first().isRewatch); assertFalse(rig.server.diary.last().isRewatch)
        assertEquals(1, rig.server.posts("/episode_log/add").size, "the episode was already marked")
    }

    @Test fun aViewingIsNeverBlockedForeverBecauseTheEpisodeWasWatchedBefore() = runTest {
        val rig = Rig(); val e = rig.engine()
        repeat(4) { i -> e.onCompletion(rig.done("s$i"), null, false); rig.clock += 24 * 3_600_000L }
        e.processPending()
        assertEquals(4, rig.server.diary.size); assertEquals(3, rig.server.diary.count { it.isRewatch })
    }

    @Test fun rewatchLoggingCanBeSwitchedOffAndTheViewingIsStillKept() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.settings = SerializdSettings(logRewatches = false)
        e.onCompletion(rig.done("s1"), null, false); e.processPending()
        rig.clock += 3_600_000L
        e.onCompletion(rig.done("s2"), null, false); e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(2, e.watches.value.size)
        assertTrue(e.events.value.any { it.note == "Rewatch logging is off" })
    }

    @Test fun trackingOffKeepsTheViewingAndSendsNothing() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.settings = SerializdSettings(autoTrackEpisodes = false)
        assertNotNull(e.onCompletion(rig.done(), null, false)); e.processPending()
        assertTrue(e.operations.value.isEmpty()); assertTrue(rig.server.requests.isEmpty())
    }

    @Test fun diaryEntriesCanBeOffWhileTheWatchedMarkerStillGoes() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.settings = SerializdSettings(createDiaryEntries = false)
        e.onCompletion(rig.done(), null, false); e.processPending()
        assertEquals(1, rig.server.markers.size); assertTrue(rig.server.diary.isEmpty())
    }

    @Test fun noAccountMeansNothingIsRecordedOrSent() = runTest {
        val rig = Rig(account = null); val e = rig.engine()
        assertNull(e.onCompletion(rig.done(), null, false)); assertTrue(e.watches.value.isEmpty()); assertTrue(rig.server.requests.isEmpty())
    }

    @Test fun aFileWithTwoEpisodesIsOneMarkerRequestAndTwoDatedEntries() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(episodes = listOf(3, 4)), null, false); e.processPending()
        val marker = rig.server.posts("/episode_log/add").single()
        assertEquals(listOf("3", "4"), rig.server.bodyOf(marker)["episode_numbers"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals(listOf(3, 4), rig.server.diary.mapNotNull { it.episodeNumber }.sorted())
        assertEquals(2, e.watches.value.size)
    }

    @Test fun specialsAreLoggedToSeasonZero() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(season = 0, episodes = listOf(2)), null, false); e.processPending()
        assertEquals(3627, rig.server.diary.single().seasonId); assertTrue(Triple(1399, 3627, 2) in rig.server.markers)
    }

    @Test fun aMergedSeasonIsPlacedAfterTheEarlierOnesOnBothRequests() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.shows[5000] = FakeSerializdServer.Show(5000, "Merged", listOf(FakeSerializdServer.Season(1, 9001, 24)))
        rig.lengths = mapOf(5000 to mapOf(1 to 12, 2 to 12))
        e.onCompletion(rig.done(show = 5000, season = 2, episodes = listOf(3)), null, false); e.processPending()
        assertEquals(setOf(Triple(5000, 9001, 15)), rig.server.markers)
        assertEquals(15, rig.server.diary.single().episodeNumber); assertEquals(9001, rig.server.diary.single().seasonId)
    }

    @Test fun anUncertainMergeLogsNothing() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.shows[5000] = FakeSerializdServer.Show(5000, "Merged", listOf(FakeSerializdServer.Season(1, 9001, 24)))
        e.onCompletion(rig.done(show = 5000, season = 2, episodes = listOf(3)), null, false) // no season lengths known
        e.processPending()
        assertTrue(rig.server.markers.isEmpty()); assertTrue(rig.server.diary.isEmpty())
        assertTrue(e.operations.value.all { it.status == SerializdOperationStatus.RetryScheduled && it.error == SerializdErrorCategory.MetadataMissing })
    }

    @Test fun anEpisodePastTheEndOfSerializdsSeasonIsAMismatchAndIsNeverLogged() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(episodes = listOf(11)), null, false); e.processPending()
        assertTrue(rig.server.markers.isEmpty()); assertTrue(rig.server.diary.isEmpty())
        assertTrue(e.operations.value.all { it.status == SerializdOperationStatus.FailedPermanent && it.error == SerializdErrorCategory.MetadataMismatch })
        assertTrue(rig.server.requests.count { it.path == "/show/1399" } >= 2, "looked again before deciding the numbering differs")
    }

    @Test fun aShowSerializdDoesNotHaveYetIsRetriedSlowlyAndThenGivenUp() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(show = 777), null, false); e.processPending()
        val first = e.ops(SerializdOperationType.MarkEpisodeWatched).single()
        assertEquals(SerializdOperationStatus.RetryScheduled, first.status); assertEquals(SerializdErrorCategory.MetadataMissing, first.error)
        assertEquals(rig.clock + 10 * MIN, first.nextAttemptAtMs)
        repeat(6) { rig.clock += 5 * 3_600_000L; e.processPending() }
        assertTrue(e.operations.value.all { it.status == SerializdOperationStatus.FailedPermanent && it.error == SerializdErrorCategory.MetadataMissing })
        assertTrue(rig.server.markers.isEmpty() && rig.server.diary.isEmpty())
    }

    @Test fun aSeasonSerializdLacksIsRetriedLater() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(season = 9), null, false); e.processPending()
        assertTrue(e.operations.value.all { it.status == SerializdOperationStatus.RetryScheduled })
        rig.server.shows[1399] = FakeSerializdServer.Show(1399, "GoT", rig.server.shows.getValue(1399).seasons + FakeSerializdServer.Season(9, 4000, 10))
        rig.clock += 61 * MIN // past the retry time and the map's refresh pause
        e.processPending()
        assertEquals(setOf(Triple(1399, 4000, 1)), rig.server.markers); assertEquals(1, rig.server.diary.size)
    }
}

class SerializdEngineReliabilityTest {
    @Test fun whenTheDiaryFailsTheWatchedMarkerIsNotSentAgain() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.Offline
        e.onCompletion(rig.done(), null, false); e.processPending()
        assertEquals(SerializdOperationStatus.Synced, e.op(SerializdOperationType.MarkEpisodeWatched).status)
        assertEquals(SerializdOperationStatus.RetryScheduled, e.op(SerializdOperationType.CreateDiaryEntry).status)
        rig.clock += 31_000; e.processPending()
        assertEquals(1, rig.server.posts("/episode_log/add").size); assertEquals(1, rig.server.diary.size)
    }

    @Test fun aSyncedDiaryEntryIsNeverResentBecauseALaterStepFailed() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        e.setRating(1, rig.got1, "GoT", 4.0)
        rig.server.addScript += FakeSerializdServer.Write.Offline
        rig.clock += 11_000; e.processPending() // the rating fails
        rig.clock += 31_000; e.processPending()
        assertEquals(1, rig.server.posts("/show/reviews/add").size); assertEquals(1, rig.server.diary.size)
    }

    @Test fun aWriteThatLandedWithALostReplyIsFoundOnTheDiaryAndNeverDuplicated() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.LandedReplyLost
        e.onCompletion(rig.done(), null, false); e.processPending()
        val op = e.op(SerializdOperationType.CreateDiaryEntry)
        assertEquals(SerializdOperationStatus.ReconciliationRequired, op.status); assertTrue(op.reconciling); assertEquals(SerializdErrorCategory.Ambiguous, op.error)
        assertEquals(1, rig.server.diary.size)
        rig.clock += 3 * MIN; e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(1, rig.server.posts("/show/reviews/add").size)
        assertEquals(SerializdOperationStatus.Synced, e.op(SerializdOperationType.CreateDiaryEntry).status)
        assertTrue(e.watches.value.single().onDiary); assertEquals(rig.server.diary.single().id, e.watches.value.single().remoteReviewId)
    }

    @Test fun aWriteLostBeforeLandingIsWaitedOnAndSentAgainOnlyIfItIsNotThere() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.LostBeforeLanding
        e.onCompletion(rig.done(), null, false); e.processPending()
        rig.clock += 3 * MIN; e.processPending()
        assertEquals(1, rig.server.posts("/show/reviews/add").size, "not resent while it might still land")
        assertEquals(SerializdOperationStatus.ReconciliationRequired, e.op(SerializdOperationType.CreateDiaryEntry).status)
        rig.clock += 8 * MIN; e.processPending()
        assertEquals(2, rig.server.posts("/show/reviews/add").size); assertEquals(1, rig.server.diary.size)
        assertEquals(SerializdOperationStatus.Synced, e.op(SerializdOperationType.CreateDiaryEntry).status)
    }

    @Test fun aServerErrorAfterTheEntryLandedIsReconciledNotDuplicated() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.ServerErrorLanded
        e.onCompletion(rig.done(), null, false); e.processPending()
        assertTrue(e.op(SerializdOperationType.CreateDiaryEntry).reconciling)
        rig.clock += 31_000; e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(1, rig.server.posts("/show/reviews/add").size)
    }

    @Test fun aServerErrorThatDidNotLandIsSentAgainOnlyAfterTheDiaryIsChecked() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.Status(503)
        e.onCompletion(rig.done(), null, false); e.processPending()
        assertTrue(rig.server.diary.isEmpty())
        rig.clock += 31_000; e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(2, rig.server.posts("/show/reviews/add").size)
        assertTrue(rig.server.requests.indexOfFirst { it.path.endsWith("/diary") } in 0 until rig.server.requests.indexOfLast { it.path == "/show/reviews/add" })
    }

    @Test fun aDiaryThatCannotBeReadIsNeverTakenForEmpty() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.ServerErrorLanded
        e.onCompletion(rig.done(), null, false); e.processPending()
        rig.server.diaryFailsOnPage = 1
        rig.clock += 31_000; e.processPending()
        assertEquals(1, rig.server.posts("/show/reviews/add").size, "nothing was sent while the diary could not be read")
        rig.server.diaryFailsOnPage = null; rig.clock += 10 * MIN; e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(1, rig.server.posts("/show/reviews/add").size)
    }

    @Test fun aRefusedWriteStopsAndTheMemberCanRetryIt() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.Status(400)
        e.onCompletion(rig.done(), null, false); e.processPending()
        val op = e.op(SerializdOperationType.CreateDiaryEntry)
        assertEquals(SerializdOperationStatus.FailedPermanent, op.status); assertEquals(SerializdErrorCategory.Rejected, op.error)
        rig.clock += 24 * 3_600_000L; e.processPending(); assertEquals(1, rig.server.posts("/show/reviews/add").size)
        e.retry(op.id); e.processPending()
        assertEquals(1, rig.server.diary.size)
    }

    @Test fun theQueueAndTheViewingsSurviveTheAppBeingClosed() = runTest {
        val rig = Rig(); var e = rig.engine()
        e.onCompletion(rig.done(), null, false) // closed before anything was sent
        e = rig.engine()
        assertEquals(1, e.watches.value.size); assertEquals(2, e.operations.value.size)
        e.processPending()
        assertEquals(1, rig.server.diary.size)
    }

    @Test fun aRepeatedFinishAfterARestartIsStillRecognised() = runTest {
        val rig = Rig(); var e = rig.engine()
        e.onCompletion(rig.done("s1"), null, false); e.processPending()
        e = rig.engine(); rig.clock += 20_000
        e.onCompletion(rig.done("s1"), null, false); e.onCompletion(rig.done("s2"), null, false); e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(1, e.watches.value.size)
    }

    @Test fun anInterruptedWriteIsCheckedOnTheDiaryBeforeAnythingIsSentAfterARestart() = runTest {
        val rig = Rig(); var e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.LandedReplyLost
        e.onCompletion(rig.done(), null, false); e.processPending()
        e = rig.engine() // the app was closed before the answer was checked
        rig.clock += 3 * MIN; e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(1, rig.server.posts("/show/reviews/add").size)
    }

    @Test fun anAppKilledMidWriteIsCheckedOnTheDiaryBeforeAnythingIsSent() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        // Rewind to the moment the app was killed: the entry reached Serializd, but the app never heard back and had saved "sending".
        val saved = kotlinx.serialization.json.Json.decodeFromString(kotlinx.serialization.builtins.ListSerializer(SerializdOperation.serializer()), rig.kv.map["serializd_ops_v1"]!!)
        val diary = saved.single { it.type == SerializdOperationType.CreateDiaryEntry }
        val killed = saved.map { if (it.id == diary.id) it.copy(status = SerializdOperationStatus.InProgress, reconciling = true, writeSentAtMs = rig.clock, lastAttemptAtMs = rig.clock) else it }
        rig.kv.map["serializd_ops_v1"] = kotlinx.serialization.json.Json { encodeDefaults = true }.encodeToString(kotlinx.serialization.builtins.ListSerializer(SerializdOperation.serializer()), killed)
        val writesBefore = rig.server.posts("/show/reviews/add").size
        val reopened = rig.engine()
        rig.clock += MIN; reopened.processPending()
        assertEquals(SerializdOperationStatus.InProgress, reopened.op(SerializdOperationType.CreateDiaryEntry).status, "left alone while the first attempt may still be running")
        rig.clock += 6 * MIN; reopened.processPending()
        assertEquals(SerializdOperationStatus.Synced, reopened.op(SerializdOperationType.CreateDiaryEntry).status)
        assertEquals(writesBefore, rig.server.posts("/show/reviews/add").size, "nothing was sent again"); assertEquals(1, rig.server.diary.size)
    }

    @Test fun withoutAUsableSessionTheQueueWaitsForTheMemberToReconnect() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.hasService = false
        e.onCompletion(rig.done(), null, false); e.processPending()
        assertTrue(e.operations.value.all { it.status == SerializdOperationStatus.NeedsReconnect })
        assertTrue(SerializdConnectionState.ReconnectionRequired in rig.states); assertTrue(rig.server.requests.isEmpty())
        rig.hasService = true; e.onReconnected(1); e.processPending()
        assertEquals(1, rig.server.diary.size)
    }

    @Test fun aServiceThatKeepsFailingIsLeftAloneAfterFiveInARow() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.settings = SerializdSettings(createDiaryEntries = false)
        repeat(60) { rig.server.markerScript += FakeSerializdServer.Write.Status(503) }
        (1..7).forEach { n -> e.onCompletion(rig.done("s$n", episodes = listOf(n)), null, false) }
        e.processPending()
        // Each marker request is tried four times by the session; after five whole requests have failed the rest wait.
        assertEquals(5 * SerializdSession.MAX_ATTEMPTS, rig.server.posts("/episode_log/add").size)
        assertEquals(2, e.operations.value.count { it.status == SerializdOperationStatus.Pending })
    }

    @Test fun anImportedViewingMakesALaterPlaybackARewatchAndTheMarkerIsNotSentBack() = runTest {
        val rig = Rig(); val e = rig.engine()
        val imported = SerializdWatch("imp-alice-5", 1, "alice", 1399, "GoT", 1, 1, completedAtMs = T0 - 86_400_000L, source = SerializdWatch.SOURCE_IMPORT, markedWatched = true, onDiary = true)
        e.addImported(1, "alice", listOf(imported), listOf(rig.got1), emptyMap(), emptyMap())
        val w = e.onCompletion(rig.done(), null, false)!!
        assertTrue(w.rewatch)
        e.processPending()
        assertTrue(rig.server.posts("/episode_log/add").isEmpty()); assertTrue(rig.server.diary.single().isRewatch)
    }

    @Test fun disconnectingDropsPendingWorkAndForgetsTheAccount() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false)
        e.onDisconnected(1, "alice", deleteLocal = false)
        assertTrue(e.operations.value.isEmpty()); e.processPending(); assertTrue(rig.server.requests.isEmpty())
        e.onCompletion(rig.done("s9", episodes = listOf(2)), null, false); e.processPending()
        e.onDisconnected(1, "alice", deleteLocal = true)
        assertTrue(e.watches.value.isEmpty()); assertTrue(e.events.value.isEmpty()); assertFalse(e.isMarkerKnown("alice", SerializdTarget(1399, 1, 2)))
    }

    @Test fun anotherAccountsOperationsNeverRunAsThisOne() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false)
        rig.account = "someone-else"
        e.processPending()
        assertTrue(rig.server.requests.isEmpty())
        assertTrue(e.operations.value.all { it.account == "alice" })
    }

    @Test fun backfillSendsMarkersPerSeasonAndDatedEntriesOnlyForRealDates() = runTest {
        val rig = Rig(); val e = rig.engine()
        val eps = listOf(
            SerializdBackfillEpisode(1399, "GoT", 1, 1, T0), SerializdBackfillEpisode(1399, "GoT", 1, 2, null), SerializdBackfillEpisode(1399, "GoT", 1, 3, 1_000L),
        )
        assertEquals(Triple(1, 1, 0), e.enqueueBackfill(1, eps, withDiary = true))
        e.processPending()
        assertEquals(setOf(Triple(1399, 3624, 1), Triple(1399, 3624, 2), Triple(1399, 3624, 3)), rig.server.markers)
        assertEquals(1, rig.server.diary.size); assertEquals(ISO0, rig.server.diary.single().backdate)
        assertTrue(rig.server.ratingsOnly.isEmpty())
        assertEquals(Triple(0, 0, 3), e.enqueueBackfill(1, eps, withDiary = true), "what Serializd already has is not sent again")
    }

    @Test fun backfillWithoutDatedEntriesOnlyMarksWatched() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.enqueueBackfill(1, listOf(SerializdBackfillEpisode(1399, "GoT", 2, 4, T0)), withDiary = false); e.processPending()
        assertEquals(1, rig.server.markers.size); assertTrue(rig.server.diary.isEmpty())
    }

    @Test fun unmarkingRemovesTheMarkerAndLeavesTheDiaryEntry() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        e.unmarkEpisode(1, rig.got1, "GoT"); e.processPending()
        assertTrue(rig.server.markers.isEmpty()); assertEquals(1, rig.server.diary.size)
        assertFalse(e.isMarkerKnown("alice", rig.got1)); assertFalse(e.watches.value.single().markedWatched)
    }

    @Test fun theAuthBreakerOpensAfterThreeAndClosesOnReset() {
        val b = SerializdAuthBreaker()
        assertFalse(b.recordFailure()); assertFalse(b.recordFailure()); assertTrue(b.recordFailure()); assertTrue(b.isOpen)
        b.reset(); assertFalse(b.isOpen)
    }

    @Test fun theLoginLimiterLocksOutRepeatedWrongPasswordsAndGrowsTheWait() {
        var clock = 0L
        val l = SerializdLoginLimiter { clock }
        repeat(2) { l.recordFailure() }; assertEquals(0, l.waitMs())
        l.recordFailure(); assertEquals(30_000L, l.waitMs())
        clock += 30_001; assertEquals(0, l.waitMs())
        l.recordFailure(); assertEquals(60_000L, l.waitMs())
        l.recordSuccess(); assertEquals(0, l.waitMs())
    }
}

class SerializdEngineRatingsTest {
    @Test fun aRatingRidesOnADiaryEntryThatHasNotBeenSentYet() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false)
        e.setRating(1, rig.got1, "GoT", 4.5)
        assertEquals(2, e.operations.value.size)
        e.processPending()
        assertEquals(9, rig.server.diary.single().rating); assertEquals(4.5, e.watches.value.single().stars)
    }

    @Test fun ratingAnEpisodeAlreadyOnTheDiaryEditsThatEntryAndAddsNoSecondOne() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        e.setRating(1, rig.got1, "GoT", 3.5)
        e.processPending() // held for the debounce
        assertEquals(0, rig.server.diary.single().rating)
        rig.clock += 11_000; e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals(7, rig.server.diary.single().rating)
        assertEquals(1, rig.server.posts("/show/reviews/add").size); assertEquals(1, rig.server.posts("/show/reviews/update").size)
        val edit = rig.server.bodyOf(rig.server.posts("/show/reviews/update").single())
        assertEquals("true", edit["is_log"]!!.jsonPrimitive.content); assertEquals(ISO0, edit["backdate"]!!.jsonPrimitive.content)
        assertEquals(3.5, e.knownRating("alice", rig.got1))
    }

    @Test fun quickChangesSendOnlyTheLastRating() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        listOf(2.0, 3.0, 4.0, 5.0).forEach { e.setRating(1, rig.got1, "GoT", it) }
        rig.clock += 11_000; e.processPending()
        assertEquals(1, rig.server.posts("/show/reviews/update").size); assertEquals(10, rig.server.diary.single().rating)
    }

    @Test fun theSameRatingIsNotSentTwice() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        repeat(2) { e.setRating(1, rig.got1, "GoT", 4.0); rig.clock += 11_000; e.processPending() }
        assertEquals(1, rig.server.posts("/show/reviews/update").size)
        assertTrue(e.operations.value.any { it.note?.startsWith("Already") == true })
    }

    @Test fun takingARatingBackOffStaysLocalBecauseItCannotBeVerified() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        e.setRating(1, rig.got1, "GoT", null)
        rig.clock += 11_000; e.processPending()
        assertEquals(0, rig.server.posts("/show/reviews/update").size); assertNull(e.watches.value.single().stars)
    }

    @Test fun ratingsCanBeSwitchedOff() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.settings = SerializdSettings(syncRatings = false)
        e.onCompletion(rig.done(), null, false); e.processPending()
        e.setRating(1, rig.got1, "GoT", 5.0); rig.clock += 11_000; e.processPending()
        assertEquals(0, rig.server.diary.single().rating); assertEquals(5.0, e.watches.value.single().stars, "still kept here")
    }

    @Test fun everyHalfStarReachesSerializdAsItsInteger() = runTest {
        val rig = Rig(); val e = rig.engine()
        for ((i, stars) in SerializdRating.choices.filterNotNull().withIndex()) {
            val target = SerializdTarget(1399, 1, i + 1)
            rig.clock += 6 * MIN
            e.onCompletion(rig.done("s$i", episodes = listOf(i + 1)), null, false); e.setRating(1, target, "GoT", stars); e.processPending()
        }
        assertEquals((1..10).toList(), rig.server.diary.map { it.rating }.sorted())
    }

    @Test fun aSeasonOrShowRatingIsARatingEntryOfItsOwnAndLaterChangesEditIt() = runTest {
        val rig = Rig(); val e = rig.engine()
        val season = SerializdTarget(1399, 1); val show = SerializdTarget(1399)
        e.setRating(1, season, "GoT", 4.0); e.setRating(1, show, "GoT", 4.5)
        rig.clock += 11_000; e.processPending()
        assertTrue(rig.server.diary.isEmpty(), "a rating alone is not a diary entry")
        val byScope = rig.server.ratingsOnly.associateBy { it.seasonId }
        assertEquals(8, byScope[3624]!!.rating); assertNull(byScope[3624]!!.episodeNumber); assertEquals(9, byScope[null]!!.rating)
        assertTrue(rig.server.ratingsOnly.none { it.isLog })
        e.setRating(1, show, "GoT", 5.0); rig.clock += 11_000; e.processPending()
        assertEquals(2, rig.server.ratingsOnly.size); assertEquals(10, rig.server.ratingsOnly.first { it.seasonId == null }.rating)
        assertEquals(1, rig.server.posts("/show/reviews/update").size)
        assertEquals(4.0, e.knownRating("alice", season))
    }

    @Test fun aRatingWithNoViewingOnTheDiaryIsAnEpisodeRatingEntryNotADiaryEntry() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.settings = SerializdSettings(createDiaryEntries = false)
        e.onCompletion(rig.done(), null, false); e.processPending()
        e.setRating(1, rig.got1, "GoT", 4.0); rig.clock += 11_000; e.processPending()
        assertTrue(rig.server.diary.isEmpty()); val entry = rig.server.ratingsOnly.single()
        assertFalse(entry.isLog); assertEquals(1, entry.episodeNumber); assertEquals(3624, entry.seasonId); assertEquals(8, entry.rating)
    }

    @Test fun aRatingEntrySerializdHasButCannotBeEditedHereIsLeftToTheMember() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addReplyHasId = false
        val show = SerializdTarget(1399)
        e.setRating(1, show, "GoT", 3.0); rig.clock += 11_000; e.processPending()
        e.setRating(1, show, "GoT", 4.0); rig.clock += 11_000; e.processPending()
        val op = e.operations.value.last { it.type == SerializdOperationType.SubmitRating }
        assertEquals(SerializdOperationStatus.ActionRequired, op.status); assertEquals(1, rig.server.ratingsOnly.size)
        assertEquals(6, rig.server.ratingsOnly.single().rating, "no second entry was made")
    }

    @Test fun aFavouriteGoesWithTheShowsRatingSoItIsNotCleared() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.settings = SerializdSettings(syncFavorites = true)
        e.setRating(1, SerializdTarget(1399), "GoT", 4.5); rig.clock += 11_000; e.processPending()
        e.setShowLike(1, 1399, "GoT", true); rig.clock += 11_000; e.processPending()
        val entry = rig.server.ratingsOnly.single()
        assertTrue(entry.like); assertEquals(9, entry.rating)
    }

    @Test fun favouritesAreOffByDefaultAndNeverImplyAWatch() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.setShowLike(1, 1399, "GoT", true); rig.clock += 11_000; e.processPending()
        assertTrue(rig.server.requests.isEmpty()); assertTrue(rig.server.markers.isEmpty())
        rig.settings = SerializdSettings(syncFavorites = true)
        e.setShowLike(1, 1399, "GoT", true); rig.clock += 11_000; e.processPending()
        assertTrue(rig.server.markers.isEmpty(), "a favourite is not proof the show was watched")
        assertTrue(rig.server.ratingsOnly.single().like)
    }
}

class SerializdEngineReviewsTest {
    @Test fun aReviewOnAnEntryNotSentYetJoinsIt() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false)
        assertEquals(SerializdReviewOutcome.Queued, e.publishReview(1, rig.got1, "GoT", "Great opener", true, 4.0))
        e.processPending()
        val entry = rig.server.diary.single()
        assertEquals("Great opener", entry.text); assertTrue(entry.spoiler); assertTrue(entry.isLog); assertEquals(8, entry.rating)
        assertEquals(1, rig.server.posts("/show/reviews/add").size)
    }

    @Test fun aReviewOnAnEntryAlreadyOnSerializdEditsItWithoutADuplicate() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        assertEquals(SerializdReviewOutcome.Queued, e.publishReview(1, rig.got1, "GoT", "Loved it", false, 5.0))
        e.processPending()
        assertEquals(1, rig.server.diary.size); val entry = rig.server.diary.single()
        assertEquals("Loved it", entry.text); assertEquals(10, entry.rating); assertEquals(ISO0, entry.backdate)
        assertEquals(1, rig.server.posts("/show/reviews/add").size)
        assertTrue(e.operations.value.none { it.reviewText != null }, "a review that is on Serializd is not also kept in the queue")
    }

    @Test fun theTextSurvivesAFailedSubmissionAndIsSentOnRetry() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        rig.server.addScript += FakeSerializdServer.Write.Status(400)
        e.publishReview(1, rig.got1, "GoT", "Long thoughtful text", true, null); e.processPending()
        val failed = e.ops(SerializdOperationType.SubmitReview).single()
        assertEquals(SerializdOperationStatus.FailedPermanent, failed.status)
        assertEquals("Long thoughtful text", e.watches.value.single().reviewDraft); assertEquals("Long thoughtful text", failed.reviewText)
        assertTrue(e.events.value.none { ev -> ev.note?.contains("Long thoughtful") == true }, "review text never reaches the history")
        e.retry(failed.id); e.processPending()
        assertEquals("Long thoughtful text", rig.server.diary.single().text); assertEquals(1, rig.server.diary.size)
    }

    @Test fun aReplyWithoutAnIdStillLetsALaterEditFindTheEntryOnTheDiary() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.server.addReplyHasId = false
        e.onCompletion(rig.done(), null, false); e.processPending()
        assertNull(e.watches.value.single().remoteReviewId)
        e.publishReview(1, rig.got1, "GoT", "Found it", false, 4.0); e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals("Found it", rig.server.diary.single().text)
        assertEquals(1, rig.server.posts("/show/reviews/add").size)
    }

    @Test fun anEntryThatCannotBeFoundKeepsTheTextAndAsksTheMemberToEditItOnSerializd() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.server.addReplyHasId = false
        e.onCompletion(rig.done(), null, false); e.processPending()
        rig.server.diary.clear()
        e.publishReview(1, rig.got1, "GoT", "Still mine", false, null); e.processPending()
        assertEquals(SerializdOperationStatus.ActionRequired, e.ops(SerializdOperationType.SubmitReview).single().status)
        assertEquals("Still mine", e.watches.value.single().reviewDraft); assertEquals(1, rig.server.posts("/show/reviews/add").size)
    }

    @Test fun aReviewForAViewingNeverLoggedMakesTheDatedEntryOnce() = runTest {
        val rig = Rig(); val e = rig.engine(); rig.settings = SerializdSettings(createDiaryEntries = false)
        e.onCompletion(rig.done(), null, false); e.processPending()
        e.publishReview(1, rig.got1, "GoT", "Worth a log", false, 4.5); e.processPending()
        val entry = rig.server.diary.single()
        assertEquals("Worth a log", entry.text); assertEquals(ISO0, entry.backdate); assertEquals(9, entry.rating); assertTrue(e.watches.value.single().onDiary)
    }

    @Test fun aReviewWhileTheEntryIsInDoubtWaitsForTheMember() = runTest {
        val rig = Rig(); val e = rig.engine()
        rig.server.addScript += FakeSerializdServer.Write.LandedReplyLost
        e.onCompletion(rig.done(), null, false); e.processPending()
        val outcome = e.publishReview(1, rig.got1, "GoT", "Hold on", false, null)
        assertTrue(outcome is SerializdReviewOutcome.DraftKeptOpenSerializd)
        assertEquals("Hold on", e.watches.value.single().reviewDraft); assertEquals(1, rig.server.posts("/show/reviews/add").size)
    }

    @Test fun emptyReviewTextWithARatingStillWorks() = runTest {
        val rig = Rig(); val e = rig.engine()
        e.onCompletion(rig.done(), null, false); e.processPending()
        e.publishReview(1, rig.got1, "GoT", "", false, 3.0); e.processPending()
        assertEquals("", rig.server.diary.single().text); assertEquals(6, rig.server.diary.single().rating)
    }

    @Test fun aSeasonOrShowReviewIsALogEntryOfItsOwnEditedOnTheNextSubmission() = runTest {
        val rig = Rig(); val e = rig.engine()
        val season = SerializdTarget(1399, 2)
        e.publishReview(1, season, "GoT", "A great season", false, 4.5); e.processPending()
        val entry = rig.server.diary.single()
        assertEquals(3625, entry.seasonId); assertNull(entry.episodeNumber); assertTrue(entry.isLog); assertEquals(9, entry.rating); assertEquals("A great season", entry.text)
        e.publishReview(1, season, "GoT", "A great, great season", true, 5.0); e.processPending()
        assertEquals(1, rig.server.diary.size); assertEquals("A great, great season", rig.server.diary.single().text); assertTrue(rig.server.diary.single().spoiler)
        e.publishReview(1, SerializdTarget(1399), "GoT", "An excellent series.", false, 4.5); e.processPending()
        assertEquals(2, rig.server.diary.size); assertNull(rig.server.diary.first().seasonId)
    }

    @Test fun reviewingWithoutAnAccountSaysSo() = runTest {
        val rig = Rig(account = null); val e = rig.engine()
        assertEquals(SerializdReviewOutcome.NotConnected, e.publishReview(1, rig.got1, "GoT", "x", false, null))
    }

    @Test fun aLoggedPastViewingUsesTheDateTheMemberGaveAndIsMarkedWatchedToo() = runTest {
        val rig = Rig(); val e = rig.engine()
        val past = T0 - 40 * 86_400_000L
        val w = e.logViewingManually(1, rig.got1, "GoT", null, past, 4.0)!!
        assertEquals(SerializdWatch.SOURCE_MANUAL, w.source); assertFalse(w.rewatch)
        e.processPending()
        assertEquals(SerializdDates.isoUtc(past), rig.server.diary.single().backdate); assertEquals(8, rig.server.diary.single().rating); assertEquals(1, rig.server.markers.size)
        val again = e.logViewingManually(1, rig.got1, "GoT", null, past + 86_400_000L, null)!!
        assertTrue(again.rewatch); e.processPending(); assertEquals(2, rig.server.diary.size); assertTrue(rig.server.diary.first().isRewatch)
    }
}
