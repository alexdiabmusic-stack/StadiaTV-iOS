package com.nuvio.app.features.letterboxd

import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

private class Rig(val site: FakeLetterboxdSite = FakeLetterboxdSite(), account: String? = "tester") : LetterboxdEngineHost {
    // 2026-11-21 20:00 UTC.
    var clock = LetterboxdDates.epochDay("2026-11-21")!! * DAY + 20 * 3_600_000L
    val kv = MemoryKeyValue()
    var account: String? = account
    var settings = LetterboxdSettings()
    val states = mutableListOf<LetterboxdConnectionState>()
    private var ids = 0
    private val service = LetterboxdWebService(
        LetterboxdSession(site.material(), site), LetterboxdFilmCache(kv) { clock }, now = { clock }, pause = {}, pageSpacingMs = 0,
    )
    var hasService = true

    init {
        site.films += FakeLetterboxdSite.Film(603, "the-matrix", "51561", "2a8i")
        site.films += FakeLetterboxdSite.Film(680, "pulp-fiction", "777", "p1")
        site.films += FakeLetterboxdSite.Film(11, "star-wars", "888", "s1")
        site.films += FakeLetterboxdSite.Film(12, "finding-nemo", "999", "n1")
    }

    override fun accountOf(profileId: Int) = account
    override fun settingsOf(profileId: Int) = settings
    override fun serviceOf(profileId: Int) = if (hasService) service else null
    override fun onConnectionState(profileId: Int, state: LetterboxdConnectionState) { states += state }

    fun engine() = LetterboxdSyncEngine(kv, this, now = { clock }, localDate = ::civil, newId = { "id${ids++}" })

    fun done(tmdb: Int = 603, title: String = "The Matrix", session: String = "s1", profile: Int = 1) =
        LetterboxdCompletion(session, profile, tmdb, title, clock, LetterboxdCompletionReason.PlayerReportedEnd, 1.0)

    companion object {
        const val DAY = 86_400_000L
        fun civil(ms: Long): String {
            val z = ms.floorDiv(DAY) + 719468
            val era = z.floorDiv(146097L); val doe = z - era * 146097
            val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
            val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            val mp = (5 * doy + 2) / 153
            val d = doy - (153 * mp + 2) / 5 + 1
            val m = if (mp < 10) mp + 3 else mp - 9
            return LetterboxdDates.format((yoe + era * 400 + if (m <= 2) 1 else 0).toInt(), m.toInt(), d.toInt())
        }
    }
}

class LetterboxdEngineTest {
    private val today = "2026-11-21"

    @Test fun aFinishedFilmIsLoggedOnTheViewersLocalDateAndConfirmedOnTheDiary() = runTest {
        val rig = Rig(); val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, liked = false)
        assertEquals(today, v.localDate)
        engine.processPending()
        assertEquals(1, rig.site.writeCount)
        val body = rig.site.diaryWrites.single()
        assertEquals(today, body.getValue("diaryDetails").jsonObject.getValue("diaryDate").jsonPrimitive.content)
        assertEquals("false", body.getValue("diaryDetails").jsonObject.getValue("rewatch").jsonPrimitive.content)
        assertEquals("2a8i", body.getValue("productionId").jsonPrimitive.content)
        assertEquals(LetterboxdOperationStatus.Succeeded, engine.operations.value.single().status)
        assertTrue(engine.viewings.value.single().onDiary)
        assertTrue(rig.site.diary["the-matrix"]!!.contains(today))
    }

    @Test fun theDateIsFixedAtCompletionEvenIfTheSendHappensTheNextDay() = runTest {
        val rig = Rig(); rig.site.writeScript += FakeLetterboxdSite.Write.Offline
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false)
        engine.processPending()
        assertEquals(LetterboxdOperationStatus.RetryScheduled, engine.operations.value.single().status)
        rig.clock += Rig.DAY // retried tomorrow
        engine.processPending()
        assertEquals("2026-11-21", rig.site.diaryWrites.single().getValue("diaryDetails").jsonObject.getValue("diaryDate").jsonPrimitive.content)
        assertEquals(1, rig.site.diaryWrites.size)
    }

    @Test fun aRepeatedPlayerCallbackNeverMakesASecondEntry() = runTest {
        val rig = Rig(); val engine = rig.engine()
        val first = engine.onCompletion(rig.done(session = "same"), null, false)
        val second = engine.onCompletion(rig.done(session = "same"), null, false)
        assertEquals(first.id, second.id)
        engine.processPending(); engine.processPending()
        assertEquals(1, rig.site.writeCount); assertEquals(1, engine.operations.value.size)
    }

    @Test fun aSecondViewingTheSameDayIsKeptLocallyAndNotSent() = runTest {
        val rig = Rig(); val engine = rig.engine()
        engine.onCompletion(rig.done(session = "a"), null, false); engine.processPending()
        val again = engine.onCompletion(rig.done(session = "b"), null, false); engine.processPending()
        assertTrue(again.localOnly)
        assertEquals(1, rig.site.writeCount)
        assertEquals(2, engine.viewingsFor(1, 603).size)
        assertEquals(LetterboxdOperationStatus.Skipped, engine.events.value.last().status)
    }

    @Test fun aFilmAlreadyOnTheDiaryTodayIsNotLoggedAgain() = runTest {
        val rig = Rig(); rig.site.diary["the-matrix"] = mutableListOf(today)
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(0, rig.site.writeCount)
        assertEquals(LetterboxdOperationStatus.Skipped, engine.operations.value.single().status)
        assertTrue(engine.viewings.value.single().onDiary)
    }

    @Test fun anEarlierEntryMoreThanADayBackMakesItARewatch() = runTest {
        val rig = Rig(); rig.site.diary["the-matrix"] = mutableListOf("2026-10-01")
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals("true", rig.site.diaryWrites.single().getValue("diaryDetails").jsonObject.getValue("rewatch").jsonPrimitive.content)
    }

    @Test fun anEntryYesterdayIsNotARewatch() = runTest {
        val rig = Rig(); rig.site.diary["the-matrix"] = mutableListOf("2026-11-20")
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals("false", rig.site.diaryWrites.single().getValue("diaryDetails").jsonObject.getValue("rewatch").jsonPrimitive.content)
    }

    @Test fun rewatchLoggingCanBeTurnedOff() = runTest {
        val rig = Rig(); rig.site.diary["the-matrix"] = mutableListOf("2026-10-01"); rig.settings = LetterboxdSettings(logRewatches = false)
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(0, rig.site.writeCount)
        assertEquals(LetterboxdOperationStatus.Skipped, engine.operations.value.single().status)
    }

    @Test fun aFailedDiaryLookupIsNeverTakenAsNoEntry() = runTest {
        val rig = Rig(); rig.site.diaryStatus = 500
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(0, rig.site.writeCount)
        val op = engine.operations.value.single()
        assertEquals(LetterboxdOperationStatus.RetryScheduled, op.status)
        // The site recovers; the retry runs and logs once.
        rig.site.diaryStatus = null; rig.clock += 2 * 60_000
        engine.processPending()
        assertEquals(1, rig.site.writeCount)
    }

    @Test fun autoLoggingOffRecordsTheViewingButSendsNothing() = runTest {
        val rig = Rig(); rig.settings = LetterboxdSettings(autoLogMovies = false)
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(1, engine.viewings.value.size); assertTrue(engine.operations.value.isEmpty()); assertEquals(0, rig.site.requests.size)
    }

    @Test fun noConnectedAccountMeansNoQueueAndNoRequests() = runTest {
        val rig = Rig(account = null); val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertTrue(engine.operations.value.isEmpty()); assertEquals(0, rig.site.requests.size)
    }

    // ---- uncertain writes

    @Test fun aLostReplyAfterALandedWriteIsConfirmedNotResent() = runTest {
        val rig = Rig(); rig.site.writeScript += FakeLetterboxdSite.Write.LandedReplyLost
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(LetterboxdOperationStatus.NeedsReconciliation, engine.operations.value.single().status)
        rig.clock += LetterboxdSyncEngine.RECONCILE_AFTER_MS + 1
        engine.processPending()
        assertEquals(LetterboxdOperationStatus.Succeeded, engine.operations.value.single().status)
        assertEquals(1, rig.site.diary["the-matrix"]!!.size)
        assertEquals(1, rig.site.writeCount)
        assertTrue(engine.viewings.value.single().onDiary)
    }

    @Test fun aWriteLostBeforeLandingIsOnlyResentAfterTheDiaryProvesItIsMissing() = runTest {
        val rig = Rig(); rig.site.writeScript += FakeLetterboxdSite.Write.LostBeforeLanding
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(1, rig.site.writeCount)
        // Soon after: the diary lacks it, but it is too early to be sure; nothing is sent.
        rig.clock += LetterboxdSyncEngine.RECONCILE_AFTER_MS + 1; engine.processPending()
        assertEquals(1, rig.site.writeCount)
        assertEquals(LetterboxdOperationStatus.NeedsReconciliation, engine.operations.value.single().status)
        // Long enough, diary readable, entry absent: now it is sent, once.
        rig.clock += LetterboxdSyncEngine.RESEND_AFTER_MS + 1; engine.processPending()
        assertEquals(2, rig.site.writeCount)
        assertEquals(1, rig.site.diary["the-matrix"]!!.size)
        assertEquals(LetterboxdOperationStatus.Succeeded, engine.operations.value.single().status)
    }

    @Test fun anAcceptedWriteNotYetOnTheDiaryIsReconciledNotRepeated() = runTest {
        val rig = Rig()
        // The site says 200 but the entry does not show up: simulate by clearing the diary after the write.
        val engine = rig.engine()
        rig.site.writeScript += FakeLetterboxdSite.Write.Status(200, """{"result": true}""") // accepted, nothing lands
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(LetterboxdOperationStatus.NeedsReconciliation, engine.operations.value.single().status)
        assertEquals(1, rig.site.writeCount)
        rig.clock += LetterboxdSyncEngine.RECONCILE_AFTER_MS + 1; engine.processPending()
        assertEquals(1, rig.site.writeCount)
    }

    @Test fun aWriteThatNeverLeftTheDeviceIsRetriedWithBackoff() = runTest {
        val rig = Rig(); rig.site.writeScript += FakeLetterboxdSite.Write.Offline
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        val op = engine.operations.value.single()
        assertEquals(LetterboxdOperationStatus.RetryScheduled, op.status)
        assertFalse(op.reconciling)
        assertTrue(op.nextAttemptAtMs > rig.clock)
        rig.clock += 60_000; engine.processPending()
        assertEquals(LetterboxdOperationStatus.Succeeded, engine.operations.value.single().status)
        assertEquals(1, rig.site.diary["the-matrix"]!!.size)
    }

    @Test fun backoffGrowsAndIsCapped() {
        val engine = Rig().engine()
        assertEquals(30_000L, engine.backoffMs(1)); assertEquals(60_000L, engine.backoffMs(2)); assertEquals(120_000L, engine.backoffMs(3))
        assertEquals(LetterboxdSyncEngine.MAX_BACKOFF_MS, engine.backoffMs(40))
    }

    @Test fun aRateLimitWaitsForRetryAfter() = runTest {
        val rig = Rig(); rig.site.writeScript += FakeLetterboxdSite.Write.Status(429)
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        val op = engine.operations.value.single()
        assertEquals(LetterboxdOperationStatus.RetryScheduled, op.status); assertEquals(LetterboxdErrorCategory.RateLimited, op.error)
        assertTrue(op.nextAttemptAtMs - rig.clock >= LetterboxdSession.DEFAULT_RETRY_AFTER_MS)
        assertFalse(op.reconciling) // a 429 means nothing landed
    }

    @Test fun aBotCheckBacksOffForFifteenMinutesAndReportsUnavailable() = runTest {
        val rig = Rig(); rig.site.challenge = true
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertTrue(rig.states.contains(LetterboxdConnectionState.TemporarilyUnavailable))
        val op = engine.operations.value.single()
        assertTrue(op.nextAttemptAtMs - rig.clock >= LetterboxdSyncEngine.BLOCKED_BACKOFF_MS)
    }

    @Test fun anUnmatchableFilmFailsOnceWithoutRetryLoops() = runTest {
        val rig = Rig(); val engine = rig.engine()
        engine.onCompletion(rig.done(tmdb = 424242, title = "Nothing"), null, false); engine.processPending()
        val op = engine.operations.value.single()
        assertEquals(LetterboxdOperationStatus.Failed, op.status); assertEquals(LetterboxdErrorCategory.FilmNotFound, op.error)
        assertEquals(1, engine.viewings.value.size) // still in the local history
    }

    @Test fun aTvEntryIsNeverLogged() = runTest {
        val rig = Rig(); rig.site.films += FakeLetterboxdSite.Film(900, "a-miniseries", "1", "z", tv = true)
        val engine = rig.engine()
        engine.onCompletion(rig.done(tmdb = 900, title = "Miniseries"), null, false); engine.processPending()
        assertEquals(LetterboxdErrorCategory.NotAFilm, engine.operations.value.single().error); assertEquals(0, rig.site.writeCount)
    }

    // ---- authentication

    @Test fun anExpiredSessionHoldsTheQueueUntilReconnectThenSendsSafely() = runTest {
        val rig = Rig(); rig.site.signedIn = false
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(LetterboxdOperationStatus.NeedsReconnect, engine.operations.value.single().status)
        assertTrue(rig.states.contains(LetterboxdConnectionState.SessionExpired))
        engine.processPending() // nothing happens while it is held
        assertEquals(0, rig.site.writeCount)
        rig.site.signedIn = true; engine.onReconnected(1); engine.processPending()
        assertEquals(LetterboxdOperationStatus.Succeeded, engine.operations.value.single().status)
        assertEquals(1, rig.site.writeCount)
    }

    @Test fun threeLoginFailuresStopTheAccountAndNeedAReconnect() = runTest {
        val rig = Rig(); rig.site.signedIn = false
        val engine = rig.engine()
        for ((i, id) in listOf(603, 680, 11).withIndex()) {
            engine.onCompletion(rig.done(tmdb = id, title = "t$i", session = "s$i"), null, false); engine.processPending()
        }
        assertEquals(LetterboxdConnectionState.ReconnectionRequired, rig.states.last { it != LetterboxdConnectionState.Connected })
        // A fourth film queues but nothing is sent while the breaker is open.
        val before = rig.site.requests.size
        engine.onCompletion(rig.done(tmdb = 12, title = "t3", session = "s3"), null, false); engine.processPending()
        assertEquals(before, rig.site.requests.size)
        assertEquals(0, rig.site.writeCount)
    }

    @Test fun noServiceMeansReconnectionRequiredNotACrash() = runTest {
        val rig = Rig(); rig.hasService = false
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(LetterboxdOperationStatus.NeedsReconnect, engine.operations.value.single().status)
        assertEquals(LetterboxdConnectionState.ReconnectionRequired, rig.states.last())
    }

    // ---- ratings

    @Test fun ratingsAreDebouncedAndOnlyTheLastIsSent() = runTest {
        val rig = Rig(); val engine = rig.engine()
        engine.setRating(1, 603, "The Matrix", 3.0, null)
        engine.setRating(1, 603, "The Matrix", 3.5, null)
        engine.setRating(1, 603, "The Matrix", 4.5, null)
        engine.processPending() // too soon
        assertTrue(rig.site.ratings.isEmpty())
        rig.clock += LetterboxdSyncEngine.RATING_DEBOUNCE_MS + 1; engine.processPending()
        assertEquals(mapOf("51561" to 9), rig.site.ratings)
        assertEquals(1, rig.site.requests.count { it.path.endsWith("/rate/") })
    }

    @Test fun anUnchangedRatingIsNotSentAgain() = runTest {
        val rig = Rig(); val engine = rig.engine()
        engine.setRating(1, 603, "The Matrix", 4.0, null)
        rig.clock += LetterboxdSyncEngine.RATING_DEBOUNCE_MS + 1; engine.processPending()
        engine.setRating(1, 603, "The Matrix", 4.0, null)
        rig.clock += LetterboxdSyncEngine.RATING_DEBOUNCE_MS + 1; engine.processPending()
        assertEquals(1, rig.site.requests.count { it.path.endsWith("/rate/") })
        assertEquals(LetterboxdOperationStatus.Skipped, engine.operations.value.last().status)
    }

    @Test fun everyHalfStepReachesTheSiteOnTheRightScale() = runTest {
        val rig = Rig(); val engine = rig.engine()
        for ((i, stars) in LetterboxdRating.choices.filterNotNull().withIndex()) {
            engine.setRating(1, 603, "The Matrix", stars, null)
            rig.clock += LetterboxdSyncEngine.RATING_DEBOUNCE_MS + 1; engine.processPending()
            assertEquals(i + 1, rig.site.ratings["51561"])
        }
    }

    @Test fun aRatingGivenBeforeTheEntryIsSentRidesOnTheEntry() = runTest {
        val rig = Rig(); val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false)
        engine.setRating(1, 603, "The Matrix", 4.5, v.id)
        engine.processPending()
        assertEquals("4.5", rig.site.diaryWrites.single().getValue("rating").jsonPrimitive.content)
        assertEquals(0, rig.site.requests.count { it.path.endsWith("/rate/") })
        assertEquals(4.5, engine.viewings.value.single().stars)
    }

    @Test fun ratingsOffKeepsTheRatingLocal() = runTest {
        val rig = Rig(); rig.settings = LetterboxdSettings(syncRatings = false); val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false)
        engine.setRating(1, 603, "The Matrix", 4.0, v.id)
        assertEquals(4.0, engine.viewings.value.single().stars)
        assertTrue(engine.operations.value.none { it.type == LetterboxdOperationType.SetRating })
    }

    @Test fun clearingARatingStaysLocalBecauseTheSessionCannotVerifyAnUnrate() = runTest {
        val rig = Rig(); val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false); engine.processPending()
        engine.setRating(1, 603, "The Matrix", null, v.id)
        assertNull(engine.viewings.value.single().stars)
        assertTrue(engine.operations.value.none { it.type == LetterboxdOperationType.SetRating })
    }

    // ---- likes

    @Test fun favouritesBecomeLikesOnlyWhenThatSettingIsOnAndNeverARating() = runTest {
        val off = Rig(); val e1 = off.engine()
        e1.onCompletion(off.done(), null, liked = true); e1.processPending()
        assertEquals("false", off.site.diaryWrites.single().getValue("like").jsonPrimitive.content)
        assertNull(off.site.diaryWrites.single()["rating"])
        val on = Rig(); on.settings = LetterboxdSettings(syncFavorites = true); val e2 = on.engine()
        e2.onCompletion(on.done(), null, liked = true); e2.processPending()
        assertEquals("true", on.site.diaryWrites.single().getValue("like").jsonPrimitive.content)
        assertNull(on.site.diaryWrites.single()["rating"])
    }

    // ---- reviews

    @Test fun aReviewWrittenBeforeTheEntryGoesOutIsPublishedWithIt() = runTest {
        val rig = Rig(); val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false)
        val outcome = engine.publishReview(v.id, "Brilliant. 🎬 Ünïcode — “quotes” & <tags>", true, 4.0)
        assertEquals(LetterboxdReviewOutcome.Queued, outcome)
        engine.processPending()
        assertEquals(1, rig.site.writeCount)
        val review = rig.site.diaryWrites.single().getValue("review").jsonObject
        assertEquals("Brilliant. 🎬 Ünïcode — “quotes” & <tags>", review.getValue("text").jsonPrimitive.content)
        assertEquals("true", review.getValue("containsSpoilers").jsonPrimitive.content)
        assertTrue(engine.viewings.value.single().reviewPublished)
    }

    @Test fun aLongReviewIsSentWhole() = runTest {
        val rig = Rig(); val engine = rig.engine(); val long = "word ".repeat(2_000)
        val v = engine.onCompletion(rig.done(), null, false)
        engine.publishReview(v.id, long, false, null); engine.processPending()
        assertEquals(long, rig.site.diaryWrites.single().getValue("review").jsonObject.getValue("text").jsonPrimitive.content)
    }

    @Test fun aReviewForAViewingAlreadyOnTheDiaryNeverMakesASecondEntry() = runTest {
        val rig = Rig(); val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertEquals(1, rig.site.writeCount)
        val outcome = engine.publishReview(v.id, "Late thoughts", false, null)
        assertIs<LetterboxdReviewOutcome.DraftKeptOpenLetterboxd>(outcome)
        assertTrue(outcome.url.contains("/tester/film/the-matrix/"))
        engine.processPending()
        assertEquals(1, rig.site.writeCount) // nothing new was sent
        assertEquals("Late thoughts", engine.viewings.value.single().reviewDraft)
        assertFalse(engine.viewings.value.single().reviewPublished)
    }

    @Test fun aReviewForAnEntryWhoseWriteIsInDoubtIsKeptAsADraft() = runTest {
        val rig = Rig(); rig.site.writeScript += FakeLetterboxdSite.Write.LandedReplyLost
        val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false); engine.processPending()
        assertIs<LetterboxdReviewOutcome.DraftKeptOpenLetterboxd>(engine.publishReview(v.id, "text", false, null))
        assertEquals(1, rig.site.writeCount)
    }

    @Test fun aPendingReviewIsNotLostWhenTheFilmWasAlreadyLoggedElsewhere() = runTest {
        val rig = Rig(); rig.site.diary["the-matrix"] = mutableListOf(today)
        val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false)
        engine.publishReview(v.id, "My review", false, null); engine.processPending()
        assertEquals(0, rig.site.writeCount)
        assertEquals(LetterboxdOperationStatus.ActionRequired, engine.operations.value.single().status)
        assertEquals("My review", engine.viewings.value.single().reviewDraft)
    }

    @Test fun draftsAreKeptAcrossRestarts() = runTest {
        val rig = Rig(); val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false)
        engine.saveReviewDraft(v.id, "half written", true)
        val reopened = rig.engine()
        assertEquals("half written", reopened.viewings.value.single().reviewDraft); assertTrue(reopened.viewings.value.single().reviewSpoilers)
    }

    // ---- manual logging, persistence, disconnect

    @Test fun logViewingManuallySendsEvenWhenTheFilmIsAlreadyOnTheDiaryToday() = runTest {
        val rig = Rig(); rig.site.diary["the-matrix"] = mutableListOf(today)
        val engine = rig.engine()
        engine.logViewingManually(1, 603, "The Matrix", null, 5.0, false); engine.processPending()
        assertEquals(1, rig.site.writeCount)
        assertEquals("5.0", rig.site.diaryWrites.single().getValue("rating").jsonPrimitive.content)
    }

    @Test fun theQueueSurvivesAnAppRestartAndIsNotDuplicated() = runTest {
        val rig = Rig(); rig.site.writeScript += FakeLetterboxdSite.Write.Offline
        val first = rig.engine()
        first.onCompletion(rig.done(), null, false); first.processPending()
        val reopened = rig.engine()
        assertEquals(1, reopened.operations.value.size)
        rig.clock += 60_000; reopened.processPending()
        assertEquals(LetterboxdOperationStatus.Succeeded, reopened.operations.value.single().status)
        assertEquals(1, rig.site.diary["the-matrix"]!!.size)
        // The same completion arriving again after a restart still makes no second entry.
        reopened.onCompletion(rig.done(), null, false); reopened.processPending()
        assertEquals(1, rig.site.diary["the-matrix"]!!.size)
    }

    @Test fun anOperationLeftInProgressByAKilledAppIsRecovered() = runTest {
        val rig = Rig(); val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false)
        // Simulate being killed mid-send: the stored op is InProgress with no write sent.
        val stuck = engine.operations.value.single().copy(status = LetterboxdOperationStatus.InProgress, lastAttemptAtMs = rig.clock)
        rig.kv.map["letterboxd_ops_v1"] = kotlinx.serialization.json.Json.encodeToString(kotlinx.serialization.builtins.ListSerializer(LetterboxdOperation.serializer()), listOf(stuck))
        val reopened = rig.engine()
        reopened.processPending()
        assertEquals(0, rig.site.writeCount) // not yet: it may still be running
        rig.clock += LetterboxdSyncEngine.STUCK_AFTER_MS + 1; reopened.processPending()
        assertEquals(LetterboxdOperationStatus.Succeeded, reopened.operations.value.single().status)
    }

    @Test fun disconnectingStopsPendingWritesAndCanDeleteLocalHistory() = runTest {
        val rig = Rig(); rig.site.writeScript += FakeLetterboxdSite.Write.Offline
        val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false); engine.processPending()
        engine.onDisconnected(1, "tester", deleteLocal = false)
        assertTrue(engine.operations.value.none { it.status == LetterboxdOperationStatus.RetryScheduled })
        assertEquals(1, engine.viewings.value.size)
        rig.account = null; rig.clock += Rig.DAY; engine.processPending()
        assertEquals(1, rig.site.writeCount)
        engine.onDisconnected(1, "tester", deleteLocal = true)
        assertTrue(engine.viewings.value.isEmpty()); assertTrue(engine.operations.value.isEmpty()); assertTrue(engine.events.value.isEmpty())
    }

    @Test fun profilesAreIsolated() = runTest {
        val rig = Rig(); val engine = rig.engine()
        engine.onCompletion(rig.done(profile = 1, session = "p1"), null, false)
        engine.onCompletion(rig.done(profile = 2, session = "p2"), null, false)
        assertEquals(1, engine.viewingsFor(1, 603).size); assertEquals(1, engine.viewingsFor(2, 603).size)
        engine.onDisconnected(2, "tester", deleteLocal = true)
        assertEquals(1, engine.viewingsFor(1, 603).size); assertTrue(engine.viewingsFor(2, 603).isEmpty())
    }

    @Test fun anAccountSwitchedAfterQueueingDoesNotReceiveTheOldAccountsOperations() = runTest {
        val rig = Rig(); val engine = rig.engine()
        engine.onCompletion(rig.done(), null, false)
        rig.account = "someone_else"
        engine.processPending()
        assertEquals(0, rig.site.requests.size)
    }

    @Test fun coverageIsPersistedPerProfileAndFilm() = runTest {
        val rig = Rig(); val engine = rig.engine()
        engine.saveCoverage(1, 603, WatchedCoverage().add(0, 60_000))
        assertEquals(60_000L, rig.engine().coverageFor(1, 603).totalMs)
        assertEquals(0L, rig.engine().coverageFor(2, 603).totalMs)
        engine.saveCoverage(1, 603, WatchedCoverage())
        assertEquals(0L, rig.engine().coverageFor(1, 603).totalMs)
    }

    @Test fun historyNeverContainsTheReviewText() = runTest {
        val rig = Rig(); rig.site.diaryStatus = 500; val engine = rig.engine()
        val v = engine.onCompletion(rig.done(), null, false)
        engine.publishReview(v.id, "SECRET-REVIEW-TEXT", false, null); engine.processPending()
        assertTrue(engine.events.value.none { it.note.orEmpty().contains("SECRET") })
        assertNotNull(engine.events.value.firstOrNull())
    }
}
